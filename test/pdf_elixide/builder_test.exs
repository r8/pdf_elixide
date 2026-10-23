defmodule PdfElixide.BuilderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import PdfElixide.Handles
  import PdfElixide.TestHelpers
  import PdfElixide.Untyped

  alias PdfElixide.Builder
  alias PdfElixide.Builder.FontFamily
  alias PdfElixide.Color.RGB
  alias PdfElixide.Document
  alias PdfElixide.Document.Image
  alias PdfElixide.Document.Page
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Png

  # Helvetica's ascent and descent, in thousandths of an em.
  @ascent 718
  @descent -207

  defp baselines(doc, page) do
    doc
    |> Document.chars!(page)
    |> Enum.map(&Float.round(&1.bbox.y, 3))
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  defp baseline(top, size, line_height \\ 1.5) do
    half_leading = (size * line_height - (@ascent - @descent) * size / 1000) / 2
    top - half_leading - @ascent * size / 1000
  end

  @fixtures Path.join([__DIR__, "..", "fixtures"])

  defp font(name), do: File.read!(Path.join(@fixtures, name))

  defp cff_family do
    FontFamily.new(
      regular: font("font_cff_regular.otf"),
      bold: font("font_cff_bold.otf"),
      italic: font("font_cff_italic.otf")
    )
  end

  defp fonts_by_text(doc) do
    doc |> Document.chars!(0) |> Map.new(&{&1.text, &1.font})
  end

  # A built page has a single content stream, so `ContentOrder`, which reads a
  # `/Contents` array, does not apply.
  defp content(builder) do
    bytes = builder |> Builder.to_binary!(compress: false)
    streams = Regex.scan(~r/stream\r?\n(.*?)endstream/s, bytes, capture: :all_but_first)
    [body] = for [stream] <- streams, stream =~ " w\n", do: stream
    body
  end

  defp refusal(builder) do
    assert {:error, %Error{reason: :unsupported, message: message}} = Builder.to_binary(builder)
    message
  end

  describe "the output" do
    test "an empty description is one blank page of the default size" do
      doc = written(Builder.new())

      assert Document.page_count!(doc) == 1
      assert %{width: 612.0, height: 792.0} = Page.media_box!(Document.page!(doc, 0))
      assert Document.chars!(doc, 0) == []
    end

    test "writes the document information" do
      metadata =
        Builder.new(title: "Title", author: "Author", subject: "Subject", creator: "Creator")
        |> written()
        |> Document.metadata!()

      assert %{title: "Title", author: "Author", subject: "Subject", creator: "Creator"} =
               metadata
    end

    test "Editor.from_builder/1 opens an editor with no source path" do
      editor = Builder.new() |> Builder.paragraph("Body") |> Editor.from_builder!()
      on_exit(fn -> Editor.close(editor) end)

      assert %Editor{source_path: nil} = editor
      assert Editor.page_count!(editor) == 1
      refute Editor.modified?(editor)
    end

    @tag :tmp_dir
    test "save/3 writes the PDF", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "built.pdf")

      assert :ok = Builder.new() |> Builder.paragraph("Saved") |> Builder.save(path)
      assert Document.open!(path) |> Document.text!() =~ "Saved"
    end

    @tag :tmp_dir
    test "to_binary/2 and save/3 close the editor they open, even when saving fails",
         %{tmp_dir: tmp_dir} do
      # A pattern set before the module loads matches nothing, and a process
      # cannot trace its own calls, so a spawned process makes them.
      Code.ensure_loaded!(Editor)
      1 = :erlang.trace_pattern({Editor, :close, 1}, true, [:local])
      on_exit(fn -> :erlang.trace_pattern({Editor, :close, 1}, false, [:local]) end)

      parent = self()
      missing = Path.join([tmp_dir, "missing", "out.pdf"])

      pid =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          Builder.to_binary!(Builder.new())
          send(parent, {:saved, Builder.save(Builder.new(), missing)})
        end)

      :erlang.trace(pid, true, [:call])
      send(pid, :go)

      assert_receive {:saved, {:error, %Error{}}}
      assert_receive {:trace, ^pid, :call, {Editor, :close, [%Editor{}]}}
      assert_receive {:trace, ^pid, :call, {Editor, :close, [%Editor{}]}}
    end
  end

  describe "layout" do
    test "the first baseline sits inside a line box at the top margin" do
      doc = Builder.new() |> Builder.paragraph("Top") |> written()

      assert [first] = baselines(doc, 0)
      assert_in_delta first, baseline(792 - 72, 12), 0.001
    end

    test "lines step by one box and the last box ends at the bottom margin" do
      doc = Builder.new() |> Builder.paragraph(lines(36)) |> written()
      ys = baselines(doc, 0)

      assert length(ys) == 36

      assert ys
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> abs(a - b - 18) < 0.01 end)

      assert_in_delta List.last(ys), baseline(72 + 18, 12), 0.001
      assert Document.page_count!(doc) == 1
    end

    test "a paragraph too long for a page continues at the top of the next" do
      doc = Builder.new() |> Builder.paragraph(lines(40)) |> written()

      assert Document.page_count!(doc) == 2
      assert length(baselines(doc, 1)) == 4
      assert_in_delta hd(baselines(doc, 1)), baseline(792 - 72, 12), 0.001
    end

    test "text wraps inside the left and right margins" do
      text = String.duplicate("The quick brown fox jumps over the lazy dog. ", 30)
      doc = Builder.new() |> Builder.paragraph(text) |> written()
      chars = Document.chars!(doc, 0)

      assert length(baselines(doc, 0)) > 1
      assert Enum.all?(chars, &(&1.bbox.x >= 72 - 0.01))
      assert Enum.all?(chars, &(&1.bbox.x + &1.bbox.width <= 612 - 72 + 0.01))
    end

    test "a newline starts a new line, and an empty one leaves a blank line" do
      doc = Builder.new() |> Builder.paragraph("one\ntwo\n\nfour") |> written()
      [one, two, four] = baselines(doc, 0)

      assert_in_delta one - two, 18, 0.01
      assert_in_delta two - four, 36, 0.01
    end

    test "a word wider than the line is split without losing a character" do
      word = String.duplicate("W", 200)
      doc = Builder.new() |> Builder.paragraph(word) |> written()
      chars = Document.chars!(doc, 0)

      assert length(chars) == 200
      assert length(baselines(doc, 0)) > 1
      assert Enum.all?(chars, &(&1.bbox.x + &1.bbox.width <= 612 - 72 + 0.01))
    end

    test "lines break by the font's real widths, accented letters and punctuation included" do
      # Helvetica advances at 12 points: é 6.672, em dash 12, ' 2.292, on a
      # 468-point line.
      for {char, per_line} <- [{"é", 70}, {"—", 39}, {"'", 204}] do
        doc = Builder.new() |> Builder.paragraph(String.duplicate(char, 300)) |> written()

        counts =
          doc
          |> Document.chars!(0)
          |> Enum.group_by(&Float.round(&1.bbox.y, 3))
          |> Enum.sort_by(fn {y, _} -> -y end)
          |> Enum.map(fn {_, chars} -> length(chars) end)

        assert hd(counts) == per_line, "#{char}: #{inspect(counts)}"
        assert Enum.sum(counts) == 300
      end
    end

    test "a paragraph leaves half its font size after it" do
      doc = Builder.new() |> Builder.paragraph("a") |> Builder.paragraph("b") |> written()
      [a, b] = baselines(doc, 0)

      assert_in_delta a - b, 18 + 6, 0.01
    end

    test "the space after a paragraph is dropped when the next starts a page" do
      doc =
        Builder.new() |> Builder.paragraph(lines(36)) |> Builder.paragraph("next") |> written()

      assert Document.page_count!(doc) == 2
      assert [top] = baselines(doc, 1)
      assert_in_delta top, baseline(792 - 72, 12), 0.001
    end

    test "a paragraph's font size sets its line box" do
      doc = Builder.new() |> Builder.paragraph("Big", font_size: 24) |> written()

      assert [first] = baselines(doc, 0)
      assert_in_delta first, baseline(792 - 72, 24), 0.001
    end

    test "a document's margins, font size and line height apply to every paragraph" do
      doc =
        Builder.new(margin_top: 100, margin_left: 50, font_size: 10, line_height: 2)
        |> Builder.paragraph("one\ntwo")
        |> written()

      [one, two] = baselines(doc, 0)

      assert_in_delta one, baseline(792 - 100, 10, 2), 0.001
      assert_in_delta one - two, 20, 0.01
      assert_in_delta hd(Document.chars!(doc, 0)).bbox.x, 50, 0.01
    end

    # Each line's box and advances stay inside the margins; only the glyph's
    # own outline crosses the edge.
    test "a flowing glyph whose ink crosses the page edge is refused" do
      for {settings, run, font} <- [
            {[margin_left: 0], {"j", italic: true}, :times},
            {[margin_left: 0], {"j", italic: true}, cff_family()},
            {[page_size: {200, 300}, margin_left: 196.6, margin_right: 0], {"f", italic: true},
             :times},
            {[margin_top: 0, line_height: 1.0], "É", :helvetica},
            {[page_size: {200, 11}, margin_top: 0, margin_bottom: 0, line_height: 0.9], "ç",
             :helvetica}
          ] do
        assert Builder.new(font: font) |> Builder.paragraph([run]) |> written()

        message =
          Builder.new([font: font] ++ settings) |> Builder.paragraph([run]) |> refusal()

        assert message =~ "op 0 on page 0"
        assert message =~ "past the edge of the page"
        assert message =~ "widen the margins"
      end
    end

    test "a list item's ink is checked like a paragraph's" do
      # The item's text starts 28.2 points in, leaving its italic f's advance
      # on the page and its ink past the right edge.
      message =
        Builder.new(page_size: {200, 300}, margin_left: 168.4, margin_right: 0, font: :times)
        |> Builder.paragraph("fine")
        |> Builder.bullet_list([[{"f", italic: true}]])
        |> refusal()

      assert message =~ "op 1 on page 0"
    end
  end

  describe "page/2" do
    test "the first content starts a page, so a leading page/2 adds no blank one" do
      doc = Builder.new() |> Builder.page(:a4) |> Builder.paragraph("A4") |> written()

      assert Document.page_count!(doc) == 1
      assert %{width: 595.0, height: 842.0} = Page.media_box!(Document.page!(doc, 0))
    end

    test "a block that draws nothing before it does not start a page either" do
      for empty <- [
            &Builder.paragraph(&1, ""),
            &Builder.paragraph(&1, "  "),
            &Builder.heading(&1, 1, ""),
            &Builder.bullet_list(&1, [])
          ] do
        doc =
          Builder.new()
          |> empty.()
          |> Builder.page(:a4)
          |> Builder.paragraph("A4")
          |> written()

        assert Document.page_count!(doc) == 1
        assert %{width: 595.0, height: 842.0} = Page.media_box!(Document.page!(doc, 0))
      end
    end

    test "without a size, the new page repeats the size before it" do
      doc =
        Builder.new()
        |> Builder.page({300, 400})
        |> Builder.paragraph("one")
        |> Builder.page()
        |> Builder.paragraph("two")
        |> written()

      assert Document.page_count!(doc) == 2

      for index <- 0..1 do
        assert %{width: 300.0, height: 400.0} = Page.media_box!(Document.page!(doc, index))
      end

      assert_in_delta hd(baselines(doc, 1)), baseline(400 - 72, 12), 0.001
    end
  end

  describe "fonts" do
    test ":auto sets Windows-1252 text in Helvetica" do
      assert %{"a" => "Helvetica"} =
               Builder.new() |> Builder.paragraph("a") |> written() |> fonts_by_text()
    end

    test ":auto sets every :auto paragraph in DejaVu Sans once one needs it" do
      doc =
        Builder.new()
        |> Builder.paragraph("Latin")
        |> Builder.paragraph(["Звіт ", {"κόσμε", italic: true}])
        |> written()

      fonts = doc |> Document.chars!(0) |> Enum.map(& &1.font) |> Enum.uniq()

      assert [font] = fonts
      assert font =~ "DejaVuSans"
      assert Document.text!(doc) =~ "Звіт κόσμε"
    end

    test "a paragraph's own font is not switched by :auto" do
      message =
        Builder.new()
        |> Builder.paragraph("Звіт")
        |> Builder.paragraph("Звіт", font: :helvetica)
        |> refusal()

      assert message =~ "op 1 on page 0: Helvetica cannot draw"
      assert message =~ "U+0417"
    end

    # U+10300 is outside the Basic Multilingual Plane, and U+1D5A0 is a
    # mathematical letter with a plain A of its own; DejaVu Sans covers both.
    test "a character beyond the Basic Multilingual Plane is drawn as itself" do
      doc = Builder.new() |> Builder.paragraph("x\u{10300}y \u{1D5A0}A") |> written()

      assert Document.text!(doc, 0) =~ "x\u{10300}y \u{1D5A0}A"
    end

    test "the built-in families set bold and italic runs in their faces" do
      runs = ["a", {"b", bold: true}, {"c", italic: true}, {"d", bold: true, italic: true}]

      for {family, faces} <- [
            times: ~w(Times-Roman Times-Bold Times-Italic Times-BoldItalic),
            courier: ~w(Courier Courier-Bold Courier-Oblique Courier-BoldOblique),
            helvetica: ~w(Helvetica Helvetica-Bold Helvetica-Oblique Helvetica-BoldOblique)
          ] do
        fonts =
          Builder.new(font: family) |> Builder.paragraph(runs) |> written() |> fonts_by_text()

        assert Enum.map(~w(a b c d), &fonts[&1]) == faces
      end
    end

    test "a FontFamily embeds its faces, CFF and TrueType alike" do
      bytes =
        Builder.new(font: cff_family())
        |> Builder.paragraph(["Звіт ", {"Очі", bold: true}])
        |> Builder.paragraph("Привет", font: FontFamily.new(regular: font("font_truetype.ttf")))
        |> Builder.to_binary!()

      assert bytes =~ "/FontFile3"
      assert bytes =~ "/FontFile2"

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)
      fonts = fonts_by_text(doc)

      assert Document.text!(doc) =~ "Звіт"
      assert fonts["З"] =~ "FixtureCFF-Regular"
      assert fonts["О"] =~ "FixtureCFF-Bold"
      assert fonts["П"] =~ "FixtureTrueType-Regular"
    end

    # The title spells the old subtype to show that only the font is relabeled.
    test "a CFF face is embedded as the OpenType font it is" do
      title = "/Subtype /CIDFontType0C"

      bytes =
        Builder.new(font: cff_family(), title: title)
        |> Builder.paragraph("Звіт")
        |> Builder.to_binary!(compress: false)

      # The font program is the one stream whose data starts with an sfnt tag.
      [dict] = Regex.run(~r{<<([^<>]*)>>\s*stream\r?\nOTTO}, bytes, capture: :all_but_first)

      assert dict =~ ~r{/Subtype\s*/OpenType\b}

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)

      assert Document.metadata!(doc).title == title
      assert Document.text!(doc) =~ "Звіт"
    end

    test "an embedded face wraps by its own widths, inside the margins" do
      text = String.duplicate("Привет Звіт Очі ", 40)

      doc =
        Builder.new(font: FontFamily.new(regular: font("font_truetype.ttf")))
        |> Builder.paragraph(text)
        |> written()

      chars = Document.chars!(doc, 0)

      assert length(baselines(doc, 0)) > 1
      assert Enum.all?(chars, &(&1.bbox.x + &1.bbox.width <= 612 - 72 + 0.01))
    end

    test "a run's color is drawn" do
      red = %RGB{r: 1.0, g: 0.0, b: 0.0}
      doc = Builder.new() |> Builder.paragraph(["a", {"b", color: red}]) |> written()
      colors = doc |> Document.chars!(0) |> Map.new(&{&1.text, &1.color})

      assert colors["b"] == red
      assert colors["a"] == %RGB{r: 0.0, g: 0.0, b: 0.0}
    end

    test "an integer color component is as good as a float" do
      doc =
        Builder.new() |> Builder.paragraph([{"b", color: %RGB{r: 1, g: 0, b: 0}}]) |> written()

      assert [%{color: color}] = Document.chars!(doc, 0)
      assert color == %RGB{r: 1.0, g: 0.0, b: 0.0}
    end

    test "a word wider than the line breaks between grapheme clusters" do
      word = String.duplicate("e\u0301", 120)
      family = FontFamily.new(regular: font("font_truetype.ttf"))
      doc = Builder.new(font: family) |> Builder.paragraph(word) |> written()

      lines = doc |> Document.text!() |> String.split("\n", trim: true)

      assert length(lines) > 1
      assert Enum.all?(lines, &String.starts_with?(&1, "e"))
    end

    test "a grapheme cluster stays whole when a style change falls inside it" do
      red = %RGB{r: 1.0, g: 0.0, b: 0.0}
      runs = Enum.flat_map(1..120, fn _ -> ["e", {"\u0301", color: red}] end)
      family = FontFamily.new(regular: font("font_truetype.ttf"))
      doc = Builder.new(font: family) |> Builder.paragraph(runs) |> written()

      lines = doc |> Document.text!() |> String.split("\n", trim: true)

      assert length(lines) > 1
      assert Enum.all?(lines, &String.starts_with?(&1, "e"))

      narrow = Builder.new(page_size: {164, 300})

      for runs <- [["😀\u200D😀"], ["😀", {"\u200D😀", color: red}]] do
        assert refusal(Builder.paragraph(narrow, runs)) =~ "wider than"
      end
    end

    test "a family used by several paragraphs crosses to the native side once" do
      family = cff_family()

      native =
        Builder.new(font: family)
        |> Builder.paragraph("a")
        |> Builder.paragraph("b", font: family)
        |> Builder.__native__()

      assert length(native.families) == 1

      assert [{:paragraph, %{font: {:family, 0}}}, {:paragraph, %{font: {:family, 0}}}] =
               native.ops
    end

    test "a face is only read when text uses it" do
      family = FontFamily.new(regular: font("font_cff_regular.otf"), bold: "not a font")

      assert {:ok, _} =
               Builder.new(font: family) |> Builder.paragraph("plain") |> Builder.to_binary()
    end
  end

  describe "headings" do
    test "a heading is set bold at a size scaled by its level" do
      for {level, size} <- [{1, 24.0}, {2, 18.0}, {3, 15.0}, {4, 13.2}] do
        [char | _] =
          Builder.new() |> Builder.heading(level, "Title") |> written() |> Document.chars!(0)

        assert char.font == "Helvetica-Bold"
        assert_in_delta char.font_size, size, 0.001
      end
    end

    test "its own font and size, and runs in italic" do
      doc =
        Builder.new()
        |> Builder.heading(2, ["Plain ", {"slanted", italic: true}], font: :times, font_size: 30)
        |> written()

      fonts = fonts_by_text(doc)

      assert fonts["P"] == "Times-Bold"
      assert fonts["s"] == "Times-BoldItalic"
      assert_in_delta hd(Document.chars!(doc, 0)).font_size, 30, 0.001
    end

    test "a heading starts the next page rather than end this one alone" do
      # 34 lines leave 30 points: room for a 19.8-point heading line, but not
      # for it, its 6.6-point gap and the next 18-point line.
      doc =
        Builder.new()
        |> Builder.paragraph(lines(34))
        |> Builder.heading(4, "Heading")
        |> Builder.paragraph("Body")
        |> written()

      assert Document.page_count!(doc) == 2
      refute Document.text!(doc, 0) =~ "Heading"
      assert Document.text!(doc, 1) =~ ~r/^Heading/
    end

    test "space between a heading and the next block does not part them" do
      doc =
        Builder.new()
        |> Builder.paragraph(lines(34))
        |> Builder.heading(4, "Heading")
        |> Builder.space(0)
        |> Builder.paragraph("Body")
        |> written()

      refute Document.text!(doc, 0) =~ "Heading"
      assert Document.text!(doc, 1) =~ ~r/^Heading/
    end

    test "consecutive headings move together with the line after them" do
      # 33 lines leave 48 points: room for one heading and the body's first
      # line, but not for two headings and that line.
      doc =
        Builder.new()
        |> Builder.paragraph(lines(33))
        |> Builder.heading(4, "First")
        |> Builder.heading(4, "Second")
        |> Builder.paragraph("Body")
        |> written()

      refute Document.text!(doc, 0) =~ "First"
      assert Document.text!(doc, 1) =~ ~r/^First\s+Second\s+Body/
    end

    test "consecutive headings at the start of the document" do
      doc =
        Builder.new()
        |> Builder.heading(1, "Title")
        |> Builder.heading(2, "Section")
        |> Builder.paragraph("Body")
        |> written()

      assert Document.text!(doc, 0) =~ ~r/^Title\s+Section\s+Body/
    end

    test "a block that draws nothing does not part a heading from its body" do
      # 33 lines leave 48 points: room for the heading and the empty block's
      # line, but not for the heading, its gap and the 36-point body line.
      for empty <- [
            &Builder.paragraph(&1, ""),
            &Builder.paragraph(&1, "  "),
            &Builder.heading(&1, 4, ""),
            &Builder.bullet_list(&1, [])
          ] do
        doc =
          Builder.new()
          |> Builder.paragraph(lines(33))
          |> Builder.heading(4, "Heading")
          |> empty.()
          |> Builder.paragraph("Body", font_size: 24)
          |> written()

        refute Document.text!(doc, 0) =~ "Heading"
        assert Document.text!(doc, 1) =~ ~r/^Heading\s+Body/
      end
    end

    test "a heading that fits with the line after it stays" do
      doc =
        Builder.new()
        |> Builder.paragraph(lines(33))
        |> Builder.heading(4, "Heading")
        |> Builder.paragraph("Body")
        |> written()

      assert Document.page_count!(doc) == 1
    end

    test "a family without a bold face cannot set a heading" do
      family = FontFamily.new(regular: font("font_truetype.ttf"))
      message = Builder.new(font: family) |> Builder.heading(1, "Title") |> refusal()

      assert message =~ "has no bold face"
    end
  end

  describe "lists" do
    defp chars_by_line(doc, page) do
      doc
      |> Document.chars!(page)
      |> Enum.group_by(&Float.round(&1.bbox.y, 3))
      |> Enum.sort_by(fn {y, _} -> -y end)
      |> Enum.map(fn {_, chars} -> Enum.sort_by(chars, & &1.bbox.x) end)
    end

    test "bullets sit in a column and the items' text starts at one x" do
      doc = Builder.new() |> Builder.bullet_list(["one", "two"]) |> written()
      [[bullet1, text1 | _], [bullet2, text2 | _]] = chars_by_line(doc, 0)

      assert bullet1.text == "•" and bullet2.text == "•"
      assert_in_delta text1.bbox.x, text2.bbox.x, 0.001
      assert_in_delta bullet1.bbox.x, 72 + 18, 0.01
      assert text1.bbox.x > bullet1.bbox.x + bullet1.bbox.width
    end

    test "numbers are right-aligned so the text lines up" do
      items = Enum.map(1..12, &"item #{&1}")
      doc = Builder.new() |> Builder.numbered_list(items) |> written()
      lines = chars_by_line(doc, 0)

      dots =
        Enum.map(lines, fn chars ->
          dot = Enum.find(chars, &(&1.text == "."))
          dot.bbox.x + dot.bbox.width
        end)

      assert length(lines) == 12
      assert Enum.all?(dots, &(abs(&1 - hd(dots)) < 0.01))
      assert Document.text!(doc) =~ "12."
    end

    test "numbering carries on across a page break" do
      items = Enum.map(1..50, &"item #{&1}")
      doc = Builder.new() |> Builder.numbered_list(items) |> written()

      assert Document.page_count!(doc) == 2
      assert Document.text!(doc, 1) =~ ~r/^37\./
    end

    test "Roman and alphabetic numbering, from a start" do
      roman = Builder.new() |> Builder.numbered_list(["a", "b"], style: :lower_roman, start: 4)
      alpha = Builder.new() |> Builder.numbered_list(["a", "b"], style: :lower_alpha, start: 26)

      assert roman |> written() |> Document.text!() =~ ~r/iv\..*\n.*v\./s
      assert alpha |> written() |> Document.text!() =~ ~r/z\..*\n.*aa\./s
    end

    test "an item longer than a line wraps under its own text" do
      long = String.duplicate("wrapping words ", 40)
      doc = Builder.new() |> Builder.bullet_list([long]) |> written()
      [[_bullet, first | _], [second | _] | _] = chars_by_line(doc, 0)

      assert_in_delta first.bbox.x, second.bbox.x, 0.001
    end

    test "a marker the family cannot draw is refused" do
      message = Builder.new(font: cff_family()) |> Builder.bullet_list(["a"]) |> refusal()

      assert message =~ "has no glyph for '•'"
    end

    test "malformed list arguments raise" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/3999/, fn ->
        Builder.numbered_list(builder, ["a", "b"], style: :lower_roman, start: 3999)
      end

      assert_raise ArgumentError, ~r/:style/, fn ->
        Builder.numbered_list(builder, ["a"], style: :upper_roman)
      end

      assert_raise ArgumentError, ~r/:start/, fn ->
        Builder.numbered_list(builder, ["a"], start: 0)
      end

      assert_raise ArgumentError, ~r/stop at 2147483647/, fn ->
        Builder.numbered_list(builder, ["one"], start: 18_446_744_073_709_551_615)
      end

      assert %Builder{} = Builder.numbered_list(builder, ["last"], start: 2_147_483_647)

      assert_raise ArgumentError, ~r/invalid item/, fn ->
        Builder.bullet_list(builder, [untyped(1)])
      end
    end
  end

  describe "space and rules" do
    test "space adds to the gap before the next block" do
      doc =
        Builder.new()
        |> Builder.paragraph("a")
        |> Builder.space(20)
        |> Builder.paragraph("b")
        |> written()

      [a, b] = baselines(doc, 0)

      assert_in_delta a - b, 18 + 6 + 20, 0.01
    end

    test "a block that draws nothing leaves the gap as it was" do
      for empty <- [
            &Builder.paragraph(&1, "", font_size: 4),
            &Builder.heading(&1, 1, ""),
            &Builder.bullet_list(&1, [])
          ] do
        doc =
          Builder.new()
          |> Builder.paragraph("a")
          |> Builder.space(20)
          |> empty.()
          |> Builder.paragraph("b")
          |> written()

        [a, b] = baselines(doc, 0)

        assert_in_delta a - b, 18 + 6 + 20, 0.01
      end
    end

    test "space is dropped at a page break" do
      doc =
        Builder.new()
        |> Builder.paragraph(lines(36))
        |> Builder.space(100)
        |> Builder.paragraph("next")
        |> written()

      assert_in_delta hd(baselines(doc, 1)), baseline(792 - 72, 12), 0.001
    end

    test "a rule is a thin gray line across the content width, in a box of the text size" do
      doc =
        Builder.new()
        |> Builder.paragraph("a")
        |> Builder.rule()
        |> Builder.paragraph("b")
        |> written()

      assert [line] = Document.lines!(doc)
      assert_in_delta line.bbox.x, 72, 0.01
      assert_in_delta line.bbox.x + line.bbox.width, 540, 0.01
      # "a" ends at 702, its 6-point gap brings the rule's box to 696..684.
      assert_in_delta line.bbox.y + line.bbox.height / 2, 690, 0.5
      assert_in_delta line.stroke_width, 0.5, 0.001
      assert_in_delta List.last(baselines(doc, 0)), baseline(684, 12), 0.001
    end

    test "a rule and text are drawn in the order they were added" do
      first_drawn = fn builder ->
        body = content(builder)
        {text, _} = :binary.match(body, "BT")
        {rule, _} = :binary.match(body, " l\n")
        if text < rule, do: :text, else: :rule
      end

      rule_first = Builder.new() |> Builder.rule() |> Builder.text_at({72, 715}, "MMMM")
      text_first = Builder.new() |> Builder.text_at({72, 715}, "MMMM") |> Builder.rule()

      assert first_drawn.(rule_first) == :rule
      assert first_drawn.(text_first) == :text
    end

    test "negative space raises" do
      assert_raise ArgumentError, ~r/:points/, fn -> Builder.space(Builder.new(), -1) end
    end
  end

  describe "text_at/4" do
    test "draws one line with its baseline at the point" do
      doc = Builder.new() |> Builder.text_at({100, 200}, "Mark") |> written()
      [first | _] = Document.chars!(doc, 0)

      assert Document.page_count!(doc) == 1
      assert_in_delta first.bbox.x, 100, 0.01
      assert_in_delta first.bbox.y, 200, 0.01
    end

    test "stays outside the flow, on the current page, and may sit in the margins" do
      doc =
        Builder.new()
        |> Builder.text_at({10, 10}, "corner")
        |> Builder.paragraph("first")
        |> Builder.page()
        |> Builder.text_at({300, 400}, "second page")
        |> written()

      fonts = doc |> Document.chars!(0) |> Enum.map_join(& &1.text)

      assert fonts =~ "corner"
      assert_in_delta Enum.max(baselines(doc, 0)), baseline(792 - 72, 12), 0.001
      assert Document.text!(doc, 1) =~ "second page"
    end

    test "takes runs, a font and a size" do
      doc =
        Builder.new()
        |> Builder.text_at({72, 72}, ["a", {"b", bold: true}], font: :times, font_size: 20)
        |> written()

      fonts = fonts_by_text(doc)

      assert fonts["a"] == "Times-Roman"
      assert fonts["b"] == "Times-Bold"
      assert_in_delta hd(Document.chars!(doc, 0)).font_size, 20, 0.001
    end

    test "counts for :auto" do
      [char | _] =
        Builder.new() |> Builder.text_at({72, 72}, "Звіт") |> written() |> Document.chars!(0)

      assert char.font =~ "DejaVuSans"
    end

    test "a line past the edge of the page is refused" do
      for {x, y} <- [{580, 100}, {72, 788}, {72, 1}, {-1, 100}] do
        message = Builder.new() |> Builder.text_at({x, y}, "Wide text") |> refusal()

        assert message =~ "past the edge of the page"
      end
    end

    # Each point keeps the advances and the font's ascent and descent on the
    # page; only the glyph's own outline crosses the edge.
    test "a glyph whose ink crosses the edge is refused" do
      for {x, y, run, font} <- [
            {72, 782, "É", :helvetica},
            {72, 2.6, "Ç", :helvetica},
            {607, 100, {"f", italic: true}, :times},
            {1, 100, {"j", italic: true}, cff_family()}
          ] do
        builder = Builder.new() |> Builder.text_at({x, y}, [run], font: font)

        assert refusal(builder) =~ "past the edge of the page"
      end
    end

    test "text that draws nothing needs no face but still starts the first page" do
      regular_only = FontFamily.new(regular: font("font_truetype.ttf"))

      doc =
        Builder.new()
        |> Builder.text_at({72, 72}, [{" ", italic: true}], font: regular_only)
        |> Builder.page({300, 300})
        |> written()

      assert Document.page_count!(doc) == 2
    end

    test "a character its font cannot draw is refused" do
      message = Builder.new() |> Builder.text_at({72, 72}, "Звіт", font: :helvetica) |> refusal()

      assert message =~ "Helvetica cannot draw"
    end

    test "malformed arguments raise" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/one line/, fn ->
        Builder.text_at(builder, {72, 72}, "a\nb")
      end

      assert_raise ArgumentError, ~r/invalid point,/, fn ->
        Builder.text_at(builder, {1.0e39, 72}, "a")
      end

      assert_raise ArgumentError, ~r/too large/, fn ->
        Builder.new(page_size: {612, 1.0e9}) |> Builder.text_at({72, 72}, "a")
      end

      assert_raise FunctionClauseError, fn ->
        Builder.text_at(builder, {untyped("72"), 72}, "a")
      end

      assert_raise FunctionClauseError, fn -> Builder.text_at(builder, untyped(72), "a") end
    end
  end

  describe "text_in_rect/4" do
    @box %Rect{x: 100.0, y: 500.0, width: 150.0, height: 90.0}
    @sentence "The quick brown fox jumps over the lazy dog again"

    defp boxed(text, opts \\ []) do
      Builder.new() |> Builder.text_in_rect(@box, text, opts) |> written()
    end

    defp right_edge(char), do: char.bbox.x + char.bbox.width

    test "wraps within the box, its first line at the top edge" do
      doc = boxed(@sentence)
      lines = chars_by_line(doc, 0)

      assert length(lines) == 2
      assert_in_delta hd(hd(lines)).bbox.x, 100, 0.001

      for char <- List.flatten(lines) do
        assert char.bbox.x >= 100 - 0.001
        assert right_edge(char) <= 250 + 0.001
      end

      assert baselines(doc, 0) == Enum.map([590, 572], &Float.round(baseline(&1, 12), 3))
    end

    test "aligns each line left, center or right" do
      for align <- [:left, :center, :right],
          line <- chars_by_line(boxed(@sentence, align: align), 0) do
        left = hd(line).bbox.x - 100
        right = 250 - right_edge(List.last(line))

        case align do
          :left -> assert_in_delta left, 0, 0.001
          :center -> assert_in_delta left, right, 0.001
          :right -> assert_in_delta right, 0, 0.001
        end
      end
    end

    test "breaks lines at \\n and takes runs, a font and a size" do
      doc =
        Builder.new()
        |> Builder.text_in_rect(@box, ["a\n", {"b", bold: true}], font: :times, font_size: 20)
        |> written()

      fonts = fonts_by_text(doc)

      assert length(chars_by_line(doc, 0)) == 2
      assert fonts["a"] == "Times-Roman"
      assert fonts["b"] == "Times-Bold"
      assert_in_delta hd(Document.chars!(doc, 0)).font_size, 20, 0.001
    end

    test "counts for :auto" do
      [char | _] = "Звіт" |> boxed() |> Document.chars!(0)

      assert char.font =~ "DejaVuSans"
    end

    test "stays outside the flow" do
      doc =
        Builder.new()
        |> Builder.text_in_rect(%Rect{@box | y: 100.0}, "boxed")
        |> Builder.paragraph("flowing")
        |> written()

      assert_in_delta Enum.max(baselines(doc, 0)), baseline(792 - 72, 12), 0.001
    end

    test "normalizes reversed corners" do
      reversed = %Rect{x: 250.0, y: 590.0, width: -150.0, height: -90.0}
      bboxes = fn doc -> doc |> Document.chars!(0) |> Enum.map(& &1.bbox) end
      doc = Builder.new() |> Builder.text_in_rect(reversed, @sentence) |> written()

      assert bboxes.(doc) == bboxes.(boxed(@sentence))
    end

    test "text the box cannot hold is refused, and text that just fits is not" do
      fits = %Rect{x: 72.0, y: 600.0, width: 200.0, height: 3 * 18.0}
      short = %Rect{fits | height: 3 * 18.0 - 0.1}
      text = "one\ntwo\nthree"

      assert {:ok, _} = Builder.new() |> Builder.text_in_rect(fits, text) |> Builder.to_binary()

      message = Builder.new() |> Builder.text_in_rect(short, text) |> refusal()
      assert message =~ "takes 3 lines, 54 points, more than the 53.9-point box"
    end

    # Nine Courier advances of 7.2 sum a hair above 64.8.
    test "text exactly as wide as the box stays on one line" do
      box = %Rect{x: 72.0, y: 600.0, width: 64.8, height: 18.0}

      for text <- ["a a a a a", ["a a ", {"a", bold: true}, " a a"], "aaaaaaaaa"] do
        builder = Builder.new() |> Builder.text_in_rect(box, text, font: :courier)

        assert {:ok, _} = Builder.to_binary(builder)
      end
    end

    # 8.8 × 1.5 and 12.8 × 1.5 round a hair above 13.2 and 19.2.
    test "a fractional size fits a box exactly one line tall" do
      for {size, height} <- [{8.8, 13.2}, {12.8, 19.2}] do
        box = %Rect{x: 72.0, y: 600.0, width: 200.0, height: height}
        builder = Builder.new() |> Builder.text_in_rect(box, "a", font_size: size)

        assert {:ok, _} = Builder.to_binary(builder)
      end
    end

    test "a character wider than the box is refused" do
      narrow = %Rect{x: 72.0, y: 600.0, width: 5.0, height: 18.0}
      message = Builder.new() |> Builder.text_in_rect(narrow, "W") |> refusal()

      assert message =~ "wider than the 5-point box; reduce the font size or widen the box"
    end

    test "a character its font cannot draw is refused" do
      message = Builder.new() |> Builder.text_in_rect(@box, "Звіт", font: :helvetica) |> refusal()

      assert message =~ "Helvetica cannot draw"
    end

    # Summed advances land a hair past the right edge.
    test "a right-aligned line may end at the edge of the page" do
      edge = %Rect{x: 0.0, y: 600.0, width: 612.0, height: 54.0}
      builder = Builder.new() |> Builder.text_in_rect(edge, "abcdefg", align: :right)

      assert {:ok, _} = Builder.to_binary(builder)
    end

    test "centers a line in a box far wider than it" do
      wide = %Rect{x: -1.0e18 + 256.0, y: 600.0, width: 2.0e18, height: 54.0}
      doc = Builder.new() |> Builder.text_in_rect(wide, "Hello", align: :center) |> written()
      [word] = Document.words!(doc, 0)

      assert_in_delta word.bbox.x + word.bbox.width / 2, 256, 0.01
    end

    test "only the text, not the box, must be on the page" do
      below = %Rect{x: 72.0, y: -100.0, width: 200.0, height: 300.0}
      above = %Rect{x: 72.0, y: 700.0, width: 200.0, height: 300.0}

      assert {:ok, _} = Builder.new() |> Builder.text_in_rect(below, "a") |> Builder.to_binary()
      assert {:ok, _} = Builder.new() |> Builder.text_in_rect(above, "") |> Builder.to_binary()

      message = Builder.new() |> Builder.text_in_rect(above, "a") |> refusal()
      assert message =~ "past the edge of the page"
    end

    test "text that draws nothing is accepted" do
      doc = boxed(" \n ")

      assert Document.page_count!(doc) == 1
      assert Document.chars!(doc, 0) == []
    end

    test "text that draws nothing needs no face but still starts the first page" do
      regular_only = FontFamily.new(regular: font("font_truetype.ttf"))

      doc =
        Builder.new()
        |> Builder.text_in_rect(@box, [{" ", italic: true}], font: regular_only)
        |> Builder.page({300, 300})
        |> written()

      assert Document.page_count!(doc) == 2
    end

    test "malformed arguments raise" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/unknown keys \[:valign\]/, fn ->
        Builder.text_in_rect(builder, @box, "a", valign: :top)
      end

      assert_raise ArgumentError, ~r/invalid :align, expected one of/, fn ->
        Builder.text_in_rect(builder, @box, "a", align: :justify)
      end

      for rect <- [%Rect{@box | width: 0}, %Rect{@box | height: 0}] do
        assert_raise ArgumentError, ~r/invalid rect, expected a positive number/, fn ->
          Builder.text_in_rect(builder, rect, "a")
        end
      end

      assert_raise ArgumentError, ~r/does not fit the 10.0-point box/, fn ->
        Builder.text_in_rect(builder, %Rect{@box | height: 10}, "a")
      end

      assert_raise ArgumentError, ~r/invalid rect/, fn ->
        Builder.text_in_rect(builder, %Rect{@box | x: untyped("0")}, "a")
      end

      assert_raise ArgumentError, ~r/too large/, fn ->
        Builder.new(page_size: {612, 1.0e9}) |> Builder.text_in_rect(@box, "a")
      end

      assert_raise FunctionClauseError, fn ->
        Builder.text_in_rect(builder, untyped({72, 72}), "a")
      end
    end
  end

  describe "table/3" do
    @fill %RGB{r: 0.75, g: 0.75, b: 0.75}

    defp tabled(rows, opts \\ []), do: Builder.new() |> Builder.table(rows, opts) |> written()

    defp grid(doc, page \\ 0) do
      for path <- Document.paths!(doc, page), path.stroke_color != nil, do: path.bbox
    end

    defp fills(doc, page) do
      for path <- Document.paths!(doc, page), path.fill_color != nil, do: path.bbox
    end

    defp page_lines(doc, page) do
      doc |> chars_by_line(page) |> Enum.map(&Enum.map_join(&1, fn char -> char.text end))
    end

    defp page_count(doc), do: Document.page_count!(doc)

    defp body_rows(count), do: for(row <- 1..count, do: ["row #{row}"])

    test "lays rows out from the top margin in equal columns across the content width" do
      doc = tabled([["a", "b"], ["c", "d"]])

      assert grid(doc) == [
               %Rect{x: 72.0, y: 694.0, width: 234.0, height: 26.0},
               %Rect{x: 306.0, y: 694.0, width: 234.0, height: 26.0},
               %Rect{x: 72.0, y: 668.0, width: 234.0, height: 26.0},
               %Rect{x: 306.0, y: 668.0, width: 234.0, height: 26.0}
             ]

      [a | _] = Document.chars!(doc, 0)
      assert_in_delta a.bbox.x, 76, 0.001
      assert baselines(doc, 0) == Enum.map([716, 690], &Float.round(baseline(&1, 12), 3))
    end

    test "fixed columns take their points and weighted ones share the rest" do
      doc = tabled([["a", "b", "c"]], column_widths: [100, {:weight, 1}, {:weight, 3}])

      assert Enum.map(grid(doc), & &1.width) == [100.0, 92.0, 276.0]
    end

    test "an :auto column is as wide as its widest line, padding included" do
      doc = tabled([["Quantity", "x"], ["Qty\nItems in stock", "y"]], column_widths: [:auto, 50])
      line = doc |> chars_by_line(0) |> List.last()
      [auto, fixed | _] = grid(doc)

      assert Enum.map_join(line, & &1.text) == "Items in stock"
      assert_in_delta auto.width, right_edge(List.last(line)) - hd(line).bbox.x + 8, 0.01
      assert fixed.width == 50.0
    end

    test ":auto columns too wide for the page shrink to fit it" do
      long = String.duplicate("word ", 60)
      doc = tabled([[long, long]], column_widths: [:auto, :auto])
      [first, second] = grid(doc)

      assert_in_delta first.width + second.width, 468, 0.001
      assert_in_delta first.width, second.width, 0.001
    end

    test "aligns each column, and a cell's own alignment overrides it" do
      doc =
        tabled([["left", "right"], [Builder.cell("centered", align: :center), "right"]],
          align: [:left, :right]
        )

      [[left, right], [centered, right2]] =
        doc
        |> chars_by_line(0)
        |> Enum.map(fn chars -> Enum.chunk_by(chars, &(&1.bbox.x < 306)) end)

      assert_in_delta hd(left).bbox.x, 76, 0.001
      assert_in_delta right_edge(List.last(right)), 536, 0.001
      assert_in_delta right_edge(List.last(right2)), 536, 0.001
      assert_in_delta hd(centered).bbox.x - 76, 302 - right_edge(List.last(centered)), 0.001
    end

    test "header rows are bold, filled, and repeated on every page the table reaches" do
      doc = tabled([["Header"] | body_rows(40)], header_rows: 1, header_fill: @fill)

      assert page_count(doc) == 2

      for page <- 0..1 do
        [first | _] = page_lines(doc, page)
        assert first == "Header"
        assert fonts_by_text(doc)["H"] == "Helvetica-Bold"
        assert [%Rect{y: 694.0, height: 26.0}] = fills(doc, page)
      end

      rows = for page <- 0..1, line <- tl(page_lines(doc, page)), do: line
      assert rows == Enum.map(1..40, &"row #{&1}")
    end

    test "fills are painted first and the grid last" do
      body =
        Builder.new() |> Builder.table([["a"]], header_rows: 1, header_fill: @fill) |> content()

      [fill, text, grid] =
        Enum.map(["re\nf\n", "BT\n", "re\nS\n"], &(:binary.match(body, &1) |> elem(0)))

      assert fill < text and text < grid
    end

    test "stroke_color: nil draws no grid" do
      assert grid(tabled([["a"]], stroke_color: nil)) == []
    end

    test "a row taller than the rest of the page continues on the next with no line lost" do
      doc = tabled([["Header"], [lines(60)]], header_rows: 1)
      text = for page <- 0..1, line <- tl(page_lines(doc, page)), do: line

      assert page_count(doc) == 2
      assert text == String.split(lines(60), "\n")
      assert hd(page_lines(doc, 1)) == "Header"

      # The first part fills the page down to the bottom margin.
      assert Enum.min_by(grid(doc, 0), & &1.y).y >= 72 - 0.001
    end

    test "rows with no text break the page like any other" do
      doc = tabled(List.duplicate([""], 40))

      assert page_count(doc) == 2

      for page <- 0..1, box <- grid(doc, page) do
        assert box.y >= 72 - 0.001
      end
    end

    test "a row that does not fit even one line moves to the next page whole" do
      doc = tabled(body_rows(25))

      assert length(page_lines(doc, 0)) == 24
      assert page_lines(doc, 1) == ["row 25"]
      assert [%Rect{y: 694.0}] = grid(doc, 1)
    end

    test "a heading before a table stays with the table's first row" do
      doc =
        Builder.new()
        |> Builder.paragraph(lines(33))
        |> Builder.heading(1, "Title")
        |> Builder.table([["a"]])
        |> written()

      refute "Title" in page_lines(doc, 0)
      assert hd(page_lines(doc, 1)) == "Title"
    end

    test "a paragraph after a table follows its space, dropped at a page break" do
      doc = Builder.new() |> Builder.table([["a"]]) |> Builder.paragraph("after") |> written()
      assert Enum.min(baselines(doc, 0)) == Float.round(baseline(694 - 6, 12), 3)

      doc =
        Builder.new()
        |> Builder.table(body_rows(23), padding: 5)
        |> Builder.paragraph("after")
        |> written()

      assert page_lines(doc, 1) == ["after"]
      assert baselines(doc, 1) == [Float.round(baseline(720, 12), 3)]
    end

    test "an empty table adds nothing" do
      doc = Builder.new() |> Builder.table([]) |> Builder.paragraph("text") |> written()

      assert grid(doc) == []
      assert baselines(doc, 0) == [Float.round(baseline(720, 12), 3)]
    end

    test "takes a font and a size, and counts for :auto" do
      doc = tabled([["a"]], font: :times, font_size: 20)
      [char] = Document.chars!(doc, 0)

      assert char.font == "Times-Roman"
      assert_in_delta char.font_size, 20, 0.001
      assert [%Rect{height: 38.0}] = grid(doc)

      [char | _] = [["Звіт"]] |> tabled() |> Document.chars!(0)
      assert char.font =~ "DejaVuSans"
    end

    test "a character wider than its cell is refused, naming the cell" do
      message =
        Builder.new() |> Builder.table([["a", "W"]], column_widths: [100, 10]) |> refusal()

      assert message =~ "op 0 on page 0: \"W\""
      assert message =~ "2-point text width of the cell at row 0, column 1"
    end

    test "header rows need a bold face" do
      family = FontFamily.new(regular: font("font_truetype.ttf"))
      message = Builder.new() |> Builder.table([["H"]], header_rows: 1, font: family) |> refusal()

      assert message =~ "no bold face"
    end

    test "header rows and a line taller than a page are refused" do
      message = Builder.new() |> Builder.table([[lines(36)], ["a"]], header_rows: 1) |> refusal()

      assert message =~
               "needs 682 points to start row 1 below its header rows, more than " <>
                 "the 648-point content height"
    end

    test "fixed and :auto columns that cannot fit the content width are refused" do
      message =
        Builder.new() |> Builder.table([["a", "Wide"]], column_widths: [460, :auto]) |> refusal()

      assert message =~ "the table's columns need at least"
      assert message =~ "more than the 468-point content width"
    end

    test "weighted columns left no room for text are refused" do
      for widths <- [[460, {:weight, 1}], [:auto, {:weight, 1}]] do
        message =
          Builder.new()
          |> Builder.table([[String.duplicate("word ", 200), "a"]], column_widths: widths)
          |> refusal()

        assert message =~ "leave its weighted columns no room"
      end
    end

    test "malformed arguments raise" do
      for {rows, opts, message} <- [
            {[["a", "b"], ["c"]], [], "row 1 covers 1 columns and row 0 covers 2"},
            {[[Builder.cell("a", rowspan: 2)]], [], "spans 2 rows, past the table's last row"},
            {[[Builder.cell("a", rowspan: 2), "b"], ["c"]], [header_rows: 1],
             "spans from the header rows into the body"},
            {[["a"]], [header_rows: 2], "invalid :header_rows, the table has 1 rows: 2"},
            {[["a"]], [column_widths: [10, 10]],
             "expected one for each of the table's 1 columns"},
            {[["a"]], [align: [:left, :right]], "expected one for each of the table's 1 columns"},
            {[["a", "b"]], [column_widths: [300, 300]], "fixed columns of 600.0 points exceed"},
            {[["a"]], [column_widths: [8]], "a 8.0-point column leaves no room"},
            {[["a"]], [column_widths: [:wide]], "expected a number, {:weight, number} or :auto"},
            {[["a"]], [header_rows: -1], "invalid :header_rows, expected a non-negative"},
            {[["a"]], [stroke_color: nil, stroke_width: 2], ":stroke_width has no effect"},
            {[:a], [], "invalid row, expected a list of cells"},
            {[[:a]], [], "invalid cell, expected a string"},
            {[[]], [], "row 0 covers no columns"},
            {[["a", Builder.cell("b", rowspan: 2)], []], [], "row 1 leaves column 0 empty"}
          ] do
        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          Builder.table(Builder.new(), untyped(rows), untyped(opts))
        end
      end
    end

    test "a line taller than the page raises" do
      assert_raise ArgumentError, ~r/does not fit the 648.0-point content height/, fn ->
        Builder.table(Builder.new(), [["a"]], font_size: 500)
      end
    end
  end

  describe "cell/2" do
    test "a colspan cell takes the width of the columns it covers" do
      doc = tabled([[Builder.cell("wide", colspan: 2)], ["a", "b"]])

      assert [%Rect{width: 468.0}, %Rect{width: 234.0}, %Rect{width: 234.0}] = grid(doc)
    end

    test "a rowspan cell covers its rows, and the last of them grows to hold it" do
      doc = tabled([[Builder.cell("one\ntwo\nthree", rowspan: 2), "a"], ["b"]])

      assert [
               %Rect{x: 72.0, y: 658.0, height: 62.0},
               %Rect{x: 306.0, y: 694.0, height: 26.0},
               %Rect{x: 306.0, y: 658.0, height: 36.0}
             ] = grid(doc)
    end

    test "a cell's fill overrides the header fill" do
      red = %RGB{r: 1.0, g: 0.0, b: 0.0}

      doc =
        tabled([[Builder.cell("a", fill_color: red), "b"]], header_rows: 1, header_fill: @fill)

      assert [red, @fill] ==
               for(path <- Document.paths!(doc, 0), path.fill_color, do: path.fill_color)
    end

    test "rows a rowspan joins move to the next page together" do
      rows = for row <- 1..23, do: ["row #{row}", "x"]
      doc = tabled(rows ++ [[Builder.cell("joined", rowspan: 2), "a"], ["b"]])

      assert length(page_lines(doc, 0)) == 23
      assert page_lines(doc, 1) == ["joineda", "b"]
    end

    test "rows a rowspan joins that are taller than a page are refused" do
      message =
        Builder.new()
        |> Builder.table([[Builder.cell(lines(40), rowspan: 2), "a"], ["b"]])
        |> refusal()

      assert message =~ "to start rows 0 to 1 below its header rows"
    end

    test "cells after a rowspan fill the columns it leaves free" do
      doc = tabled([["a", Builder.cell("b", rowspan: 2), "c"], ["d", "e"]])
      [_a, _b, _c, d, e] = grid(doc)

      assert d.x == 72.0
      assert e.x == 384.0
    end

    test "overlapping spans raise" do
      rows = [["a", Builder.cell("b", rowspan: 2)], [Builder.cell("c", colspan: 2)]]

      assert_raise ArgumentError, ~r/overlaps a cell spanning from an earlier row/, fn ->
        Builder.table(Builder.new(), rows)
      end
    end

    test "malformed options raise" do
      for {opts, message} <- [
            {[colspan: 0], "invalid :colspan, expected a positive integer: 0"},
            {[rowspan: 1.5], "invalid :rowspan, expected a positive integer: 1.5"},
            {[align: :middle], "invalid :align"},
            {[fill_color: :red], "invalid :fill_color"}
          ] do
        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          Builder.cell("a", untyped(opts))
        end
      end
    end
  end

  describe "drawing" do
    @gray %RGB{r: 0.5, g: 0.5, b: 0.5}
    @black %RGB{r: 0.0, g: 0.0, b: 0.0}
    @red %RGB{r: 1.0, g: 0.0, b: 0.0}

    defp drawn(builder), do: builder |> written() |> Document.paths!()

    defp distance({x1, y1}, {x2, y2}), do: :math.sqrt((x1 - x2) ** 2 + (y1 - y2) ** 2)

    defp ends(operations) do
      for op <- operations, op != :close_path, do: op |> Tuple.to_list() |> Enum.take(-2)
    end

    test "a rectangle is drawn from a Rect, reversed corners normalized" do
      for rect <- [
            %Rect{x: 72, y: 600, width: 100, height: 50},
            %Rect{x: 172, y: 650, width: -100, height: -50}
          ] do
        assert [path] =
                 Builder.new()
                 |> Builder.rect(rect, fill_color: @gray, stroke_color: nil)
                 |> drawn()

        assert path.operations == [{:rectangle, 72.0, 600.0, 100.0, 50.0}]
        assert path.fill_color == @gray
        assert path.stroke_color == nil
      end
    end

    test "an extracted bbox draws back as a rectangle around its text" do
      doc = Builder.new() |> Builder.paragraph("Mark") |> written()
      [word] = Document.words!(doc, 0)

      assert [path] = Builder.new() |> Builder.rect(word.bbox) |> drawn()
      assert path.bbox == word.bbox
    end

    test "lines, polygons and curves read back as written" do
      [line, polygon, bezier] =
        Builder.new()
        |> Builder.line({72, 580}, {540, 580}, stroke_width: 2.5)
        |> Builder.polygon([{100, 100}, {200, 100}, {150, 180}], fill_color: @red)
        |> Builder.bezier({72, 300}, {150, 400}, {250, 200}, {340, 300}, stroke_color: @red)
        |> drawn()

      assert line.operations == [{:move_to, 72.0, 580.0}, {:line_to, 540.0, 580.0}]
      assert {line.stroke_color, line.fill_color, line.stroke_width} == {@black, nil, 2.5}

      assert polygon.operations == [
               {:move_to, 100.0, 100.0},
               {:line_to, 200.0, 100.0},
               {:line_to, 150.0, 180.0},
               :close_path
             ]

      assert {polygon.stroke_color, polygon.fill_color} == {@black, @red}

      assert bezier.operations == [
               {:move_to, 72.0, 300.0},
               {:curve_to, 150.0, 400.0, 250.0, 200.0, 340.0, 300.0}
             ]

      assert bezier.stroke_color == @red
    end

    test "a zero-width outline is drawn as the thinnest line and reads back as zero" do
      builder = Builder.new() |> Builder.line({72, 600}, {540, 600}, stroke_width: 0)

      assert content(builder) =~ "0 w\n72 600 m\n"
      assert [%{stroke_width: +0.0}] = drawn(builder)
    end

    test "an extracted path draws back unchanged" do
      original =
        Builder.new()
        |> Builder.path([
          {:move_to, 100, 100},
          {:line_to, 200, 100},
          {:curve_to, 250, 100, 250, 200, 200, 200},
          :close_path,
          {:rectangle, 300, 300, 50, 50}
        ])
        |> drawn()

      [path] = original

      redrawn =
        Builder.new()
        |> Builder.path(path.operations,
          stroke_color: path.stroke_color,
          fill_color: path.fill_color,
          stroke_width: path.stroke_width
        )
        |> drawn()

      assert redrawn == original
    end

    test "circles and ellipses are closed curves on their outline" do
      [circle, ellipse] =
        Builder.new()
        |> Builder.circle({300, 400}, 50)
        |> Builder.ellipse({300, 200}, {80, 40}, fill_color: @red)
        |> drawn()

      assert [{:move_to, _, _} | curves] = circle.operations
      assert length(curves) == 5 and List.last(curves) == :close_path

      for [x, y] <- ends(circle.operations) do
        assert_in_delta distance({x, y}, {300, 400}), 50, 0.001
      end

      for [x, y] <- ends(ellipse.operations) do
        assert_in_delta ((x - 300) / 80) ** 2 + ((y - 200) / 40) ** 2, 1, 0.001
      end

      assert_in_delta circle.bbox.width, 100, 0.01
      assert_in_delta ellipse.bbox.height, 80, 0.01
      assert ellipse.fill_color == @red
    end

    test "an arc runs counter-clockwise, or clockwise when the end angle is lower" do
      [quarter, three_quarters, full] =
        Builder.new()
        |> Builder.arc({100, 100}, 50, 0, 90)
        |> Builder.arc({100, 100}, 50, 0, -270)
        |> Builder.arc({100, 100}, 50, 30, 390)
        |> drawn()

      points = fn path ->
        for [x, y] <- ends(path.operations), do: {Float.round(x, 3), Float.round(y, 3)}
      end

      assert points.(quarter) == [{150.0, 100.0}, {100.0, 150.0}]

      assert points.(three_quarters) == [
               {150.0, 100.0},
               {100.0, 50.0},
               {50.0, 100.0},
               {100.0, 150.0}
             ]

      # Clockwise from the rightmost point, the curve first bends downwards.
      [_, {:curve_to, _, c1y, _, _, _, _} | _] = three_quarters.operations
      assert c1y < 100

      # An angle too large for its sweep to survive conversion to radians.
      huge = 100_000_000_000_000_000_000_000

      [far_quarter] =
        Builder.new() |> Builder.arc({100, 100}, 50, huge, huge + 90) |> drawn()

      [near_quarter] =
        Builder.new()
        |> Builder.arc({100, 100}, 50, rem(huge, 360), rem(huge, 360) + 90)
        |> drawn()

      assert far_quarter == near_quarter
      assert [start, finish] = points.(far_quarter)
      assert_in_delta distance(start, finish), 50 * :math.sqrt(2), 0.01

      [first | rest] = points.(full)
      assert length(rest) == 4 and List.last(rest) == first
      assert three_quarters.fill_color == nil

      for path <- [quarter, three_quarters, full],
          {:curve_to, c1x, c1y, c2x, c2y, _, _} <- path.operations,
          point <- [{c1x, c1y}, {c2x, c2y}] do
        assert distance(point, {100, 100}) <= 50 * :math.sqrt(1 + 0.5523 ** 2)
      end
    end

    test "a dash pattern applies to its own outline only" do
      body =
        Builder.new()
        |> Builder.line({72, 600}, {540, 600}, dash_pattern: {[3, 2], 1})
        |> Builder.line({72, 500}, {540, 500})
        |> content()

      assert [_, after_dashed] = String.split(body, "[3 2] 1 d\n")
      assert [dashed, solid] = String.split(after_dashed, "[] 0 d\n")
      assert dashed =~ "600 m"
      assert solid =~ "500 m"
      refute solid =~ " d\n"
    end

    test "shapes and text are painted in the order they were added" do
      first_drawn = fn builder ->
        body = content(builder)
        {text, _} = :binary.match(body, "BT")
        {rect, _} = :binary.match(body, " re\n")
        if text < rect, do: :text, else: :rect
      end

      box = %Rect{x: 72, y: 700, width: 100, height: 30}
      text_first = Builder.new() |> Builder.text_at({72, 715}, "MMMM") |> Builder.rect(box)
      rect_first = Builder.new() |> Builder.rect(box) |> Builder.text_at({72, 715}, "MMMM")

      assert first_drawn.(text_first) == :text
      assert first_drawn.(rect_first) == :rect
    end

    test "text after a filled shape keeps its own color" do
      doc =
        Builder.new()
        |> Builder.rect(%Rect{x: 72, y: 700, width: 100, height: 30}, fill_color: @red)
        |> Builder.paragraph("Mark")
        |> written()

      assert doc |> Document.chars!(0) |> Enum.all?(&(&1.color == @black))
    end

    test "shapes sit outside the flow, on the current page" do
      plain = Builder.new() |> Builder.paragraph("Body") |> written()

      shaped =
        Builder.new()
        |> Builder.rect(%Rect{x: 72, y: 600, width: 100, height: 100})
        |> Builder.paragraph("Body")
        |> Builder.page(:a4)
        |> Builder.circle({100, 100}, 10)
        |> written()

      assert baselines(shaped, 0) == baselines(plain, 0)
      assert Document.page_count!(shaped) == 2
      assert shaped |> Document.paths!() |> Enum.map(& &1.page) == [0, 1]

      alone = Builder.new() |> Builder.line({0, 0}, {10, 10}) |> written()
      assert Document.page_count!(alone) == 1
    end

    test "a shape may run past the page edge" do
      assert [path] =
               Builder.new()
               |> Builder.rect(%Rect{x: -10, y: -10, width: 700, height: 900},
                 fill_color: @gray,
                 stroke_color: nil
               )
               |> Builder.circle({612, 792}, 100)
               |> drawn()
               |> Enum.take(1)

      assert path.operations == [{:rectangle, -10.0, -10.0, 700.0, 900.0}]
    end

    test "a setting the shape would not draw raises" do
      builder = Builder.new()
      rect = %Rect{x: 72, y: 72, width: 10, height: 10}

      assert_raise ArgumentError, ~r/:stroke_color/, fn ->
        Builder.rect(builder, rect, stroke_color: nil)
      end

      assert_raise ArgumentError, ~r/:stroke_color/, fn ->
        Builder.line(builder, {0, 0}, {1, 1}, stroke_color: nil)
      end

      for {key, value} <- [stroke_width: 2, dash_pattern: {[3, 2], 0}] do
        assert_raise ArgumentError,
                     ~r/#{inspect(key)} has no effect with stroke_color: nil/,
                     fn ->
                       Builder.rect(builder, rect, [
                         {key, value},
                         fill_color: @gray,
                         stroke_color: nil
                       ])
                     end
      end

      assert %Builder{} =
               Builder.rect(builder, rect,
                 fill_color: @gray,
                 stroke_color: nil,
                 stroke_width: 1,
                 dash_pattern: nil
               )
    end

    test "malformed paint options raise" do
      builder = Builder.new()

      for dash <- [{[], 0}, {[0, 2], 0}, {[3], -1}, [3, 2], {[3, "2"], 0}] do
        assert_raise ArgumentError, ~r/:dash_pattern/, fn ->
          Builder.line(builder, {0, 0}, {1, 1}, dash_pattern: dash)
        end
      end

      assert_raise ArgumentError, ~r/:stroke_width/, fn ->
        Builder.line(builder, {0, 0}, {1, 1}, stroke_width: -1)
      end

      assert_raise ArgumentError, ~r/:fill_color/, fn ->
        Builder.circle(builder, {0, 0}, 1, fill_color: %RGB{r: 2, g: 0, b: 0})
      end

      assert_raise ArgumentError, ~r/:stroke_color/, fn ->
        Builder.circle(builder, {0, 0}, 1, stroke_color: {0, 0, 0})
      end
    end

    test "malformed geometry raises" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/three/, fn ->
        Builder.polygon(builder, [{0, 0}, {1, 1}])
      end

      assert_raise ArgumentError, ~r/invalid point/, fn ->
        Builder.polygon(builder, [{0, 0}, {1, 1}, {:a, 2}])
      end

      for {from, to} <- [{0, 0}, {0, 361}, {90, -271}] do
        assert_raise ArgumentError, ~r/angles/, fn ->
          Builder.arc(builder, {0, 0}, 1, from, to)
        end
      end

      for operations <- [[], [{:line_to, 1, 2}], [:close_path]] do
        assert_raise ArgumentError, ~r/must start with/, fn ->
          Builder.path(builder, operations)
        end
      end

      for operation <- [{:move_to, 1}, {:curve_to, 1, 2, 3, 4, 5, "6"}, :stroke] do
        assert_raise ArgumentError, ~r/invalid operation/, fn ->
          Builder.path(builder, [{:move_to, 0, 0}, operation])
        end
      end

      assert_raise ArgumentError, ~r/^invalid radius,/, fn ->
        Builder.circle(builder, {0, 0}, 0)
      end

      assert_raise ArgumentError, ~r/^invalid radii,/, fn ->
        Builder.ellipse(builder, {0, 0}, {1, -1})
      end

      assert_raise ArgumentError, ~r/invalid rect/, fn ->
        Builder.rect(builder, %Rect{x: untyped("0"), y: 0, width: 1, height: 1})
      end

      assert_raise FunctionClauseError, fn -> Builder.line(builder, untyped({1}), {0, 0}) end
      assert_raise FunctionClauseError, fn -> Builder.rect(builder, untyped({0, 0, 1, 1})) end
    end

    test "an integer coordinate too large for 64 bits is drawn" do
      draw = fn x ->
        Builder.new()
        |> Builder.line({x, 0}, {0, 0})
        |> Builder.rect(%Rect{x: x, y: 0, width: 1, height: 1})
        |> drawn()
      end

      assert draw.(10_000_000_000_000_000_000) == draw.(1.0e19)
    end

    test "geometry beyond the 32-bit float range raises" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/^invalid from,/, fn ->
        Builder.line(builder, {1.0e39, 0}, {0, 0})
      end

      # The message names the arguments, not the control point that overflowed.
      assert_raise ArgumentError,
                   ~r/^invalid radius, .* center \{3.0e38, 0.0\} .*: 1.0e38$/,
                   fn ->
                     Builder.circle(builder, {3.0e38, 0}, 1.0e38)
                   end

      assert_raise ArgumentError, ~r/^invalid radius, .* around center/, fn ->
        Builder.arc(builder, {3.0e38, 0}, 1.0e38, 0, 90)
      end

      assert_raise ArgumentError, ~r/corners/, fn ->
        Builder.rect(builder, %Rect{x: 3.0e38, y: 0, width: 1.0e38, height: 1})
      end

      # Both corners fit; the distance between them does not.
      assert_raise ArgumentError, ~r/width and height/, fn ->
        Builder.rect(builder, %Rect{x: -3.0e38, y: 0, width: 6.0e38, height: 1})
      end

      for operation <- [{:rectangle, 3.0e38, 0, 1.0e38, 1}, {:rectangle, -3.0e38, 0, 6.0e38, 1}] do
        assert_raise ArgumentError,
                     ~r/^invalid operation, .*: #{Regex.escape(inspect(operation))}$/,
                     fn ->
                       Builder.path(builder, [operation])
                     end
      end
    end
  end

  describe "images" do
    defp jpeg do
      [image] = @fixtures |> Path.join("image_jpeg.pdf") |> open() |> Document.images!(0)
      Image.to_binary!(image, format: :jpeg)
    end

    # `Document.images/2` skips images under 8 × 8, so every image here is larger.
    defp boxes(doc, page) do
      for %Image{bbox: box} <- Document.images!(doc, page) do
        Enum.map([box.x, box.y, box.width, box.height], &Float.round(&1, 3))
      end
    end

    defp wide, do: Png.solid(40, 20, :rgb)

    test "image_in_rect/4 fits the image within the rect, centered, or fills it" do
      doc =
        Builder.new()
        |> Builder.image_in_rect(%Rect{x: 72.0, y: 600.0, width: 100.0, height: 100.0}, wide())
        |> Builder.image_in_rect(
          %Rect{x: 300.0, y: 600.0, width: 100.0, height: 100.0},
          wide(),
          fit: :fill
        )
        |> Builder.image_in_rect(
          %Rect{x: 500.0, y: 300.0, width: -100.0, height: -50.0},
          wide(),
          fit: :fill
        )
        |> written()

      assert Enum.sort(boxes(doc, 0)) == [
               [72.0, 625.0, 100.0, 50.0],
               [300.0, 600.0, 100.0, 100.0],
               [400.0, 250.0, 100.0, 50.0]
             ]
    end

    test "image_in_rect/4 stays outside the flow, on the current page, and may pass the edge" do
      doc =
        Builder.new()
        |> Builder.image_in_rect(%Rect{x: -50.0, y: 700.0, width: 200.0, height: 200.0}, wide())
        |> Builder.paragraph("first")
        |> Builder.page()
        |> Builder.image_in_rect(%Rect{x: 72.0, y: 72.0, width: 40.0, height: 20.0}, wide())
        |> written()

      assert length(Document.images!(doc, 0)) == 1
      assert_in_delta Enum.max(baselines(doc, 0)), baseline(792 - 72, 12), 0.001
      assert boxes(doc, 1) == [[72.0, 72.0, 40.0, 20.0]]
    end

    test "keeps a JPEG's bytes and a PNG's transparency" do
      source = jpeg()
      rect = %Rect{x: 72.0, y: 600.0, width: 100.0, height: 100.0}

      bytes =
        Builder.new()
        |> Builder.image_in_rect(rect, source)
        |> Builder.page()
        |> Builder.image(Png.solid(8, 8, :rgba))
        |> Builder.to_binary!(compress: false)

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)

      assert [image] = Document.images!(doc, 0)
      assert Image.data!(image) == {:jpeg, source}
      assert [%Image{width: 8, height: 8}] = Document.images!(doc, 1)
      assert bytes |> :binary.matches("/SMask") |> length() == 1
    end

    test "an image placed more than once is stored once" do
      rect = %Rect{x: 72.0, y: 600.0, width: 100.0, height: 100.0}

      bytes =
        Builder.new()
        |> Builder.image(wide())
        |> Builder.image_in_rect(rect, wide())
        |> Builder.page()
        |> Builder.image(wide())
        |> Builder.image(jpeg())
        |> Builder.to_binary!(compress: false)

      assert bytes |> :binary.matches("/Subtype /Image") |> length() == 2
    end

    # The pairs share their compressed samples, which is all the writer compares.
    test "images with the same samples but different transparency stay apart" do
      translucent = fn alpha ->
        Png.encode(8, 8, :rgba, :binary.copy(<<128, 128, 128, alpha>>, 64))
      end

      bytes =
        [Png.solid(8, 8, :rgb), translucent.(128), translucent.(0), translucent.(64)]
        |> Enum.reduce(Builder.new(), &(&2 |> Builder.page() |> Builder.image(&1)))
        |> Builder.to_binary!(compress: false)

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)

      assert bytes |> :binary.matches("/Subtype /Image") |> length() == 7
      assert bytes |> :binary.matches("/SMask") |> length() == 3

      for page <- 0..3 do
        assert [image] = Document.images!(doc, page)
        assert {:ok, <<0x89, "PNG", _::binary>>} = Image.to_binary(image, format: :png)
      end
    end

    test "images with the same samples but a different shape stay apart" do
      doc =
        Builder.new()
        |> Builder.image(Png.solid(24, 8, :gray))
        |> Builder.image(Png.solid(8, 8, :rgb))
        |> written()

      assert doc |> Document.images!(0) |> Enum.map(&{&1.width, &1.height}) == [{24, 8}, {8, 8}]
    end

    test "image/3 draws one point per pixel below the content before it" do
      doc = Builder.new() |> Builder.paragraph("Hello") |> Builder.image(wide()) |> written()

      assert boxes(doc, 0) == [[72.0, 720.0 - 18 - 6 - 20, 40.0, 20.0]]
    end

    test "image/3 shrinks an image larger than the content area, keeping its proportions" do
      doc =
        Builder.new()
        |> Builder.image(Png.solid(936, 100, :rgb))
        |> Builder.page()
        |> Builder.image(Png.solid(100, 1296, :gray))
        |> written()

      assert boxes(doc, 0) == [[72.0, 670.0, 468.0, 50.0]]
      assert boxes(doc, 1) == [[72.0, 72.0, 50.0, 648.0]]
    end

    test "image/3 follows the image's proportions from a width or a height" do
      doc =
        Builder.new()
        |> Builder.image(wide(), width: 200)
        |> Builder.image(wide(), height: 50)
        |> written()

      assert boxes(doc, 0) == [[72.0, 620.0, 200.0, 100.0], [72.0, 564.0, 100.0, 50.0]]
    end

    test "image/3 fits within a width and height, or fills them" do
      doc =
        Builder.new()
        |> Builder.image(wide(), width: 100, height: 100)
        |> Builder.image(wide(), width: 100, height: 100, fit: :fill)
        |> written()

      assert boxes(doc, 0) == [[72.0, 670.0, 100.0, 50.0], [72.0, 564.0, 100.0, 100.0]]
    end

    test "image/3 aligns between the margins" do
      doc =
        Builder.new()
        |> Builder.image(wide(), width: 100, align: :center)
        |> Builder.image(wide(), width: 100, align: :right)
        |> written()

      assert boxes(doc, 0) == [[256.0, 670.0, 100.0, 50.0], [440.0, 614.0, 100.0, 50.0]]
    end

    test "image/3 leaves a paragraph's space after it" do
      doc = Builder.new() |> Builder.image(wide()) |> Builder.paragraph("after") |> written()

      assert_in_delta Enum.max(baselines(doc, 0)), baseline(720 - 20 - 6, 12), 0.001
    end

    test "image/3 moves to the next page when it does not fit, dropping the space before it" do
      doc =
        Builder.new()
        |> Builder.paragraph("first")
        |> Builder.space(600)
        |> Builder.image(wide(), height: 100)
        |> written()

      assert boxes(doc, 0) == []
      assert boxes(doc, 1) == [[72.0, 620.0, 200.0, 100.0]]
    end

    test "a heading keeps with an image after it" do
      build = fn block ->
        Builder.new()
        |> Builder.paragraph("first")
        |> Builder.space(500)
        |> block.()
        |> Builder.image(wide(), height: 110)
        |> written()
      end

      heading = build.(&Builder.heading(&1, 1, "Figure"))
      paragraph = build.(&Builder.paragraph(&1, "Figure"))

      assert Document.text!(heading, 1) =~ "Figure"
      assert Document.text!(paragraph, 0) =~ "Figure"
      assert length(Document.images!(heading, 1)) == 1
      assert length(Document.images!(paragraph, 1)) == 1
    end

    test "refuses an image whose proportions take it past the content area" do
      message = Builder.new() |> Builder.image(Png.solid(10, 100, :rgb), width: 100) |> refusal()

      assert message =~ "op 0 on page 0: an image 100 × 1000 points does not fit"
      assert message =~ "468 × 648-point content area"
    end

    test "refuses an image that cannot be read, naming the op" do
      rect = %Rect{x: 72.0, y: 72.0, width: 10.0, height: 10.0}

      assert {:error,
              %Error{reason: :unsupported, message: "the image of op 1 is neither JPEG nor PNG"}} =
               Builder.new()
               |> Builder.paragraph("x")
               |> Builder.image_in_rect(rect, "GIF89a")
               |> Builder.to_binary()

      assert {:error, %Error{reason: :other, message: "the image of op 0: " <> _}} =
               Builder.new() |> Builder.image(Png.header(8, 8, :rgb)) |> Builder.to_binary()

      assert Builder.new()
             |> Builder.image(Png.header(20_000, 20_000, :rgba))
             |> refusal() =~ "the image of op 0 is 20000 × 20000 pixels, over the"
    end
  end

  describe "font refusals" do
    test "a style the family has no face for" do
      message =
        Builder.new(font: cff_family())
        |> Builder.paragraph([{"both", bold: true, italic: true}])
        |> refusal()

      assert message =~ "op 0: its FontFamily has no bold italic face; pass :bold_italic"
    end

    test "italic in an explicit :dejavu_sans, which has no italic face" do
      message =
        Builder.new(font: :dejavu_sans)
        |> Builder.paragraph([{"slanted", italic: true}])
        |> refusal()

      assert message =~ ":dejavu_sans has no italic face"
    end

    test "a character the embedded face has no glyph for" do
      message = Builder.new(font: cff_family()) |> Builder.paragraph("Жук") |> refusal()

      assert message =~ "FixtureCFF-Regular has no glyph for 'Ж' (U+0416)"
    end

    test "a character DejaVu Sans lacks under :auto" do
      message = Builder.new() |> Builder.paragraph("中文") |> refusal()

      assert message =~ "DejaVuSans has no glyph for '中'"
    end

    test "right-to-left text, in any font" do
      for text <- ["שלום", "مرحبا"] do
        message = Builder.new() |> Builder.paragraph("ok " <> text) |> refusal()

        assert message =~ "op 0 on page 0"
        assert message =~ "is right-to-left text"
      end
    end

    test "a script that needs shaping" do
      family = FontFamily.new(regular: font("font_truetype.ttf"))
      message = Builder.new(font: family) |> Builder.paragraph("नमस्ते") |> refusal()

      assert message =~ "'न' (U+0928) is in a script that needs shaping"
    end

    test "a spacing vowel sign, a virama or a joining letter in any script" do
      for {text, refused} <- [
            {"\u{1140E}\u{11436}", "U+11436"},
            {"\u{1C00}\u{1C27}", "U+1C27"},
            {"\u{1140E}\u{11442}", "U+11442"},
            {"\u{A840}\u{A841}", "U+A840"}
          ] do
        message = Builder.new() |> Builder.paragraph(text) |> refusal()

        assert message =~ "(#{refused}) is in a script that needs shaping"
      end
    end

    test "empty text needs no face" do
      family = FontFamily.new(regular: font("font_truetype.ttf"))

      doc =
        Builder.new(font: family)
        |> Builder.heading(1, "")
        |> Builder.heading(2, " ")
        |> Builder.paragraph(["Body", {"", italic: true}])
        |> written()

      assert Document.text!(doc, 0) == "Body"
    end

    test "a font collection" do
      family = FontFamily.new(regular: font("font_collection.ttc"))
      message = Builder.new(font: family) |> Builder.paragraph("a") |> refusal()

      assert message =~ "its :regular face is a font collection (.ttc)"
    end

    test "bytes that are not a font" do
      family = FontFamily.new(regular: "not a font")
      message = Builder.new(font: family) |> Builder.paragraph("a") |> refusal()

      assert message =~ "its :regular face is not a font this library can read"
    end
  end

  describe "refusals" do
    test "a character Helvetica cannot draw is refused, naming the op" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Builder.new(font: :helvetica)
               |> Builder.paragraph("fine")
               |> Builder.paragraph("Привет")
               |> Builder.to_binary()

      assert message =~ "op 1"
      assert message =~ "U+041F"
    end

    test "a control character is refused like any other undrawable one" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Builder.new() |> Builder.paragraph("bell\u0007") |> Builder.to_binary()

      assert message =~ "U+0007"
    end

    test "whitespace other than a space is laid out as one" do
      doc = Builder.new() |> Builder.paragraph("a\tb") |> written()

      assert Document.text!(doc) =~ "a b"
    end

    test "a character wider than the line is refused, naming it" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Builder.new(page_size: {154, 300})
               |> Builder.paragraph("W")
               |> Builder.to_binary()

      assert message =~ ~s("W")
      assert message =~ "10-point line"
    end

    test "from_builder!/1 raises the refusal" do
      assert_raise Error, ~r/U\+041F/, fn ->
        Builder.new(font: :helvetica) |> Builder.paragraph("Привет") |> Editor.from_builder!()
      end
    end
  end

  describe "malformed arguments raise where they are passed" do
    test "images" do
      rect = %Rect{x: 72.0, y: 72.0, width: 10.0, height: 10.0}

      assert_raise FunctionClauseError, fn -> Builder.image(Builder.new(), untyped(:logo)) end

      assert_raise ArgumentError, ~r/^invalid :fit, expected one of/, fn ->
        Builder.image_in_rect(Builder.new(), rect, "image", fit: :cover)
      end

      assert_raise ArgumentError, ~r/^invalid :fit, it has no effect unless both :width/, fn ->
        Builder.image(Builder.new(), "image", width: 100, fit: :fill)
      end

      assert_raise ArgumentError,
                   ~r/^invalid :width, a 469.0-point image does not fit the 468.0-point/,
                   fn -> Builder.image(Builder.new(), "image", width: 469) end

      assert_raise ArgumentError, ~r/^invalid :height, a 57.0-point image/, fn ->
        Builder.new() |> Builder.page({300, 200}) |> Builder.image("image", height: 57)
      end

      assert_raise ArgumentError, ~r/^invalid rect, expected a positive number/, fn ->
        Builder.image_in_rect(Builder.new(), %{rect | width: 0.0}, "image")
      end
    end

    test "text and metadata that are not UTF-8" do
      for build <- [
            &Builder.paragraph(&1, <<0xFF>>),
            &Builder.heading(&1, 1, ["ok ", {<<0xFF>>, bold: true}]),
            &Builder.bullet_list(&1, [<<0xFF>>]),
            &Builder.text_at(&1, {72, 72}, <<0xFF>>)
          ] do
        assert_raise ArgumentError, ~r/^invalid text, expected a UTF-8 string/, fn ->
          build.(Builder.new())
        end
      end

      assert_raise ArgumentError, ~r/^invalid :title, expected a UTF-8 string/, fn ->
        Builder.new(title: <<0xFF>>)
      end
    end

    test "a line taller than the content area" do
      assert_raise ArgumentError, ~r/does not fit the 648.0-point content height/, fn ->
        Builder.new() |> Builder.paragraph("x", font_size: 500)
      end
    end

    test "a page too large for the text's size to be placed precisely" do
      assert_raise ArgumentError, ~r/too large to place 12.0-point text/, fn ->
        Builder.new(page_size: {612, 1.0e9}) |> Builder.paragraph("a\nb\nc\nd")
      end

      assert %Builder{} = Builder.new(page_size: {14_400, 14_400}) |> Builder.paragraph("a")
    end

    test "the check uses the current page's size" do
      builder = Builder.new() |> Builder.page({300, 200})

      assert %Builder{} = Builder.paragraph(builder, "x", font_size: 37)

      assert_raise ArgumentError, ~r/content height/, fn ->
        Builder.paragraph(builder, "x", font_size: 38)
      end
    end

    test "margins that leave no room on the page" do
      assert_raise ArgumentError, ~r/leave no room/, fn ->
        Builder.new(margin_left: 300, margin_right: 312)
      end

      assert_raise ArgumentError, ~r/leave no room/, fn ->
        Builder.new() |> Builder.page({100, 100})
      end
    end

    test "an unknown paper size, or values of the wrong type" do
      assert_raise ArgumentError, ~r/:page_size/, fn -> Builder.new(page_size: :b5) end
      assert_raise ArgumentError, ~r/:title/, fn -> Builder.new(title: 1) end
      assert_raise ArgumentError, ~r/:font_size/, fn -> Builder.new(font_size: "12") end
      assert_raise ArgumentError, ~r/:font_size/, fn -> Builder.new(font_size: 0) end
      assert_raise ArgumentError, ~r/:margin_top/, fn -> Builder.new(margin_top: -1) end
    end

    test "a font that is neither built in nor a FontFamily" do
      assert_raise ArgumentError, ~r/invalid :font/, fn -> Builder.new(font: :arial) end

      assert_raise ArgumentError, ~r/invalid :font/, fn ->
        Builder.paragraph(Builder.new(), "x", font: "Helvetica")
      end
    end

    test "a malformed run" do
      assert_raise ArgumentError, ~r/invalid run/, fn ->
        Builder.paragraph(Builder.new(), [untyped(:text)])
      end

      assert_raise ArgumentError, ~r/:bold/, fn ->
        Builder.paragraph(Builder.new(), [{"x", bold: :yes}])
      end

      assert_raise ArgumentError, ~r/:color/, fn ->
        Builder.paragraph(Builder.new(), [{"x", color: %RGB{r: 2.0, g: 0.0, b: 0.0}}])
      end

      assert_raise ArgumentError, ~r/:color/, fn ->
        Builder.paragraph(Builder.new(), [{"x", color: {1, 0, 0}}])
      end
    end

    test "a FontFamily without a regular face, or with a face that is not a binary" do
      assert_raise ArgumentError, ~r/invalid :regular, .* cannot be missing/, fn ->
        FontFamily.new(bold: "b")
      end

      assert_raise ArgumentError, ~r/:italic/, fn -> FontFamily.new(regular: "r", italic: 1) end
    end

    test "paragraph text that is not a string" do
      assert_raise FunctionClauseError, fn ->
        Builder.paragraph(Builder.new(), untyped(:text))
      end
    end
  end
end
