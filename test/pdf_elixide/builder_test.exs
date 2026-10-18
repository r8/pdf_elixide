defmodule PdfElixide.BuilderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Builder
  alias PdfElixide.Builder.FontFamily
  alias PdfElixide.Color.RGB
  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Editor
  alias PdfElixide.Error

  # Helvetica's ascent and descent, in thousandths of an em.
  @ascent 718
  @descent -207

  defp written(%Builder{} = builder) do
    doc = builder |> Builder.to_binary!() |> Document.from_binary!()
    on_exit(fn -> Document.close(doc) end)
    doc
  end

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

  defp lines(count), do: Enum.map_join(1..count, "\n", &"line #{&1}")

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

    # The title spells the old subtype to show that only the font is relabelled.
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

    test "a run's colour is drawn" do
      red = %RGB{r: 1.0, g: 0.0, b: 0.0}
      doc = Builder.new() |> Builder.paragraph(["a", {"b", color: red}]) |> written()
      colors = doc |> Document.chars!(0) |> Map.new(&{&1.text, &1.color})

      assert colors["b"] == red
      assert colors["a"] == %RGB{r: 0.0, g: 0.0, b: 0.0}
    end

    test "an integer colour component is as good as a float" do
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

    test "a rule is a thin grey line across the content width, in a box of the text size" do
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
        bytes = builder |> Editor.from_builder!() |> Editor.to_binary!(compress: false)
        streams = Regex.scan(~r/stream\r?\n(.*?)endstream/s, bytes, capture: :all_but_first)
        [body] = for [stream] <- streams, stream =~ "BT", do: stream

        {text, _} = :binary.match(body, "BT")
        {rule, _} = :binary.match(body, " l\n")
        if text < rule, do: :text, else: :rule
      end

      rule_first = Builder.new() |> Builder.rule() |> Builder.text_at(72, 715, "MMMM")
      text_first = Builder.new() |> Builder.text_at(72, 715, "MMMM") |> Builder.rule()

      assert first_drawn.(rule_first) == :rule
      assert first_drawn.(text_first) == :text
    end

    test "negative space raises" do
      assert_raise ArgumentError, ~r/:points/, fn -> Builder.space(Builder.new(), -1) end
    end
  end

  describe "text_at/5" do
    test "draws one line with its baseline at the point" do
      doc = Builder.new() |> Builder.text_at(100, 200, "Mark") |> written()
      [first | _] = Document.chars!(doc, 0)

      assert Document.page_count!(doc) == 1
      assert_in_delta first.bbox.x, 100, 0.01
      assert_in_delta first.bbox.y, 200, 0.01
    end

    test "stays outside the flow, on the current page, and may sit in the margins" do
      doc =
        Builder.new()
        |> Builder.text_at(10, 10, "corner")
        |> Builder.paragraph("first")
        |> Builder.page()
        |> Builder.text_at(300, 400, "second page")
        |> written()

      fonts = doc |> Document.chars!(0) |> Enum.map_join(& &1.text)

      assert fonts =~ "corner"
      assert_in_delta Enum.max(baselines(doc, 0)), baseline(792 - 72, 12), 0.001
      assert Document.text!(doc, 1) =~ "second page"
    end

    test "takes runs, a font and a size" do
      doc =
        Builder.new()
        |> Builder.text_at(72, 72, ["a", {"b", bold: true}], font: :times, font_size: 20)
        |> written()

      fonts = fonts_by_text(doc)

      assert fonts["a"] == "Times-Roman"
      assert fonts["b"] == "Times-Bold"
      assert_in_delta hd(Document.chars!(doc, 0)).font_size, 20, 0.001
    end

    test "counts for :auto" do
      [char | _] =
        Builder.new() |> Builder.text_at(72, 72, "Звіт") |> written() |> Document.chars!(0)

      assert char.font =~ "DejaVuSans"
    end

    test "a line past the edge of the page is refused" do
      for {x, y} <- [{580, 100}, {72, 788}, {72, 1}, {-1, 100}] do
        message = Builder.new() |> Builder.text_at(x, y, "Wide text") |> refusal()

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
        builder = Builder.new() |> Builder.text_at(x, y, [run], font: font)

        assert refusal(builder) =~ "past the edge of the page"
      end
    end

    test "a character its font cannot draw is refused" do
      message = Builder.new() |> Builder.text_at(72, 72, "Звіт", font: :helvetica) |> refusal()

      assert message =~ "Helvetica cannot draw"
    end

    test "malformed arguments raise" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/one line/, fn -> Builder.text_at(builder, 72, 72, "a\nb") end
      assert_raise ArgumentError, ~r/:x/, fn -> Builder.text_at(builder, 1.0e39, 72, "a") end

      assert_raise ArgumentError, ~r/too large/, fn ->
        Builder.new(page_size: {612, 1.0e9}) |> Builder.text_at(72, 72, "a")
      end

      assert_raise FunctionClauseError, fn -> Builder.text_at(builder, untyped("72"), 72, "a") end
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
      assert_raise ArgumentError, ~r/missing :regular/, fn -> FontFamily.new(bold: "b") end
      assert_raise ArgumentError, ~r/:italic/, fn -> FontFamily.new(regular: "r", italic: 1) end
    end

    test "paragraph text that is not a string" do
      assert_raise FunctionClauseError, fn ->
        Builder.paragraph(Builder.new(), untyped(:text))
      end
    end
  end
end
