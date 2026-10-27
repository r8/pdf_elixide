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

    @tag :tmp_dir
    test "a bad output option raises even when layout would refuse the description",
         %{tmp_dir: tmp_dir} do
      builder =
        Builder.new(font: FontFamily.new(regular: "not a font")) |> Builder.paragraph("a")

      path = Path.join(tmp_dir, "never.pdf")

      assert_raise ArgumentError, ~r/:compress/, fn ->
        Builder.to_binary(builder, compress: untyped(:invalid))
      end

      assert_raise ArgumentError, ~r/:compress/, fn ->
        Builder.save(builder, path, compress: untyped(:invalid))
      end

      assert_raise ArgumentError, ~r/:bogus/, fn ->
        Builder.to_binary(builder, encryption: untyped(bogus: 1))
      end

      assert_raise ArgumentError, ~r/:aes256/, fn ->
        Builder.save(builder, path, encryption: [algorithm: untyped(:aes256)])
      end

      refute File.exists?(path)
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
    test "the largest page size it accepts reads back" do
      for {width, height} <- [{1.0e18, 792}, {612, 1.0e18}] do
        doc = written(Builder.new(page_size: {width, height}))
        box = Page.media_box!(Document.page!(doc, 0))

        assert_in_delta box.width / width, 1.0, 1.0e-6
        assert_in_delta box.height / height, 1.0, 1.0e-6
      end
    end

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
    test "refuses a heading that cannot share any page with the start of what follows" do
      message =
        Builder.new()
        |> Builder.heading(1, "Figure")
        |> Builder.image(Png.solid(20, 40, :rgb), height: 648)
        |> refusal()

      assert message =~ "op 0 on page 0"
      assert message =~ "it would be left alone"
    end

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

  describe "code_block/3" do
    # Courier's 12-point advance, and the margin plus the default padding.
    @column 7.2
    @code_left 78.0

    defp coded(text, opts \\ []), do: Builder.new() |> Builder.code_block(text, opts) |> written()

    defp column_of(char), do: round((char.bbox.x - @code_left) / @column)

    defp code_lines(doc, page) do
      for line <- chars_by_line(doc, page) do
        for char <- line, char.text != " ", do: {char.text, column_of(char)}
      end
    end

    test "keeps indentation, spaces and blank lines as written" do
      doc = coded("def a do\n    x  = 1\n\nend\n")

      assert code_lines(doc, 0) == [
               [{"d", 0}, {"e", 1}, {"f", 2}, {"a", 4}, {"d", 6}, {"o", 7}],
               [{"x", 4}, {"=", 7}, {"1", 9}],
               [{"e", 0}, {"n", 1}, {"d", 2}]
             ]

      [first, second, third] = baselines(doc, 0)
      assert_in_delta first - second, 18, 0.001
      assert_in_delta second - third, 36, 0.001
    end

    test "expands tabs to stops counted from the start of each line" do
      assert code_lines(coded("\tx\nab\ty\nabcd\tz"), 0) == [
               [{"x", 4}],
               [{"a", 0}, {"b", 1}, {"y", 4}],
               [{"a", 0}, {"b", 1}, {"c", 2}, {"d", 3}, {"z", 8}]
             ]

      assert code_lines(coded("ab\tx", tab_width: 8), 0) == [[{"a", 0}, {"b", 1}, {"x", 8}]]
    end

    test "ends lines at \\r\\n and \\r as at \\n, and drops trailing whitespace" do
      doc = coded("a  \r\nb\t\rc\n   ")

      assert code_lines(doc, 0) == [[{"a", 0}], [{"b", 0}], [{"c", 0}]]
    end

    test "a line break is a line however it is written" do
      after_block =
        for ending <- ["\n", "\r\n", "\r"] do
          doc = Builder.new() |> Builder.code_block(ending) |> Builder.paragraph("a") |> written()

          assert length(Document.paths!(doc, 0)) == 1
          [a, b] = baselines(coded("a" <> ending <> ending <> "b"), 0)
          assert_in_delta a - b, 36, 0.001

          baselines(doc, 0)
        end

      assert [same] = Enum.uniq(after_block)
      assert hd(same) < baseline(720, 12) - 30
    end

    test "breaks a line too wide for the block at the column, not between words" do
      # 456 points between the paddings holds 63 columns.
      doc = coded(String.duplicate("abcd ", 20))
      [first, second] = chars_by_line(doc, 0)

      assert length(first) == 63
      assert {List.last(first).text, column_of(List.last(first))} == {"c", 62}
      assert {hd(second).text, column_of(hd(second))} == {"d", 0}

      for char <- first ++ second do
        assert char.bbox.x + char.bbox.width <= 540 - 6 + 0.001
      end
    end

    test "draws its background across the margins, under the text" do
      fill = %RGB{r: 0.9, g: 0.8, b: 0.7}
      doc = coded("a\nb", fill_color: fill, padding: 10)

      assert [%{bbox: bbox, fill_color: color, stroke_color: nil}] = Document.paths!(doc, 0)
      assert bbox == %Rect{x: 72.0, y: 720.0 - 56.0, width: 468.0, height: 56.0}
      assert_in_delta color.g, 0.8, 0.0001
      assert_in_delta hd(Document.chars!(doc, 0)).bbox.x, 82, 0.001

      body = Builder.new() |> Builder.code_block("a") |> content()
      assert elem(:binary.match(body, "re\nf\n"), 0) < elem(:binary.match(body, "BT\n"), 0)

      assert Document.paths!(coded("a", fill_color: nil), 0) == []
    end

    test "continues across pages, each page's part in a box of its own" do
      source = Enum.map_join(1..50, "\n", &"line #{&1}")
      doc = Builder.new() |> Builder.code_block(source) |> Builder.paragraph("after") |> written()

      # 648 points of content height hold 35 lines of 18 points within the
      # padding.
      assert Document.page_count!(doc) == 2

      assert [%Rect{x: 72.0, y: 78.0, width: 468.0, height: 642.0}] =
               Enum.map(Document.paths!(doc, 0), & &1.bbox)

      assert [%Rect{y: 438.0, height: 282.0}] =
               Enum.map(Document.paths!(doc, 1), & &1.bbox)

      lines = for page <- 0..1, line <- page_lines(doc, page), do: line
      assert lines == Enum.map(1..50, &"line #{&1}") ++ ["after"]

      assert hd(baselines(doc, 1)) == hd(baselines(doc, 0))
    end

    test "a heading is kept with the block's first line" do
      doc =
        Builder.new()
        |> Builder.paragraph("a")
        |> Builder.space(580)
        |> Builder.heading(1, "H")
        |> Builder.code_block("code")
        |> written()

      assert Document.page_count!(doc) == 2
      assert Document.text!(doc, 0) =~ "a"
      refute Document.text!(doc, 0) =~ "H"
    end

    test "sets Courier by default, and takes runs, another font and a size" do
      assert fonts_by_text(coded("a"))["a"] == "Courier"

      doc =
        coded(["a", {"b", bold: true}, {"c", color: %RGB{r: 1.0, g: 0.0, b: 0.0}}],
          font: :times,
          font_size: 9
        )

      fonts = fonts_by_text(doc)

      assert fonts["a"] == "Times-Roman" and fonts["b"] == "Times-Bold"
      assert_in_delta hd(Document.chars!(doc, 0)).font_size, 9, 0.001
      refute fonts_by_text(coded("ab", font: cff_family()))["a"] =~ "Courier"
    end

    test "counts for :auto, and refuses what Courier cannot draw" do
      [char | _] = "Звіт" |> coded(font: :auto) |> Document.chars!(0)
      assert char.font =~ "DejaVuSans"

      message = Builder.new() |> Builder.code_block("Звіт") |> refusal()
      assert message =~ "op 0 on page 0"
      assert message =~ "Courier"
    end

    test "text that draws nothing adds nothing" do
      doc = Builder.new() |> Builder.code_block("  \t ") |> Builder.paragraph("a") |> written()

      assert Document.paths!(doc, 0) == []
      assert_in_delta Enum.max(baselines(doc, 0)), baseline(720, 12), 0.001
    end
  end

  describe "columns/3" do
    # Two 228-point columns 12 points apart: the gap's middle is at 306.
    defp by_column(doc, page, split \\ 306) do
      {left, right} =
        doc |> Document.chars!(page) |> Enum.split_with(&(&1.bbox.x < split))

      for chars <- [left, right] do
        chars
        |> Enum.sort_by(&{-&1.bbox.y, &1.bbox.x})
        |> Enum.chunk_by(&Float.round(&1.bbox.y, 3))
        |> Enum.map(fn line -> Enum.map_join(line, & &1.text) end)
      end
    end

    defp numbered(count), do: Enum.map(1..count, &"p#{&1}")

    test "balances the lines between the block before and the next" do
      doc =
        Builder.new()
        |> Builder.paragraph("Before")
        |> Builder.columns(numbered(7))
        |> Builder.paragraph("After")
        |> written()

      assert by_column(doc, 0) == [
               ["Before", "p1", "p2", "p3", "p4", "After"],
               ["p5", "p6", "p7"]
             ]

      {left, right} = doc |> Document.chars!(0) |> Enum.split_with(&(&1.bbox.x < 306))
      assert Enum.all?(left, &(&1.bbox.x >= 72 and &1.bbox.x + &1.bbox.width <= 300))
      assert Enum.all?(right, &(&1.bbox.x >= 312 and &1.bbox.x + &1.bbox.width <= 540))

      # Four lines with three paragraph gaps between them, then the space
      # after the block.
      [before, top | _] = baselines(doc, 0)
      assert_in_delta before, baseline(720, 12), 0.001
      assert_in_delta top, baseline(696, 12), 0.001
      assert_in_delta Enum.min(baselines(doc, 0)), baseline(600, 12), 0.001
    end

    test "fills each page's columns in order, and balances the last page's" do
      doc = Builder.new() |> Builder.columns(numbered(70)) |> written()

      # 648 points hold 27 lines of 18 points with a 6-point gap between each.
      assert Document.page_count!(doc) == 2
      assert by_column(doc, 0) == [numbered(54) |> Enum.take(27), numbered(54) |> Enum.drop(27)]
      assert by_column(doc, 1) == [Enum.map(55..62, &"p#{&1}"), Enum.map(63..70, &"p#{&1}")]
      assert hd(baselines(doc, 1)) == hd(baselines(doc, 0))
    end

    test "drops a paragraph's space at the top of a column" do
      doc = Builder.new() |> Builder.columns(["a\nb", "c\nd"]) |> written()

      assert by_column(doc, 0) == [["a", "b"], ["c", "d"]]
      assert [_top, _second] = baselines(doc, 0)

      [first, second] =
        Builder.new() |> Builder.columns(["a", "b"], count: 1) |> written() |> baselines(0)

      assert_in_delta first - second, 24, 0.001
    end

    test "with balance: false, fills a column to the bottom before the next" do
      unbalanced =
        Builder.new()
        |> Builder.columns(["a", "b", "c"], balance: false)
        |> Builder.paragraph("after")
        |> written()

      assert by_column(unbalanced, 0) == [["a", "b", "c", "after"], []]
      assert_in_delta Enum.min(baselines(unbalanced, 0)), baseline(648, 12), 0.001

      balanced =
        Builder.new()
        |> Builder.columns(["a", "b", "c"])
        |> Builder.paragraph("after")
        |> written()

      assert by_column(balanced, 0) == [["a", "b", "after"], ["c"]]
      assert_in_delta Enum.min(baselines(balanced, 0)), baseline(672, 12), 0.001
    end

    test "with rule: true, draws a line down the middle of each gap beside text" do
      ruled = fn paragraphs, opts ->
        Builder.new()
        |> Builder.columns(paragraphs, [rule: true] ++ opts)
        |> written()
        |> Document.paths!(0)
        |> Enum.map(& &1.bbox)
      end

      assert ruled.(["a", "b", "c"], []) == [%Rect{x: 306.0, y: 678.0, width: 0.0, height: 42.0}]

      # Three 148-point columns, the third left empty.
      assert ruled.(["a", "b"], count: 3) == [%Rect{x: 226.0, y: 702.0, width: 0.0, height: 18.0}]

      assert Builder.new() |> Builder.columns(["a", "b"]) |> written() |> Document.paths!(0) == []
    end

    test "a heading is kept with the columns' first line" do
      doc =
        Builder.new()
        |> Builder.paragraph("a")
        |> Builder.space(580)
        |> Builder.heading(1, "H")
        |> Builder.columns(["b", "c"])
        |> written()

      assert Document.page_count!(doc) == 2
      refute Document.text!(doc, 0) =~ "H"
    end

    test "takes runs, a font and a size, and counts for :auto" do
      doc =
        Builder.new()
        |> Builder.columns([["a", {"b", bold: true}]], font: :times, font_size: 9)
        |> written()

      fonts = fonts_by_text(doc)
      assert fonts["a"] == "Times-Roman" and fonts["b"] == "Times-Bold"
      assert_in_delta hd(Document.chars!(doc, 0)).font_size, 9, 0.001

      [char | _] = Builder.new() |> Builder.columns(["Звіт"]) |> written() |> Document.chars!(0)
      assert char.font =~ "DejaVuSans"

      message = Builder.new() |> Builder.columns(["Звіт"], font: :helvetica) |> refusal()
      assert message =~ "op 0 on page 0"
      assert message =~ "Helvetica"
    end

    test "refuses a character wider than a column" do
      # Twenty 23.4-point columns; a 30-point W is 28.32 points wide.
      message =
        Builder.new()
        |> Builder.columns(["W"], count: 20, gap: 0, font_size: 30)
        |> refusal()

      assert message =~ "op 0 starting on page 0"
      assert message =~ "point column"
    end

    test "raises for a caller bug" do
      builder = Builder.new()

      assert_raise ArgumentError, ~r/invalid :count/, fn ->
        Builder.columns(builder, ["a"], count: 0)
      end

      assert_raise ArgumentError, ~r/invalid :count/, fn ->
        Builder.columns(builder, ["a"], count: 1.5)
      end

      for count <- [2_147_483_648, 18_446_744_073_709_551_616] do
        assert_raise ArgumentError,
                     ~r/invalid :count, expected an integer from 1 to 2147483647/,
                     fn -> Builder.columns(builder, ["\n"], count: count, gap: 0) end
      end

      assert_raise ArgumentError, ~r/invalid :gap/, fn ->
        Builder.columns(builder, ["a"], gap: -1)
      end

      assert_raise ArgumentError, ~r/invalid :rule/, fn ->
        Builder.columns(builder, ["a"], rule: :yes)
      end

      assert_raise ArgumentError, ~r/invalid layout, 3 columns with 300.0-point gaps/, fn ->
        Builder.columns(builder, ["a"], count: 3, gap: 300)
      end

      assert_raise ArgumentError, ~r/invalid paragraph/, fn ->
        Builder.columns(builder, [:a])
      end

      assert_raise FunctionClauseError, fn -> Builder.columns(builder, untyped("a")) end
    end

    test "balancing ends where a line is too large for the fit tolerance to absorb rounding" do
      size = 1_000_000_000.1

      assert {:ok, _} =
               Builder.new(page_size: {size * 100, size * 100}, font_size: size)
               |> Builder.columns(["a\na\na", "a\na", "a", "a", "a", "a"])
               |> Builder.to_binary()
    end

    test "the largest column count, far above the lines, is laid out" do
      assert {:ok, _} =
               Builder.new()
               |> Builder.columns(["\n"], gap: 0, count: 2_147_483_647)
               |> Builder.to_binary()
    end

    test "paragraphs that draw nothing add nothing" do
      for paragraphs <- [[], ["  ", ""]] do
        doc = Builder.new() |> Builder.columns(paragraphs) |> Builder.paragraph("a") |> written()

        assert_in_delta Enum.max(baselines(doc, 0)), baseline(720, 12), 0.001
      end

      doc = Builder.new() |> Builder.columns(["", "a", " ", "b"]) |> written()
      assert by_column(doc, 0) == [["a"], ["b"]]
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

  describe "barcodes" do
    @yellow %RGB{r: 1.0, g: 1.0, b: 0.75}
    @crimson %RGB{r: 0.75, g: 0.0, b: 0.0}

    # Rounded to absorb the 32-bit floats the writer stores.
    defp rounded(operations) do
      for {:rectangle, x, y, width, height} <- operations do
        Enum.map([x, y, width, height], &Float.round(&1, 3))
      end
    end

    defp bars(doc, page \\ 0) do
      assert [%{stroke_color: nil} = path] = Document.paths!(doc, page)
      rounded(path.operations)
    end

    defp ean13_rect, do: %Rect{x: 72.0, y: 600.0, width: 230.0, height: 50.0}

    test "barcode_in_rect/5 fills the rect, quiet zones included, with one bar per run" do
      doc =
        Builder.new()
        |> Builder.barcode_in_rect(ean13_rect(), :ean13, "5901234123457")
        |> written()

      # 95 modules and two 10-module quiet zones across 230 points: 2 points each.
      bars = bars(doc)
      assert length(bars) == 30
      assert hd(bars) == [92.0, 600.0, 2.0, 50.0]
      assert List.last(bars) == [280.0, 600.0, 2.0, 50.0]
      assert Enum.all?(bars, fn [_x, y, _width, height] -> {y, height} == {600.0, 50.0} end)
    end

    test "a caption prints the data with its computed check digit under the bars" do
      doc =
        Builder.new()
        |> Builder.barcode_in_rect(ean13_rect(), :ean13, "590123412345",
          text: true,
          color: @crimson
        )
        |> written()

      assert Enum.all?(bars(doc), fn [_x, y, _w, h] -> {y, h} == {618.0, 32.0} end)
      chars = Document.chars!(doc, 0)
      assert Enum.map_join(chars, & &1.text) == "5901234123457"
      assert Enum.all?(chars, &(&1.color == @crimson))

      left = chars |> Enum.map(& &1.bbox.x) |> Enum.min()
      right = chars |> Enum.map(&(&1.bbox.x + &1.bbox.width)) |> Enum.max()
      assert_in_delta (left + right) / 2, 72 + 230 / 2, 0.5
    end

    test "a caption keeps every space of the encoded data" do
      origins = fn data ->
        Builder.new()
        |> Builder.barcode_in_rect(ean13_rect(), :code128, data, text: true)
        |> written()
        |> Document.chars!(0)
        |> Enum.reject(&(&1.text == " "))
        |> Enum.map(fn %{origin: {x, _y}} -> x end)
      end

      # Helvetica at 12 points: "A" advances 667 units and a space 278.
      [a, b] = origins.("A  B")
      assert_in_delta b - a, (667 + 2 * 278) * 12 / 1000, 0.01

      # Centered on x = 187 with the spaces counted.
      assert_in_delta hd(origins.("A")), 187 - 667 * 12 / 2000, 0.01
      assert_in_delta hd(origins.("A ")), 187 - (667 + 278) * 12 / 2000, 0.01
      assert_in_delta hd(origins.(" A")), 187 - (667 + 278) * 12 / 2000 + 278 * 12 / 1000, 0.01
    end

    test "the background is painted behind the whole symbol, before the bars" do
      [background, bars] =
        Builder.new()
        |> Builder.barcode_in_rect(ean13_rect(), :ean13, "5901234123457",
          background: @yellow,
          color: @crimson
        )
        |> written()
        |> Document.paths!(0)

      assert background.operations == [{:rectangle, 72.0, 600.0, 230.0, 50.0}]
      assert {background.fill_color, background.stroke_color} == {@yellow, nil}
      assert {bars.fill_color, bars.stroke_color} == {@crimson, nil}
    end

    test "qr_code_in_rect/4 draws the largest square that fits, centered" do
      doc =
        Builder.new()
        |> Builder.qr_code_in_rect(
          %Rect{x: 300.0, y: 500.0, width: 200.0, height: 100.0},
          "hello"
        )
        |> written()

      # Version 1 is 21 modules, plus a 4-module quiet zone on each side.
      module = 100 / 29
      bars = bars(doc)

      top_left_finder =
        Enum.map([350 + 4 * module, 600 - 5 * module, 7 * module, module], &Float.round(&1, 3))

      bottom_left_finder =
        Enum.map([350 + 4 * module, 500 + 4 * module, 7 * module, module], &Float.round(&1, 3))

      assert Enum.any?(bars, &close?(&1, top_left_finder))
      assert Enum.any?(bars, &close?(&1, bottom_left_finder))

      for [x, y, width, height] <- bars do
        assert x >= 350 + 4 * module - 0.001 and x + width <= 450 - 4 * module + 0.001
        assert y >= 500 + 4 * module - 0.001 and y + height <= 600 - 4 * module + 0.001
      end
    end

    defp close?(a, b), do: Enum.zip(a, b) |> Enum.all?(fn {p, q} -> abs(p - q) < 0.01 end)

    test "barcode/4 flows below the content before it, one point per module by default" do
      doc =
        Builder.new()
        |> Builder.paragraph("Hello")
        |> Builder.barcode(:ean13, "590123412345")
        |> Builder.page()
        |> Builder.barcode(:ean13, "590123412345", align: :center)
        |> written()

      assert hd(bars(doc, 0)) == [82.0, 720.0 - 18 - 6 - 36, 1.0, 36.0]
      assert hd(bars(doc, 1)) == [72 + 468 / 2 - 115 / 2 + 10, 720.0 - 36, 1.0, 36.0]
    end

    test "qr_code/3 flows at two points per module by default" do
      doc = Builder.new() |> Builder.qr_code("hello") |> written()

      assert [path] = Document.paths!(doc, 0)
      assert path.bbox == %Rect{x: 80.0, y: 720.0 - 58 + 8, width: 42.0, height: 42.0}
    end

    test "a flowing barcode that does not fit the rest of the page starts the next one" do
      doc =
        Builder.new()
        |> Builder.paragraph("Hello")
        |> Builder.barcode(:code128, "ABC", height: 640)
        |> written()

      assert Document.paths!(doc, 0) == []
      assert [[_x, 80.0, _width, 640.0] | _] = bars(doc, 1)
    end

    test "every symbology encodes" do
      for {symbology, data} <- [
            code128: "Hello, world!",
            code39: "CODE 39",
            code93: "CODE-93",
            code93: "V",
            ean13: "5901234123457",
            ean8: "9638507",
            upc_a: "03600029145",
            itf: "1234",
            codabar: "A40156B",
            codabar: "A12+34B"
          ] do
        doc =
          Builder.new()
          |> Builder.barcode_in_rect(ean13_rect(), symbology, data, text: true)
          |> written()

        assert [_ | _] = bars(doc)
        assert Document.text!(doc, 0) =~ String.slice(data, 0, 5)
      end

      assert [_ | _] = Builder.new() |> Builder.qr_code("Привіт, світ") |> written() |> bars()
    end

    test "a caption in a font family takes its faces" do
      doc =
        Builder.new()
        |> Builder.barcode_in_rect(ean13_rect(), :ean13, "590123412345",
          text: true,
          font: cff_family()
        )
        |> written()

      refute fonts_by_text(doc)["5"] =~ "Helvetica"
    end

    test "a caption wider than the symbol is refused when the document is built" do
      builder =
        Builder.barcode_in_rect(
          Builder.new(),
          %Rect{x: 72.0, y: 600.0, width: 20.0, height: 50.0},
          :ean13,
          "590123412345",
          text: true
        )

      assert refusal(builder) =~ "op 0 on page 0"
    end

    test "data a symbology cannot encode raises where it is passed" do
      for {symbology, data, message} <- [
            {:code128, "café", "Code 128 takes printable ASCII characters"},
            {:code39, "abc", "Code 39 takes digits, capital letters, spaces and - . $ / + %"},
            {:code93, "A(B", "Code 93 takes digits, capital letters, spaces and - . $ / + %"},
            {:ean13, "12345", "EAN-13 takes 12 digits, or 13 with the check digit"},
            {:ean8, "96385070", "EAN-8's check digit should be 4"},
            {:upc_a, "036000291450", "UPC-A's check digit should be 2"},
            {:itf, "123", "ITF takes an even number of digits"},
            {:codabar, "1234",
             "Codabar begins and ends with a start or stop character A, B, C or D"},
            {:code128, "", "Code 128 cannot encode an empty string"},
            {:code128, String.duplicate("~", 257), "Code 128 takes at most 256 characters"}
          ] do
        assert_raise ArgumentError,
                     "invalid data, #{message}: #{inspect(data, printable_limit: 100)}",
                     fn ->
                       Builder.barcode(Builder.new(), symbology, data)
                     end
      end

      error =
        assert_raise ArgumentError,
                     ~r/^invalid data, 3000 bytes are too many for a QR code at error correction :high: "x+" <> \.\.\.$/,
                     fn ->
                       Builder.qr_code(Builder.new(), String.duplicate("x", 3000),
                         error_correction: :high
                       )
                     end

      assert byte_size(error.message) < 200
    end

    test "malformed arguments raise where they are passed" do
      rect = ean13_rect()

      assert_raise FunctionClauseError, fn ->
        Builder.barcode(Builder.new(), :ean13, untyped(590_123_412_345))
      end

      assert_raise ArgumentError, ~r/^invalid symbology, expected one of \[:code128/, fn ->
        Builder.barcode_in_rect(Builder.new(), rect, untyped(:pdf417), "data")
      end

      assert_raise ArgumentError, ~r/^invalid :color, a barcode needs one/, fn ->
        Builder.qr_code(Builder.new(), "data", color: nil)
      end

      assert_raise ArgumentError, ~r/^invalid :error_correction, expected one of/, fn ->
        Builder.qr_code_in_rect(Builder.new(), rect, "data", error_correction: :max)
      end

      assert_raise ArgumentError,
                   ~r/^invalid :width, a 500.0-point barcode does not fit the 468.0-point content width/,
                   fn ->
                     Builder.barcode(Builder.new(), :code128, "data", width: 500)
                   end

      assert_raise ArgumentError, ~r/^invalid :height, a 400.0-point QR code does not fit/, fn ->
        Builder.new() |> Builder.page({800, 500}) |> Builder.qr_code("data", size: 400)
      end

      assert_raise ArgumentError,
                   ~r/^invalid height, a 18.0-point barcode leaves no room for bars/,
                   fn ->
                     Builder.barcode_in_rect(
                       Builder.new(),
                       %{rect | height: 18.0},
                       :ean13,
                       "590123412345",
                       text: true
                     )
                   end
    end
  end

  describe "links" do
    defp links(doc, page) do
      for %{subtype: :link} = link <- Document.annotations!(doc, page), do: link
    end

    test "an area link is clipped to the page" do
      link = fn rect ->
        doc = Builder.new() |> Builder.link_in_rect(rect, "https://example.com") |> written()
        assert [%{rect: rect}] = links(doc, 0)
        rect
      end

      assert link.(%Rect{x: -100_000_000.0, y: 72.0, width: 100_000_001.0, height: 20.0}) ==
               %Rect{x: 0.0, y: 72.0, width: 1.0, height: 20.0}

      assert link.(%Rect{x: -1.0e30, y: -1.0e30, width: 2.0e30, height: 2.0e30}) ==
               %Rect{x: 0.0, y: 0.0, width: 612.0, height: 792.0}

      assert Builder.new(page_size: {1.0e9, 792})
             |> Builder.link_in_rect(
               %Rect{x: 1.0e9 - 1, y: 0, width: 10, height: 10},
               "https://example.com"
             )
             |> refusal() =~ "op 0 on page 0: where the link's area overlaps the page"

      assert Builder.new()
             |> Builder.link_in_rect(
               %Rect{x: 0, y: 500, width: 0.000001, height: 20},
               "https://example.com"
             )
             |> refusal() =~ "under 0.00001 points across once written"
    end

    defp quad_points(bytes) do
      for [points] <- Regex.scan(~r{/QuadPoints \[([^\]]*)\]}, bytes, capture: :all_but_first) do
        points
        |> String.split()
        |> Enum.map(&String.to_float(&1 <> if(&1 =~ ".", do: "", else: ".0")))
      end
    end

    defp link_objects(bytes) do
      numbers = fn text ->
        text |> String.split() |> Enum.map(&elem(Float.parse(&1), 0))
      end

      for [object] <- Regex.scan(~r/obj(.*?)endobj/s, bytes, capture: :all_but_first),
          object =~ "/QuadPoints" do
        [rect] = Regex.run(~r{/Rect \[([^\]]*)\]}, object, capture: :all_but_first)
        [quads] = Regex.run(~r{/QuadPoints \[([^\]]*)\]}, object, capture: :all_but_first)
        points = quads |> numbers.() |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)
        {numbers.(rect), points}
      end
    end

    # Read the file: annotation extraction returns page object numbers, not indices.
    defp destinations(bytes) do
      [[kids]] = Regex.scan(~r{/Kids \[([^\]]*)\]}, bytes, capture: :all_but_first)
      pages = ~r/(\d+) 0 R/ |> Regex.scan(kids, capture: :all_but_first) |> List.flatten()

      for [object, rest] <-
            Regex.scan(~r{/Dest \[(\d+) 0 R ([^\]]*)\]}, bytes, capture: :all_but_first) do
        {Enum.find_index(pages, &(&1 == object)), String.split(rest)}
      end
    end

    defp inside?(%Rect{} = rect, %Rect{} = box) do
      {x, y} = {box.x + box.width / 2, box.y + box.height / 2}
      x > rect.x and x < rect.x + rect.width and y > rect.y and y < rect.y + rect.height
    end

    test "a linked run covers its own text and opens its URI" do
      doc =
        Builder.new()
        |> Builder.paragraph(["Read ", {"the docs", link: "https://example.com/docs"}, " today."])
        |> written()

      assert [%{action: {:uri, "https://example.com/docs"}, destination: nil, rect: rect}] =
               links(doc, 0)

      chars = doc |> Document.chars!(0) |> Enum.reject(&(&1.text == " "))
      assert Enum.map_join(chars, & &1.text) == "Readthedocstoday."
      {before, rest} = Enum.split(chars, 4)
      {linked, rest} = Enum.split(rest, 7)

      assert Enum.all?(linked, &inside?(rect, &1.bbox))
      refute Enum.any?(before ++ rest, &inside?(rect, &1.bbox))
    end

    test "a linked run that wraps is one link with a quadrilateral for each line" do
      text = String.duplicate("linked words ", 12)

      builder =
        Builder.new(page_size: {300, 400})
        |> Builder.paragraph([{text, link: "https://example.com"}])

      doc = written(builder)
      [link] = links(doc, 0)
      [quads] = builder |> Builder.to_binary!(compress: false) |> quad_points()
      lines = baselines(doc, 0)

      assert length(lines) > 1
      assert length(quads) == 8 * length(lines)
      assert_in_delta link.rect.x, 72, 0.001
    end

    test "a link's rect contains every quadrilateral as written" do
      text = "a bb ccc link words wrap here there example docs reference"

      for box_y <- [200.1, 333.3], size <- [12, 11, 9.5] do
        objects =
          Builder.new()
          |> Builder.text_in_rect(
            %Rect{x: 72, y: box_y, width: 100.3, height: 100.2},
            [{text, link: "https://example.com"}],
            font_size: size
          )
          |> Builder.to_binary!(compress: false)
          |> link_objects()

        assert [{[x0, y0, x1, y1], points}] = objects
        assert length(points) > 4

        for {x, y} <- points do
          assert x >= x0 and x <= x1 and y >= y0 and y <= y1,
                 "#{size}-point text at #{box_y}: {#{x}, #{y}} outside #{inspect([x0, y0, x1, y1])}"
        end
      end
    end

    test "a linked run broken by a page is one link on each page" do
      doc =
        Builder.new(page_size: {300, 200})
        |> Builder.paragraph([{String.duplicate("more words ", 30), link: "https://example.com"}])
        |> written()

      assert Document.page_count!(doc) > 1

      for page <- 0..(Document.page_count!(doc) - 1) do
        assert [%{action: {:uri, "https://example.com"}}] = links(doc, page)
      end
    end

    test "separate runs to one target stay separate, and different targets are not merged" do
      doc =
        Builder.new()
        |> Builder.paragraph([
          {"one", link: "https://a.example"},
          " and ",
          {"two", link: "https://a.example"},
          {"three", link: "https://b.example"}
        ])
        |> written()

      assert Enum.map(links(doc, 0), & &1.action) == [
               {:uri, "https://a.example"},
               {:uri, "https://a.example"},
               {:uri, "https://b.example"}
             ]
    end

    test "links work in headings, lists, positioned text, boxes and cells" do
      link = fn name -> {name, link: "https://example.com/#{name}"} end

      doc =
        Builder.new()
        |> Builder.heading(1, [link.("heading")])
        |> Builder.bullet_list([[link.("item")]])
        |> Builder.text_at({72, 300}, [link.("at")])
        |> Builder.text_in_rect(%Rect{x: 72.0, y: 200.0, width: 200.0, height: 40.0}, [
          link.("box")
        ])
        |> Builder.table([[[link.("cell")]]])
        |> written()

      assert doc |> links(0) |> Enum.map(fn %{action: {:uri, uri}} -> uri end) |> Enum.sort() ==
               Enum.sort(
                 for name <- ~w(heading item at box cell), do: "https://example.com/#{name}"
               )
    end

    test "link_in_rect/3 makes an area of the current page a link" do
      doc =
        Builder.new()
        |> Builder.paragraph("first")
        |> Builder.page()
        |> Builder.link_in_rect(
          %Rect{x: 172.0, y: 120.0, width: -100.0, height: -20.0},
          "https://example.com"
        )
        |> written()

      assert links(doc, 0) == []

      assert [%{action: {:uri, "https://example.com"}, rect: rect}] = links(doc, 1)
      assert {rect.x, rect.y, rect.width, rect.height} == {72.0, 100.0, 100.0, 20.0}
    end

    test "a page link fits that page in the window" do
      bytes =
        Builder.new()
        |> Builder.paragraph([{"next", link: {:page, 1}}])
        |> Builder.page()
        |> Builder.link_in_rect(%Rect{x: 72.0, y: 72.0, width: 10.0, height: 10.0}, {:page, 0})
        |> Builder.to_binary!(compress: false)

      assert destinations(bytes) == [{1, ["/Fit"]}, {0, ["/Fit"]}]
    end

    test "a page past the last one is refused, naming the op" do
      message =
        Builder.new()
        |> Builder.paragraph("first")
        |> Builder.paragraph([{"nowhere", link: {:page, 1}}])
        |> refusal()

      assert message =~ "op 1 on page 0"
      assert message =~ "page 1, but the document has 1 page,"
    end
  end

  describe "anchor/2" do
    test "a link to an anchor goes to the top of the content after it, wherever it lands" do
      bytes =
        Builder.new(page_size: {300, 300})
        |> Builder.paragraph([{"to the end", link: {:anchor, "end"}}])
        |> Builder.paragraph(Enum.join(1..6, "\n"))
        |> Builder.anchor("end")
        |> Builder.heading(2, "End")
        |> Builder.to_binary!(compress: false)

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)

      assert Document.page_count!(doc) == 2
      assert destinations(bytes) == [{1, ["/XYZ", "null", "228", "null"]}]
    end

    test "an anchor may come after its links, and one at the end points where the flow ends" do
      bytes =
        Builder.new()
        |> Builder.paragraph([{"later", link: {:anchor, "later"}}])
        |> Builder.anchor("later")
        |> Builder.to_binary!(compress: false)

      assert destinations(bytes) == [{0, ["/XYZ", "null", "702", "null"]}]
    end

    test "an anchor no call names is refused, naming it" do
      message =
        Builder.new()
        |> Builder.anchor("there")
        |> Builder.paragraph([{"lost", link: {:anchor, "nowhere"}}])
        |> refusal()

      assert message =~ "op 1 on page 0"
      assert message =~ ~s(anchor "nowhere")
    end
  end

  describe "watermark/3" do
    defp marks(doc) do
      for %{subtype: :watermark} = mark <- Document.annotations!(doc), do: mark
    end

    defp center(%Rect{x: x, y: y, width: width, height: height}),
      do: {x + width / 2, y + height / 2}

    test "the largest size and the farthest center it accepts still read back" do
      doc =
        Builder.new()
        |> Builder.watermark("W", font_size: 1.0e18 / 6, center: {-1.0e18, 1.0e18})
        |> written()

      assert [%{rect: %Rect{x: x, y: y}}] = marks(doc)
      assert x < -1.0e18 and y > 0
    end

    test ":current marks one page, and :all every page wherever it is called" do
      doc =
        Builder.new(page_size: {300, 300})
        |> Builder.watermark("ONE")
        |> Builder.paragraph(Enum.join(1..20, "\n"))
        |> Builder.watermark("ALL", pages: :all)
        |> written()

      assert Document.page_count!(doc) == 3
      assert doc |> marks() |> Enum.frequencies_by(& &1.page) == %{0 => 2, 1 => 1, 2 => 1}
    end

    test "is centered on each page it marks, or on :center" do
      doc =
        Builder.new()
        |> Builder.watermark("ALL", pages: :all)
        |> Builder.watermark("HERE", pages: :all, center: {100, 100})
        |> Builder.paragraph("first")
        |> Builder.page({300, 400})
        |> written()

      [[all_0, here_0], [all_1, here_1]] =
        doc
        |> marks()
        |> Enum.chunk_by(& &1.page)
        |> Enum.map(fn marks -> Enum.map(marks, & &1.rect) end)

      # The box is offset from the text's center by an amount that depends on
      # the text alone, so equal offsets mean equal centering.
      {x0, y0} = center(all_0)
      {x1, y1} = center(all_1)
      assert_in_delta x0 - 306, x1 - 150, 0.001
      assert_in_delta y0 - 396, y1 - 200, 0.001
      assert here_0 == here_1
    end

    test "is a printable, read-only annotation with the opacity given" do
      builder = Builder.new() |> Builder.watermark("DRAFT", opacity: 0.5)

      assert [%{page: 0, flags: %{print: true, read_only: true}}] =
               builder |> written() |> marks()

      assert builder |> Builder.to_binary!(compress: false) =~ "/ca 0.5"
    end

    test "flattening draws it into the page's content" do
      builder = Builder.new() |> Builder.watermark("DRAFT", opacity: 1.0)

      blank? = fn doc ->
        %{data: data} =
          Document.render!(doc, 0, dpi: 18, format: :rgba8, render_annotations: false)

        data == :binary.copy(<<255>>, byte_size(data))
      end

      flattened = builder |> Editor.from_builder!() |> Editor.flatten_annotations!() |> written()

      assert builder |> written() |> blank?.()
      assert marks(flattened) == []
      refute blank?.(flattened)
    end
  end

  describe "form fields" do
    alias PdfElixide.Form
    alias PdfElixide.Form.Field
    alias PdfElixide.Signature

    defp box(x, y, width \\ 150, height \\ 20),
      do: %Rect{x: x, y: y, width: width, height: height}

    defp blank?(doc) do
      %{data: data} = Document.render!(doc, 0, dpi: 18, format: :rgba8)
      data == :binary.copy(<<255>>, byte_size(data))
    end

    test "each kind reads back as the field it was built as" do
      doc =
        Builder.new()
        |> Builder.text_field("full_name", box(100, 650),
          value: "Jane",
          default_value: "Doe",
          required: true,
          tooltip: "Ваше имя"
        )
        |> Builder.check_box("agree", box(100, 600, 15, 15), checked: true, read_only: true)
        |> Builder.check_box("spam", box(130, 600, 15, 15))
        |> Builder.combo_box("country", box(100, 550), ["UA", "PL"], selected: "PL")
        |> Builder.list_box("langs", box(100, 450, 150, 80), ["en", "uk", "pl"],
          multi_select: true,
          selected: ["en", "pl"]
        )
        |> Builder.list_box("size", box(300, 450, 150, 80), ["S", "M"], selected: "M")
        |> Builder.push_button("go", box(100, 400), "Go", tooltip: "press")
        |> written()

      assert [
               %Field.Text{
                 name: "full_name",
                 kind: :single_line,
                 value: "Jane",
                 default_value: "Doe",
                 tooltip: "Ваше имя",
                 rect: %Rect{x: 100.0, y: 650.0, width: 150.0, height: 20.0},
                 flags: %Field.Text.Flags{required: true, read_only: false}
               },
               %Field.Button{
                 name: "agree",
                 kind: :check_box,
                 value: true,
                 flags: %Field.Button.Flags{read_only: true}
               },
               %Field.Button{name: "spam", kind: :check_box, value: false},
               %Field.Choice{
                 name: "country",
                 kind: :combo_box,
                 value: "PL",
                 options: ["UA", "PL"]
               },
               %Field.Choice{
                 name: "langs",
                 kind: :list_box,
                 value: ["en", "pl"],
                 flags: %Field.Choice.Flags{multi_select: true}
               },
               %Field.Choice{name: "size", kind: :list_box, value: "M"},
               %Field.Button{name: "go", kind: :push, tooltip: "press"}
             ] = Form.fields!(doc)
    end

    test "a field has no appearance of its own until the form is flattened" do
      builder = Builder.new() |> Builder.check_box("agree", box(100, 600, 15, 15), checked: true)
      doc = written(builder)

      assert [%Field.Button{on_states: []}] = Form.fields!(doc)
      refute Builder.to_binary!(builder, compress: false) =~ "/AP"
      assert blank?(doc)
      refute builder |> Editor.from_builder!() |> Form.flatten!() |> written() |> blank?()
    end

    test "flattening draws a value only where it is a single string" do
      flattened = fn builder ->
        builder
        |> Editor.from_builder!()
        |> Form.flatten!()
        |> Editor.to_binary!(compress: false)
      end

      drawn = [
        Builder.text_field(Builder.new(), "t", box(100, 450), value: "hello"),
        Builder.combo_box(Builder.new(), "c", box(100, 450), ["en", "uk"], selected: "uk"),
        Builder.list_box(Builder.new(), "l", box(100, 450, 150, 80), ["en", "uk"], selected: "uk")
      ]

      for builder <- drawn, do: assert(flattened.(builder) =~ ~r/\((hello|uk)\) Tj/)

      multi =
        Builder.list_box(Builder.new(), "l", box(100, 450, 150, 80), ["en", "uk"],
          multi_select: true,
          selected: ["en", "uk"]
        )

      refute flattened.(multi) =~ "Tj"

      refute Builder.new() |> Builder.push_button("go", box(100, 300), "Go") |> flattened.() =~
               "Tj"
    end

    test "a flattened value draws only its ASCII characters as written" do
      flattened =
        Builder.new()
        |> Builder.text_field("t", box(100, 450), value: "café")
        |> Editor.from_builder!()
        |> Form.flatten!()
        |> Editor.to_binary!(compress: false)

      assert flattened =~ "(caf\xEF\xBF\xBD) Tj"
      refute flattened =~ "(caf\xE9) Tj"
    end

    test "text resembling a byte-order mark reads back as written" do
      for text <- ["aþÿ", "þ", "ÿ", "ï»", "þa"] do
        doc =
          Builder.new(title: text)
          |> Builder.paragraph("x")
          |> Builder.text_field(text, box(100, 650),
            value: text,
            default_value: text,
            tooltip: text
          )
          |> Builder.combo_box("c", box(100, 600), [text], selected: text)
          |> written()

        assert Document.metadata!(doc).title == text

        assert [
                 %Field.Text{name: ^text, value: ^text, default_value: ^text, tooltip: ^text},
                 %Field.Choice{value: ^text, options: [^text]}
               ] = Form.fields!(doc)
      end
    end

    test "one-byte text that is not UTF-8 reads back as written" do
      for text <- ["£", "é", "Â£€"] do
        doc =
          Builder.new()
          |> Builder.text_field("t", box(100, 650), value: text, tooltip: text)
          |> Builder.combo_box("c", box(100, 600), [text, "other"], selected: text)
          |> written()

        assert [
                 %Field.Text{value: ^text, tooltip: ^text},
                 %Field.Choice{value: ^text, options: [^text, "other"]}
               ] = Form.fields!(doc)
      end
    end

    test "filling a value keeps the document information" do
      metadata =
        Builder.new(title: "Report", author: "Jane")
        |> Builder.text_field("t", box(100, 650), value: "v")
        |> written()
        |> Document.metadata!()

      assert %{title: "Report", author: "Jane"} = metadata
    end

    test "an editor opened on the builder holds the same fields, unmodified" do
      builder =
        Builder.new()
        |> Builder.text_field("full_name", box(100, 650), value: "Jane")
        |> Builder.list_box("langs", box(100, 450, 150, 80), ["en", "uk"],
          multi_select: true,
          selected: ["uk"]
        )

      editor = builder |> Editor.from_builder!()
      on_exit(fn -> Editor.close(editor) end)

      refute Editor.modified?(editor)
      assert Form.fields!(editor) == Form.fields!(written(builder))
    end

    test "a built field can be filled afterwards" do
      doc =
        Builder.new()
        |> Builder.text_field("full_name", box(100, 650))
        |> Builder.check_box("agree", box(100, 600, 15, 15))
        |> Editor.from_builder!()
        |> Form.put_values!(%{"full_name" => "Jane", "agree" => true})
        |> written()

      assert Form.value!(doc, "full_name") == "Jane"
      assert Form.value!(doc, "agree") == true
    end

    test "a field lands on the page it was added to" do
      doc =
        Builder.new()
        |> Builder.text_field("first", box(100, 650))
        |> Builder.page()
        |> Builder.text_field("second", box(100, 650))
        |> written()

      assert [%{field_name: "first"}] = Document.annotations!(doc, 0)
      assert [%{field_name: "second"}] = Document.annotations!(doc, 1)
    end

    test "a signature field is an unsigned signature field, not a form field" do
      doc =
        Builder.new()
        |> Builder.signature_field("approval", box(100, 200), tooltip: "Sign here")
        |> written()

      assert Signature.unsigned_fields!(doc) == ["approval"]
      assert Signature.list!(doc) == []
      assert Form.fields!(doc) == []
    end

    test "names and tooltips may hold any text, values only what the font draws" do
      doc =
        Builder.new()
        |> Builder.text_field("Имя (полное)", box(100, 650),
          value: "Ça coûte 5 € – “ok”",
          tooltip: "名前"
        )
        |> written()

      assert [%Field.Text{name: "Имя (полное)", value: "Ça coûte 5 € – “ok”", tooltip: "名前"}] =
               Form.fields!(doc)
    end
  end

  describe "scripts" do
    defp field_box(y), do: %Rect{x: 72.0, y: y, width: 150.0, height: 20.0}

    defp objects(bytes) do
      for [number, object] <-
            Regex.scan(~r/(\d+) 0 obj(.*?)endobj/s, bytes, capture: :all_but_first),
          into: %{},
          do: {number, object}
    end

    # Each action dictionary under a one-letter key — a trigger in `/AA`, or a
    # link's `/A` — or under `/OpenAction`, with its decoded `/JS`.
    defp scripts_of(object) do
      ~r{/([A-Z]|OpenAction)\s*<<(?:(?!>>).)*?/JS\s*(\((?:[^()\\]|\\.)*\)|<[0-9A-Fa-f\s]*>)}s
      |> Regex.scan(object, capture: :all_but_first)
      |> Map.new(fn [key, literal] -> {key, literal(literal)} end)
    end

    defp literal("<" <> hex) do
      hex
      |> String.trim_trailing(">")
      |> String.replace(~r/\s/, "")
      |> Base.decode16!(case: :mixed)
      |> decoded()
    end

    defp literal(text),
      do: text |> binary_part(1, byte_size(text) - 2) |> unescape(<<>>) |> decoded()

    defp decoded(<<0xFE, 0xFF, utf16::binary>>),
      do: :unicode.characters_to_binary(utf16, {:utf16, :big})

    defp decoded(bytes), do: :unicode.characters_to_binary(bytes, :latin1)

    @escapes %{?n => ?\n, ?r => ?\r, ?t => ?\t, ?b => ?\b, ?f => ?\f}

    defp unescape(<<?\\, a, b, c, rest::binary>>, acc)
         when a in ?0..?7 and b in ?0..?7 and c in ?0..?7,
         do: unescape(rest, <<acc::binary, List.to_integer([a, b, c], 8)>>)

    defp unescape(<<?\\, char, rest::binary>>, acc),
      do: unescape(rest, <<acc::binary, Map.get(@escapes, char, char)>>)

    defp unescape(<<char, rest::binary>>, acc), do: unescape(rest, <<acc::binary, char>>)
    defp unescape(<<>>, acc), do: acc

    defp catalog_scripts(bytes) do
      [catalog] = for {_, object} <- objects(bytes), object =~ "/Type /Catalog", do: object
      scripts_of(catalog)
    end

    defp page_scripts(bytes) do
      objects = objects(bytes)
      [[kids]] = Regex.scan(~r{/Kids \[([^\]]*)\]}, bytes, capture: :all_but_first)

      for [number] <- Regex.scan(~r/(\d+) 0 R/, kids, capture: :all_but_first) do
        case Regex.run(~r{/AA\s*<<(.*?>>)\s*>>}s, objects[number], capture: :all_but_first) do
          [triggers] -> scripts_of(triggers)
          nil -> %{}
        end
      end
    end

    defp field_scripts(bytes, name) do
      [field] = for {_, object} <- objects(bytes), object =~ "/T (#{name})", do: object

      case Regex.run(~r{/AA\s*<<(.*?>>)\s*>>}s, field, capture: :all_but_first) do
        [triggers] -> scripts_of(triggers)
        nil -> %{}
      end
    end

    defp link_scripts(bytes) do
      for {_, object} <- objects(bytes), object =~ "/Subtype /Link", do: scripts_of(object)
    end

    test "a script link runs its code, from a run or an area" do
      code = "app.alert(\"(unbalanced ) \\\\ \\u00e9\");\r\nvar total = 1;"

      builder =
        Builder.new()
        |> Builder.paragraph(["Run ", {"this", link: {:script, code}}])
        |> Builder.link_in_rect(field_box(500.0), {:script, "app.beep(0);"})

      bytes = Builder.to_binary!(builder, compress: false)
      doc = Document.from_binary!(bytes)

      assert [{:other, "JavaScript"}, {:other, "JavaScript"}] =
               for(%{subtype: :link, action: action} <- Document.annotations!(doc, 0), do: action)

      assert link_scripts(bytes) == [%{"A" => code}, %{"A" => "app.beep(0);"}]
    end

    test "a script that is not Latin-1 text is written whole" do
      code = "app.alert('Привіт, 世界');"
      bytes = Builder.new(scripts: [open: code]) |> Builder.to_binary!(compress: false)

      assert catalog_scripts(bytes) == %{"OpenAction" => code}
    end

    test "document, page and field scripts are written where a viewer runs them" do
      builder =
        Builder.new(scripts: [open: "this.print();"])
        |> Builder.paragraph("One")
        |> Builder.page_scripts(open: "shown();", close: "left();")
        |> Builder.text_field("total", field_box(600.0),
          scripts: [keystroke: "k();", format: "f();", validate: "v();"]
        )
        |> Builder.combo_box("country", field_box(550.0), ["UA", "PL"],
          scripts: [keystroke: "ck();", validate: "cv();"]
        )
        |> Builder.list_box("size", %Rect{x: 72.0, y: 450.0, width: 150.0, height: 60.0}, ["S"],
          scripts: [validate: "lv();"]
        )
        |> Builder.check_box("agree", %Rect{x: 72.0, y: 400.0, width: 15.0, height: 15.0})

      bytes = Builder.to_binary!(builder, compress: false)

      assert catalog_scripts(bytes) == %{"OpenAction" => "this.print();"}
      assert page_scripts(bytes) == [%{"O" => "shown();", "C" => "left();"}]
      assert field_scripts(bytes, "total") == %{"K" => "k();", "F" => "f();", "V" => "v();"}
      assert field_scripts(bytes, "country") == %{"K" => "ck();", "V" => "cv();"}
      assert field_scripts(bytes, "size") == %{"V" => "lv();"}
      assert field_scripts(bytes, "agree") == %{}
    end

    test "scripts survive the pass that sets field values, and a later save" do
      builder =
        Builder.new(scripts: [open: "o();"])
        |> Builder.paragraph([{"x", link: {:script, "a();"}}])
        |> Builder.page_scripts(open: "p();")
        |> Builder.text_field("name", field_box(600.0),
          value: "Jane",
          scripts: [validate: "v();"]
        )

      editor = Editor.from_builder!(builder)
      on_exit(fn -> Editor.close(editor) end)

      for bytes <- [
            Builder.to_binary!(builder, compress: false),
            Editor.to_binary!(editor, compress: false)
          ] do
        assert catalog_scripts(bytes) == %{"OpenAction" => "o();"}
        assert page_scripts(bytes) == [%{"O" => "p();"}]
        assert field_scripts(bytes, "name") == %{"V" => "v();"}
        assert link_scripts(bytes) == [%{"A" => "a();"}]
      end
    end

    test "sanitizing removes the document's open script only" do
      builder =
        Builder.new(scripts: [open: "o();"])
        |> Builder.paragraph([{"x", link: {:script, "a();"}}])
        |> Builder.page_scripts(close: "c();")
        |> Builder.text_field("name", field_box(600.0), scripts: [format: "f();"])

      editor = Editor.from_builder!(builder)
      on_exit(fn -> Editor.close(editor) end)
      Editor.sanitize!(editor)
      bytes = Editor.to_binary!(editor, compress: false)

      assert catalog_scripts(bytes) == %{}
      assert page_scripts(bytes) == [%{"C" => "c();"}]
      assert field_scripts(bytes, "name") == %{"F" => "f();"}
      assert link_scripts(bytes) == [%{"A" => "a();"}]
    end

    test "page scripts go to the page the next content lands on" do
      bytes =
        Builder.new()
        |> Builder.paragraph("One")
        |> Builder.page_scripts(open: "two();")
        |> Builder.page()
        |> Builder.paragraph("Two")
        |> Builder.page()
        |> Builder.paragraph("Three")
        |> Builder.page_scripts(close: "last();")
        |> Builder.to_binary!(compress: false)

      assert page_scripts(bytes) == [%{}, %{"O" => "two();"}, %{"C" => "last();"}]
    end

    test "a second page_scripts/2 on the same page is refused" do
      message =
        Builder.new()
        |> Builder.page_scripts(open: "a();")
        |> Builder.page_scripts(close: "b();")
        |> Builder.paragraph("x")
        |> refusal()

      assert message =~ "op 0: its page_scripts/2 setting would start on page 0, where op 1"
    end

    test "a script must be text a viewer reads as written" do
      link = &Builder.paragraph(Builder.new(), [{"x", link: {:script, &1}}])

      assert_raise ArgumentError,
                   ~r/^invalid :link, a script needs code other than whitespace/,
                   fn ->
                     link.(" \n")
                   end

      assert_raise ArgumentError, ~r/^invalid :open, a script needs code other than/, fn ->
        Builder.new(scripts: [open: ""])
      end

      assert_raise ArgumentError, ~r/^invalid :validate, text starting with/, fn ->
        Builder.text_field(Builder.new(), "f", field_box(600.0), scripts: [validate: "þÿx"])
      end

      assert_raise ArgumentError, ~r/^invalid :close, a script cannot hold "\\u00A0"/, fn ->
        Builder.page_scripts(Builder.new(), close: "a\u00A0b")
      end

      assert_raise ArgumentError, ~r/^invalid :keystroke, expected a string: 1/, fn ->
        Builder.combo_box(Builder.new(), "f", field_box(600.0), ["a"],
          scripts: [keystroke: untyped(1)]
        )
      end

      assert_raise ArgumentError, ~r/^invalid :scripts, expected a keyword list: "x"/, fn ->
        Builder.new(scripts: untyped("x"))
      end

      assert_raise ArgumentError,
                   ~r/^invalid scripts, expected at least one of :open and :close/,
                   fn ->
                     Builder.page_scripts(Builder.new(), [])
                   end
    end

    test "a field takes only the scripts its kind runs" do
      rect = field_box(600.0)

      refused = [
        fn -> Builder.text_field(Builder.new(), "f", rect, scripts: [calculate: "c();"]) end,
        fn -> Builder.combo_box(Builder.new(), "f", rect, ["a"], scripts: [format: "f();"]) end,
        fn -> Builder.list_box(Builder.new(), "f", rect, ["a"], scripts: [keystroke: "k();"]) end,
        fn -> Builder.new(scripts: [close: "c();"]) end
      ]

      for call <- refused, do: assert_raise(ArgumentError, ~r/unknown keys/, call)

      without = [
        fn -> Builder.check_box(Builder.new(), "f", rect, scripts: [validate: "v();"]) end,
        fn ->
          Builder.push_button(Builder.new(), "f", rect, "Go", scripts: [validate: "v();"])
        end,
        fn -> Builder.signature_field(Builder.new(), "f", rect, scripts: [validate: "v();"]) end
      ]

      for call <- without, do: assert_raise(ArgumentError, ~r/unknown keys \[:scripts\]/, call)
    end
  end

  describe "bookmarks" do
    defp titles(items), do: Enum.map(items, &{&1.title, &1.dest, titles(&1.children)})

    test "levels nest bookmarks, and a heading's bookmark takes its text and level" do
      doc =
        Builder.new()
        |> Builder.heading(1, "One", bookmark: true)
        |> Builder.heading(2, ["Two ", {"words", italic: true}], bookmark: true)
        |> Builder.bookmark("Three", level: 3)
        |> Builder.paragraph("x")
        |> Builder.heading(2, "Four", bookmark: "Fourth")
        |> Builder.bookmark("Five")
        |> Builder.paragraph("y")
        |> written()

      assert doc |> Document.outline!() |> titles() == [
               {"One", {:page, 0},
                [
                  {"Two words", {:page, 0}, [{"Three", {:page, 0}, []}]},
                  {"Fourth", {:page, 0}, []}
                ]},
               {"Five", {:page, 0}, []}
             ]
    end

    test "a bookmark points to the top of the content after it, wherever it lands" do
      bytes =
        Builder.new(page_size: {300, 300})
        |> Builder.paragraph("first")
        |> Builder.paragraph(Enum.join(1..6, "\n"))
        |> Builder.bookmark("End")
        |> Builder.heading(2, "End")
        |> Builder.to_binary!(compress: false)

      assert destinations(bytes) == [{1, ["/XYZ", "null", "228", "null"]}]
    end

    test "a bookmark can point to a page or an anchor instead" do
      bytes =
        Builder.new()
        |> Builder.bookmark("Cover", to: {:page, 0})
        |> Builder.bookmark("Later", to: {:anchor, "later"})
        |> Builder.paragraph("first")
        |> Builder.anchor("later")
        |> Builder.paragraph("second")
        |> Builder.to_binary!(compress: false)

      assert destinations(bytes) == [{0, ["/Fit"]}, {0, ["/XYZ", "null", "696", "null"]}]
    end

    test "a bookmark's style and whether its children show are written" do
      bytes =
        Builder.new()
        |> Builder.bookmark("Closed", open: false, bold: true, italic: true)
        |> Builder.bookmark("Child", level: 2, color: %RGB{r: 1.0, g: 0.0, b: 0.0})
        |> Builder.paragraph("x")
        |> Builder.to_binary!(compress: false)

      [closed] = Regex.run(~r{<<[^>]*/Title \(Closed\)[^>]*>>}, bytes)
      [child] = Regex.run(~r{<<[^>]*/Title \(Child\)[^>]*>>}, bytes)

      assert closed =~ "/Count -1"
      assert closed =~ "/F 3"
      assert child =~ ~r{/C \[1(\.0+)? 0(\.0+)? 0(\.0+)?\]}
      refute child =~ "/F "
    end

    test "a page past the last one, or an anchor no call names, is refused" do
      message =
        Builder.new()
        |> Builder.paragraph("only")
        |> Builder.bookmark("Gone", to: {:page, 3})
        |> refusal()

      assert message =~ "op 1: the bookmark points to page 3, but the document has 1 page,"

      message =
        Builder.new()
        |> Builder.bookmark("Lost", to: {:anchor, "nowhere"})
        |> refusal()

      assert message =~ ~s(op 0: the bookmark points to anchor "nowhere")
    end
  end

  describe "page_labels/3" do
    test "a range starts on the page its next content lands on, even after a page break" do
      doc =
        Builder.new(page_size: {300, 300})
        |> Builder.paragraph(Enum.join(1..8, "\n"))
        |> Builder.page_labels(:roman_upper)
        |> Builder.paragraph("next")
        |> Builder.page()
        |> Builder.page_labels(:decimal, prefix: "A-", start: 5)
        |> Builder.paragraph("a")
        |> Builder.page()
        |> Builder.paragraph("b")
        |> written()

      assert Document.page_labels!(doc) == ["1", "I", "A-5", "A-6"]
    end

    test "every style, and pages before the first range numbered from 1" do
      labels =
        for style <- [:decimal, :roman_lower, :roman_upper, :alpha_lower, :alpha_upper, :none] do
          Builder.new()
          |> Builder.paragraph("cover")
          |> Builder.page()
          |> Builder.page_labels(style, start: 28)
          |> Builder.paragraph("body")
          |> written()
          |> Document.page_labels!()
        end

      assert labels == [
               ["1", "28"],
               ["1", "xxviii"],
               ["1", "XXVIII"],
               ["1", "bb"],
               ["1", "BB"],
               ["1", ""]
             ]
    end

    test "a document without ranges writes no labels" do
      bytes = Builder.new() |> Builder.paragraph("x") |> Builder.to_binary!(compress: false)

      refute bytes =~ "/PageLabels"
    end

    test "a range replaced on its own first page is refused" do
      message =
        Builder.new()
        |> Builder.page_labels(:roman_lower)
        |> Builder.page_labels(:decimal)
        |> Builder.paragraph("x")
        |> refusal()

      assert message =~
               "op 0: its page_labels/3 setting would start on page 0, where op 1 replaces it"
    end

    test "{page} letters pages as the labels do, repeating the letter after Z" do
      doc =
        Builder.new()
        |> Builder.page_labels(:alpha_upper, start: 26)
        |> Builder.footer(center: "{page}")
        |> Builder.paragraph("a")
        |> Builder.page()
        |> Builder.paragraph("b")
        |> Builder.page()
        |> Builder.paragraph("c")
        |> written()

      footers =
        for page <- 0..2 do
          doc |> Document.words!(page) |> Enum.find(&(&1.bbox.y < 72)) |> Map.fetch!(:text)
        end

      assert footers == ["Z", "AA", "BB"]
      assert Document.page_labels!(doc) == footers
    end

    test "a label is drawn with each run of whitespace as one space" do
      doc =
        Builder.new()
        |> Builder.page_labels(:decimal, prefix: "A\u2003\t")
        |> Builder.footer(center: "Page {page} of {pages}")
        |> Builder.contents()
        |> Builder.bookmark("Intro")
        |> Builder.paragraph("x")
        |> written()

      assert Document.page_labels!(doc) == ["A\u2003\t1"]
      assert Document.text!(doc, 0) =~ "Intro A 1"
      assert Document.text!(doc, 0) =~ "Page A 1 of 1"
    end

    test "spaces at either end of a label still separate it in a header" do
      doc =
        Builder.new()
        |> Builder.page_labels(:none, prefix: " A\u2003")
        |> Builder.footer(center: "Page{page}of {pages}")
        |> Builder.paragraph("x")
        |> written()

      assert Document.text!(doc, 0) =~ "Page A of 1"
    end

    test "a lettered label past 26000 is refused when built, and cannot be read" do
      message =
        Builder.new()
        |> Builder.page_labels(:alpha_lower, start: 26_000)
        |> Builder.paragraph("a")
        |> Builder.page()
        |> Builder.paragraph("b")
        |> refusal()

      assert message =~ "op 0: the label of page 1 would be past 26000"

      bytes =
        Builder.new()
        |> Builder.page_labels(:decimal, start: 26_001)
        |> Builder.paragraph("a")
        |> Builder.to_binary!(compress: false)

      lettered = String.replace(bytes, "/S /D/St 26001", "/S /A/St 26001")
      assert lettered != bytes
      doc = Document.from_binary!(lettered)
      on_exit(fn -> Document.close(doc) end)

      assert {:error, %Error{reason: :unsupported, message: message}} = Document.page_labels(doc)
      assert message =~ "the label of page 0 counts past 26000 in letters"
      assert {:error, %Error{reason: :unsupported}} = doc |> Document.page!(0) |> Page.label()
    end

    test "a label past 2147483647 is refused, and one at the limit is not" do
      at_limit = fn -> Builder.new() |> Builder.page_labels(:decimal, start: 2_147_483_647) end

      assert at_limit.() |> Builder.paragraph("a") |> written() |> Document.page_labels!() ==
               ["2147483647"]

      message =
        at_limit.()
        |> Builder.paragraph("a")
        |> Builder.page()
        |> Builder.paragraph("b")
        |> refusal()

      assert message =~ "op 0: the label of page 1 would be past 2147483647;"
    end

    test "a Roman numeral past 3999 is refused, naming the page" do
      message =
        Builder.new()
        |> Builder.page_labels(:roman_lower, start: 3999)
        |> Builder.paragraph("a")
        |> Builder.page()
        |> Builder.paragraph("b")
        |> refusal()

      assert message =~ "op 0: the label of page 1 would be past 3999"
    end
  end

  describe "header/2 and footer/2" do
    defp running_words(doc, page, band) do
      for word <- Document.words!(doc, page), band.(word.bbox.y), do: word
    end

    defp header?(y), do: y > 720
    defp footer?(y), do: y < 72

    test "parts sit at the margins and the center, on a line centered in the margin" do
      doc =
        Builder.new()
        |> Builder.header(left: "Left", center: "Middle", right: "Right")
        |> Builder.footer(center: "Foot")
        |> Builder.paragraph("body")
        |> written()

      assert [left, middle, right] = running_words(doc, 0, &header?/1)
      assert_in_delta left.bbox.x, 72, 0.001
      assert_in_delta middle.bbox.x + middle.bbox.width / 2, 306, 0.01
      assert_in_delta right.bbox.x + right.bbox.width, 540, 0.01

      [foot] = running_words(doc, 0, &footer?/1)
      chars = Document.chars!(doc, 0)
      header_char = Enum.find(chars, &(&1.text == "L"))
      footer_char = Enum.find(chars, &(&1.text == "F"))

      assert_in_delta header_char.bbox.y, baseline(792 - (72 - 18) / 2, 12), 0.001
      assert_in_delta footer_char.bbox.y, baseline((72 + 18) / 2, 12), 0.001
      assert foot.text == "Foot"
    end

    test "{page} prints the page's label and {pages} the number of pages" do
      doc =
        Builder.new()
        |> Builder.page_labels(:roman_lower)
        |> Builder.footer(right: "{page} of {pages}", left: "{{page}")
        |> Builder.paragraph("a")
        |> Builder.page()
        |> Builder.paragraph("b")
        |> written()

      for {page, label} <- [{0, "i"}, {1, "ii"}] do
        assert doc |> running_words(page, &footer?/1) |> Enum.map(& &1.text) ==
                 ["{#{label}", label, "of", "2"]
      end
    end

    test "a header runs from the page its next content lands on until replaced or stopped" do
      doc =
        Builder.new()
        |> Builder.header(left: "A")
        |> Builder.paragraph("one")
        |> Builder.page()
        |> Builder.header(left: "B")
        |> Builder.paragraph("two")
        |> Builder.page()
        |> Builder.paragraph("three")
        |> Builder.page()
        |> Builder.header(nil)
        |> Builder.paragraph("four")
        |> written()

      headers =
        for page <- 0..3, do: doc |> running_words(page, &header?/1) |> Enum.map(& &1.text)

      assert headers == [["A"], ["B"], ["B"], []]
    end

    test "content placed outside the flow starts it on the current page" do
      doc =
        Builder.new()
        |> Builder.footer(center: "{page}")
        |> Builder.text_at({72, 400}, "placed")
        |> Builder.page()
        |> Builder.text_at({72, 400}, "again")
        |> written()

      for page <- 0..1 do
        assert doc |> running_words(page, &footer?/1) |> Enum.map(& &1.text) ==
                 ["#{page + 1}"]
      end
    end

    test "any run of whitespace is drawn and measured as one space" do
      doc =
        Builder.new()
        |> Builder.header(right: "a\u2003b  \tc")
        |> Builder.paragraph("x")
        |> written()

      words = running_words(doc, 0, &header?/1)
      last = List.last(words)

      assert Enum.map(words, & &1.text) == ["a", "b", "c"]
      assert_in_delta last.bbox.x + last.bbox.width, 540, 0.01
      assert doc |> Document.text!(0) |> String.starts_with?("a b c")
    end

    test "the text is marked as a header or footer artifact" do
      bytes =
        Builder.new()
        |> Builder.header(left: "Top")
        |> Builder.footer(left: "Bottom")
        |> Builder.paragraph("body")
        |> Builder.to_binary!(compress: false)

      assert bytes =~ "/Artifact <</Type /Pagination /Subtype /Header>> BDC"
      assert bytes =~ "/Artifact <</Type /Pagination /Subtype /Footer>> BDC"
    end

    test "text :auto cannot draw in Helvetica switches the document to DejaVu Sans" do
      doc =
        Builder.new()
        |> Builder.header(left: "Отчёт")
        |> Builder.paragraph("body")
        |> written()

      assert doc |> fonts_by_text() |> Map.fetch!("b") =~ "DejaVuSans"
    end

    test "parts that overlap or do not fit once filled in are refused" do
      long = String.duplicate("wide ", 40)

      assert Builder.new()
             |> Builder.header(center: long)
             |> Builder.paragraph("x")
             |> refusal() =~
               "op 0 on page 0: the header's center part is"

      assert Builder.new()
             |> Builder.footer(
               left: String.duplicate("a ", 30),
               right: String.duplicate("b ", 30)
             )
             |> Builder.paragraph("x")
             |> refusal() =~
               "op 0 on page 0: the footer's left and right parts overlap"
    end

    test "a header replaced on its own first page is refused" do
      message =
        Builder.new()
        |> Builder.header(left: "A")
        |> Builder.header(left: "B")
        |> Builder.paragraph("x")
        |> refusal()

      assert message =~ "op 0: its header/2 setting would start on page 0, where op 1 replaces it"
    end
  end

  describe "contents/2" do
    defp flat(items), do: Enum.flat_map(items, &[&1 | flat(&1.children)])

    test "lists each bookmark with the label of its page, after the contents' own pages" do
      builder =
        Builder.new(page_size: {300, 300})
        |> Builder.page_labels(:roman_lower)
        |> Builder.contents()
        |> Builder.page()
        |> Builder.page_labels(:decimal)

      bytes =
        1..14
        |> Enum.reduce(builder, fn n, builder ->
          builder
          |> Builder.heading(1, "Chapter #{n}", bookmark: true)
          |> Builder.paragraph("text")
        end)
        |> Builder.to_binary!(compress: false)

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)

      labels = Document.page_labels!(doc)
      items = doc |> Document.outline!() |> flat()
      contents = [Document.text!(doc, 0), Document.text!(doc, 1)] |> Enum.join("\n")

      assert length(items) == 14
      assert Enum.take(labels, 2) == ["i", "ii"]

      for %{title: title, dest: {:page, page}} <- items do
        assert contents =~ "#{title} #{Enum.at(labels, page)}"
      end

      links = for page <- 0..1, link <- links(doc, page), do: link
      assert length(links) == 14
    end

    test "a long title wraps, with its label on its last line" do
      doc =
        Builder.new()
        |> Builder.contents()
        |> Builder.bookmark(String.duplicate("long title ", 12))
        |> Builder.paragraph("x")
        |> written()

      {entry, ["x"]} =
        doc |> Document.text!(0) |> String.split("\n", trim: true) |> Enum.split(-1)

      assert length(entry) > 1
      assert List.last(entry) =~ ~r/ 1$/
      refute Enum.any?(Enum.drop(entry, -1), &(&1 =~ ~r/ 1$/))
    end

    test "contents with no bookmarks is refused" do
      assert Builder.new() |> Builder.contents() |> refusal() =~
               "op 0: contents/2 lists the document's bookmarks, but it has none"
    end
  end

  describe "footnotes" do
    # Twelve-point body lines are 18 points tall; notes default to 9.6 points
    # on 14.4-point lines, with one such line for the separator.
    @note_size 9.6
    @note_line 14.4

    defp lines_of(count, prefix \\ "l"), do: Enum.map_join(1..count, "\n", &"#{prefix}#{&1}")

    # Sizes come back as written, in single precision.
    defp sized(doc, page, sizes) do
      doc
      |> Document.chars!(page)
      |> Enum.filter(fn char -> Enum.any?(sizes, &(abs(char.font_size - &1) < 0.001)) end)
    end

    defp note_chars(doc, page), do: sized(doc, page, [@note_size])

    defp body_chars(doc, page), do: sized(doc, page, [12])

    defp note_text(doc, page) do
      doc
      |> sized(page, [@note_size, @note_size * 0.65])
      |> Enum.sort_by(&{-Float.round(&1.bbox.y, 1), &1.bbox.x})
      |> Enum.map_join(& &1.text)
    end

    test "sets the note at the foot of its page, its last line on the bottom margin" do
      doc =
        Builder.new()
        |> Builder.paragraph(["Revenue ", {"rose", footnote: "Audited."}, " on the year."])
        |> written()

      assert Document.page_count!(doc) == 1

      [note_baseline] =
        doc |> note_chars(0) |> Enum.map(&Float.round(&1.bbox.y, 3)) |> Enum.uniq()

      assert_in_delta note_baseline, baseline(72 + @note_line, @note_size), 0.001
      assert note_text(doc, 0) =~ "1 Audited."

      [rule] =
        for %{operations: [{:move_to, x, y}, {:line_to, to, y}]} <- Document.paths!(doc, 0),
            do: {x, to, y}

      assert_in_delta elem(rule, 2), 72 + 1.5 * @note_line, 0.001
      assert_in_delta elem(rule, 1), 72 + 468 / 3, 0.001
    end

    test "draws the mark smaller and raised after the run's text" do
      doc =
        Builder.new()
        |> Builder.paragraph(["A ", {"claim", footnote: "Note."}, " here."])
        |> written()

      chars = Document.chars!(doc, 0)
      body = Enum.find(chars, &(&1.text == "m"))
      mark = Enum.find(chars, &(&1.text == "1" and &1.font_size < 12))
      assert_in_delta mark.font_size, 12 * 0.65, 0.001
      assert_in_delta mark.bbox.y, body.bbox.y + 12 * 0.33, 0.001
      assert mark.bbox.x >= body.bbox.x + body.bbox.width - 0.001
    end

    test "moves a line whose notes do not fit below it to the next page, with them" do
      text = [lines_of(35) <> "\n", {"l36", footnote: "Note."}]
      doc = Builder.new() |> Builder.paragraph(text) |> written()

      assert Document.page_count!(doc) == 2
      assert length(baselines(doc, 0)) == 35
      assert note_chars(doc, 0) == []
      assert body_chars(doc, 1) |> Enum.map_join(& &1.text) == "l36"
      assert note_text(doc, 1) =~ "1 Note."
    end

    test "keeps later lines above the notes already on the page" do
      text = [{"first", footnote: "Note."}, "\n" <> lines_of(36)]
      doc = Builder.new() |> Builder.paragraph(text) |> written()

      # 648 points less two note lines hold 34 body lines.
      floor = 72 + 2 * @note_line
      assert Enum.all?(body_chars(doc, 0), &(&1.bbox.y + 12 * @descent / 1000 >= floor - 0.001))
      assert body_chars(doc, 0) |> Enum.map(& &1.bbox.y) |> Enum.uniq() |> length() == 34
    end

    test "numbers marks across the document and stacks each page's notes in order" do
      doc =
        Builder.new()
        |> Builder.paragraph([{"a", footnote: "First."}, " and ", {"b", footnote: "Second."}])
        |> Builder.page()
        |> Builder.paragraph([{"c", footnote: "Third."}])
        |> written()

      assert note_text(doc, 0) == "1 First.2 Second."
      assert note_text(doc, 1) == "3 Third."
    end

    test "wraps a long note within the margins" do
      note = String.duplicate("word ", 120)
      doc = Builder.new() |> Builder.paragraph([{"a", footnote: note}]) |> written()

      chars = note_chars(doc, 0)
      assert chars |> Enum.map(&Float.round(&1.bbox.y, 3)) |> Enum.uniq() |> length() > 1
      assert Enum.all?(chars, &(&1.bbox.x >= 72 and &1.bbox.x + &1.bbox.width <= 540.001))
    end

    test "keeps a heading with the next line when the heading's note takes the room" do
      doc =
        Builder.new()
        |> Builder.paragraph(lines_of(33))
        |> Builder.heading(1, [{"Heading", footnote: "Note."}], font_size: 12)
        |> Builder.paragraph("Next")
        |> written()

      assert body_chars(doc, 1) |> Enum.map_join(& &1.text) =~ "HeadingNext"
      assert note_text(doc, 1) =~ "1 Note."
    end

    test "sets column notes across the page, below every column" do
      paragraphs = [lines_of(30, "a"), [{"marked", footnote: String.duplicate("wide ", 30)}]]
      doc = Builder.new() |> Builder.columns(paragraphs) |> written()

      notes = note_chars(doc, 0)
      assert Enum.any?(notes, &(&1.bbox.x > 306))
      lowest_note = notes |> Enum.map(& &1.bbox.y) |> Enum.max()
      lowest_body = body_chars(doc, 0) |> Enum.map(& &1.bbox.y) |> Enum.min()
      assert lowest_body > lowest_note + @note_line
    end

    test "carries a split table row's notes onto the page each mark lands on" do
      cell = [
        {lines_of(1), footnote: "Early."},
        "\n" <> lines_of(50, "m") <> "\n",
        {"last", footnote: "Late."}
      ]

      doc = Builder.new() |> Builder.table([[cell]]) |> written()

      assert Document.page_count!(doc) == 2
      assert note_text(doc, 0) == "1 Early."
      assert note_text(doc, 1) == "2 Late."
    end

    test "refuses a word and mark too wide for a cell rather than splitting the mark" do
      nine = Enum.flat_map(1..9, &[{"n#{&1}", footnote: "Note #{&1}."}, " "])

      message =
        Builder.new(font: :courier)
        |> Builder.paragraph(nine)
        |> Builder.table([[[{"a", footnote: "Tenth note"}], "b"]],
          column_widths: [20, {:weight, 1}]
        )
        |> refusal()

      assert message =~ ~s("a10")
      assert message =~ "row 0, column 0"
    end

    test "keeps a mark whole and with its word when a narrow cell splits the word" do
      nine = Enum.flat_map(1..9, &[{"n#{&1}", footnote: "Note #{&1}."}, " "])

      # 20 points of text hold "aa", then "a", then "a" with mark 10.
      doc =
        Builder.new(font: :courier)
        |> Builder.paragraph(nine)
        |> Builder.table([[[{"aaaa", footnote: "Tenth note"}], "b"]],
          column_widths: [28, {:weight, 1}]
        )
        |> written()

      assert length(String.split(note_text(doc, 0), "10 Tenth note")) == 2

      chars = Document.chars!(doc, 0)
      [last_a] = chars |> Enum.filter(&(&1.text == "a")) |> Enum.take(-1)
      # Every mark drawn on the cell's lines, which are below the paragraph's.
      marks =
        Enum.filter(
          chars,
          &(abs(&1.font_size - 7.8) < 0.001 and abs(&1.bbox.y - last_a.bbox.y) < 6)
        )

      assert Enum.map(marks, & &1.text) == ["1", "0"]
      assert Enum.all?(marks, &(abs(&1.bbox.y - (last_a.bbox.y + 12 * 0.33)) < 0.001))
    end

    test "carries a mark with the end of a split word onto the next page" do
      # 78 Helvetica "x"s fill a line exactly, leaving no room for the mark.
      text = [lines_of(35) <> "\n", {String.duplicate("x", 78), footnote: "Note."}]
      doc = Builder.new() |> Builder.paragraph(text) |> written()

      assert note_text(doc, 0) == ""
      assert note_text(doc, 1) == "1 Note."

      chars = Document.chars!(doc, 1)
      [x | _] = Enum.filter(chars, &(&1.text == "x"))
      mark = Enum.find(chars, &(&1.text == "1" and &1.font_size < 12))
      assert_in_delta mark.bbox.y, x.bbox.y + 12 * 0.33, 0.001
    end

    test "sets notes in the font and size given to new/1" do
      doc =
        Builder.new(footnotes: [font: :times, font_size: 8])
        |> Builder.paragraph([{"a", footnote: "Note."}])
        |> written()

      note = doc |> Document.chars!(0) |> Enum.find(&(&1.text == "N"))
      assert_in_delta note.font_size, 8, 0.001
      assert note.font =~ "Times"
    end

    test "chooses DejaVu Sans for :auto when only a note needs it" do
      doc = Builder.new() |> Builder.paragraph([{"a", footnote: "Примечание"}]) |> written()

      note = doc |> Document.chars!(0) |> Enum.find(&(&1.text == "П"))
      assert note.font =~ "DejaVu"
    end

    test "refuses a heading whose next line and its notes cannot share a page with it" do
      message =
        Builder.new()
        |> Builder.heading(1, "Heading", font_size: 12)
        |> Builder.paragraph([{"a", footnote: lines_of(42, "n")}])
        |> refusal()

      assert message =~ "op 0 on page 0"
      assert message =~ "it would be left alone"
    end

    test "keeps a heading with a list whose note falls on the item's second line" do
      item = [{String.duplicate("x", 62), footnote: lines_of(42, "n")}]

      doc =
        Builder.new(font: :courier)
        |> Builder.heading(1, "Heading", font_size: 12)
        |> Builder.bullet_list([item])
        |> written()

      page = Document.text!(doc, 0)
      assert page =~ "Heading"
      assert page =~ String.duplicate("x", 60)
      assert note_text(doc, 0) == ""
      assert note_text(doc, 1) =~ "1 n1"
      assert Document.text!(doc, 1) =~ "xx"
    end

    test "refuses a line whose notes cannot fit even on a page of their own" do
      tall = String.duplicate("x\n", 60)

      for builder <- [
            Builder.paragraph(Builder.new(), [{"a", footnote: tall}]),
            Builder.columns(Builder.new(), [[{"a", footnote: tall}]]),
            Builder.table(Builder.new(), [[[{"a", footnote: tall}]]])
          ] do
        message = refusal(builder)
        assert message =~ "footnotes it references need"
        assert message =~ "648-point content height"
      end
    end

    test "raises where a footnote cannot be set" do
      note = [{"a", footnote: "Note."}]

      for call <- [
            fn -> Builder.text_at(Builder.new(), {72, 72}, note) end,
            fn -> Builder.code_block(Builder.new(), note) end,
            fn -> Builder.header(Builder.new(), left: note) end
          ] do
        assert_raise ArgumentError, ~r/footnotes are set only in paragraphs/, call
      end

      assert_raise ArgumentError, ~r/a header row repeats on every page/, fn ->
        Builder.table(Builder.new(), [[note], ["b"]], header_rows: 1)
      end

      assert_raise ArgumentError, ~r/cannot have a footnote of its own/, fn ->
        Builder.paragraph(Builder.new(), [{"a", footnote: note}])
      end

      assert_raise ArgumentError, ~r/must end in a character other than whitespace/, fn ->
        Builder.paragraph(Builder.new(), [{"a ", footnote: "Note."}])
      end

      assert_raise ArgumentError, ~r/must end in a character other than whitespace/, fn ->
        Builder.paragraph(Builder.new(), ["a", {"", footnote: "Note."}])
      end

      assert_raise ArgumentError, ~r/a note needs text other than whitespace/, fn ->
        Builder.paragraph(Builder.new(), [{"a", footnote: " \n"}])
      end

      assert_raise ArgumentError, ~r/invalid :footnote, expected a string/, fn ->
        Builder.paragraph(Builder.new(), [{"a", footnote: untyped(3)}])
      end

      assert_raise ArgumentError, ~r/invalid :footnotes, expected a keyword list/, fn ->
        Builder.new(footnotes: untyped(:none))
      end
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
    test "code blocks" do
      assert_raise ArgumentError,
                   ~r/^invalid layout, a line 18.0 points tall .* with 320.0 points of padding above and below does not fit the 648.0-point content height/,
                   fn -> Builder.code_block(Builder.new(), "x", padding: 320) end

      assert_raise ArgumentError,
                   ~r/^invalid :padding, 234.0 points on each side leave no room for text/,
                   fn -> Builder.code_block(Builder.new(), "x", padding: 234) end

      assert_raise ArgumentError,
                   ~r/^invalid :tab_width, expected an integer from 1 to 64: 0/,
                   fn ->
                     Builder.code_block(Builder.new(), "x", tab_width: 0)
                   end

      assert_raise ArgumentError,
                   ~r/^invalid :tab_width, expected an integer from 1 to 64: 65/,
                   fn ->
                     Builder.code_block(Builder.new(), "x", tab_width: 65)
                   end

      assert_raise ArgumentError, ~r/^invalid :padding, expected a non-negative number/, fn ->
        Builder.code_block(Builder.new(), "x", padding: -1)
      end

      assert_raise ArgumentError, ~r/^invalid :font, expected one of/, fn ->
        Builder.code_block(Builder.new(), "x", font: :menlo)
      end

      assert_raise FunctionClauseError, fn -> Builder.code_block(Builder.new(), untyped(:x)) end
    end

    test "navigation" do
      assert_raise ArgumentError,
                   ~r/^invalid :level, a bookmark can be at most one level deeper .* it is the first bookmark: 2$/,
                   fn -> Builder.bookmark(Builder.new(), "T", level: 2) end

      assert_raise ArgumentError, ~r/^invalid level, .* the previous one is at 1: 3$/, fn ->
        Builder.new() |> Builder.bookmark("A") |> Builder.heading(3, "C", bookmark: true)
      end

      assert_raise ArgumentError, ~r/^invalid :level, expected an integer from 1 to 256/, fn ->
        Builder.bookmark(Builder.new(), "T", level: 0)
      end

      assert_raise ArgumentError, ~r/^invalid title, a bookmark needs a title/, fn ->
        Builder.bookmark(Builder.new(), "  ")
      end

      assert_raise ArgumentError, ~r/^invalid title, a bookmark title cannot hold/, fn ->
        Builder.bookmark(Builder.new(), "x\u0085y")
      end

      assert_raise ArgumentError, ~r/^invalid :to, expected/, fn ->
        Builder.bookmark(Builder.new(), "T", to: "https://example.com")
      end

      assert_raise ArgumentError, ~r/^invalid :bookmark, expected a boolean or a string/, fn ->
        Builder.heading(Builder.new(), 1, "T", bookmark: :yes)
      end

      assert_raise ArgumentError, ~r/^invalid style, expected one of/, fn ->
        Builder.page_labels(Builder.new(), untyped(:roman))
      end

      assert_raise ArgumentError, ~r/^invalid :start, Roman numerals stop at 3999/, fn ->
        Builder.page_labels(Builder.new(), :roman_upper, start: 4000)
      end

      assert_raise ArgumentError, ~r/^invalid :start, letters stop at 26000/, fn ->
        Builder.page_labels(Builder.new(), :alpha_lower, start: 26_001)
      end

      assert_raise ArgumentError, ~r/^invalid :start, expected an integer from 1/, fn ->
        Builder.page_labels(Builder.new(), :decimal, start: 0)
      end

      for prefix <- ["A\n", "A\r", "A\u2028"] do
        assert_raise ArgumentError, ~r/^invalid :prefix, a page label is one line/, fn ->
          Builder.page_labels(Builder.new(), :decimal, prefix: prefix)
        end
      end

      assert_raise ArgumentError, ~r/^invalid :prefix, a page label cannot hold/, fn ->
        Builder.page_labels(Builder.new(), :decimal, prefix: "Ã©")
      end

      assert_raise ArgumentError, ~r/^invalid header, expected at least one of :left/, fn ->
        Builder.header(Builder.new(), font_size: 9)
      end

      assert_raise ArgumentError, ~r/^invalid :left, a header or footer part is one line/, fn ->
        Builder.footer(Builder.new(), left: "a\nb")
      end

      assert_raise ArgumentError,
                   ~r/^invalid :font_size, a line 75.0 points tall .* the 72.0-point top margin/,
                   fn -> Builder.header(Builder.new(), left: "x", font_size: 50) end

      assert_raise ArgumentError, ~r/^invalid contents, a document can have only one/, fn ->
        Builder.new() |> Builder.contents() |> untyped() |> Builder.contents()
      end

      assert_raise FunctionClauseError, fn -> Builder.header(Builder.new(), untyped("x")) end
    end

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

      assert_raise ArgumentError, ~r/^invalid :page_size, expected sides of at most 1.0e18/, fn ->
        Builder.new(page_size: {1.0e19, 792})
      end

      assert_raise ArgumentError, ~r/^invalid :page_size, expected sides of at most 1.0e18/, fn ->
        Builder.page(Builder.new(), {612, 1.0e19})
      end

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

    test "links" do
      paragraph = &Builder.paragraph(Builder.new(), [{"x", link: &1}])
      rect = %Rect{x: 72.0, y: 72.0, width: 10.0, height: 10.0}

      assert_raise ArgumentError, ~r/^invalid :link, expected a URI of printable ASCII/, fn ->
        paragraph.("https://example.com/ж")
      end

      assert_raise ArgumentError, ~r/^invalid :link, expected a URI/, fn ->
        paragraph.("https://example.com/a b")
      end

      assert_raise ArgumentError,
                   ~r/^invalid :link, a javascript: URI is not run as a script; give the code as {:script, code}/,
                   fn ->
                     paragraph.("JavaScript:alert(1)")
                   end

      assert_raise ArgumentError,
                   ~r/^invalid :link, a vbscript: URI runs a script in a language/,
                   fn ->
                     paragraph.("VBScript:MsgBox(1)")
                   end

      assert_raise ArgumentError, ~r/^invalid :link, expected a URI string, {:page, index}/, fn ->
        paragraph.({:page, -1})
      end

      assert_raise ArgumentError, ~r/^invalid :link, an anchor name cannot be empty/, fn ->
        paragraph.({:anchor, ""})
      end

      assert_raise ArgumentError, ~r/^invalid run, a linked run needs text other than/, fn ->
        Builder.paragraph(Builder.new(), ["x", {" ", link: "https://example.com"}])
      end

      assert_raise ArgumentError, ~r/^invalid rect, it lies outside the 612.0 × 792.0 page/, fn ->
        Builder.link_in_rect(Builder.new(), %{rect | x: 612.0}, "https://example.com")
      end

      assert_raise FunctionClauseError, fn ->
        Builder.link_in_rect(Builder.new(), rect, untyped(nil))
      end
    end

    test "anchors" do
      assert_raise ArgumentError, ~r/^invalid name, an anchor named "a" already exists/, fn ->
        Builder.new() |> Builder.anchor("a") |> Builder.anchor("a")
      end

      assert_raise ArgumentError, ~r/^invalid name, an anchor name cannot be empty/, fn ->
        Builder.anchor(Builder.new(), "")
      end
    end

    test "watermarks" do
      watermark = &Builder.watermark(Builder.new(), &1, &2)

      for text <- ["", "   ", "Отчёт", "two\nlines"] do
        assert_raise ArgumentError, ~r/^invalid text, expected one line of printable ASCII/, fn ->
          watermark.(text, [])
        end
      end

      for opacity <- [0, 1.5, :half] do
        assert_raise ArgumentError, ~r/^invalid :opacity/, fn ->
          watermark.("DRAFT", opacity: opacity)
        end
      end

      assert_raise ArgumentError, ~r/^invalid :pages/, fn -> watermark.("DRAFT", pages: 1) end
      assert_raise ArgumentError, ~r/^invalid :font/, fn -> watermark.("DRAFT", font: :auto) end

      assert_raise ArgumentError, ~r/^invalid :color, a watermark needs one/, fn ->
        watermark.("DRAFT", color: nil)
      end

      for font_size <- [1.0e20, 1.0e38] do
        assert_raise ArgumentError, ~r/^invalid :font_size, .* too wide to place/, fn ->
          watermark.("W", font_size: font_size)
        end
      end

      assert_raise ArgumentError,
                   ~r/^invalid :center, expected coordinates of at most 1.0e18/,
                   fn ->
                     watermark.("DRAFT", center: {0, -1.0e19})
                   end
    end

    test "a form field" do
      rect = %Rect{x: 72, y: 600, width: 100, height: 20}
      text_field = &Builder.text_field(Builder.new(), &1, rect, &2)

      assert_raise ArgumentError, ~r/^invalid name, a form field's name cannot be empty/, fn ->
        text_field.("", [])
      end

      assert_raise ArgumentError, ~r/^invalid name, a "\." separates/, fn ->
        text_field.("address.city", [])
      end

      assert_raise ArgumentError, ~r/^invalid name, a form field named "a" already exists/, fn ->
        Builder.new() |> Builder.text_field("a", rect) |> Builder.check_box("a", rect)
      end

      for bad <- [
            %Rect{x: -1, y: 0, width: 10, height: 10},
            %Rect{x: 600, y: 0, width: 20, height: 10}
          ] do
        assert_raise ArgumentError,
                     ~r/^invalid rect, a form field must lie on the 612.0 × 792.0/,
                     fn ->
                       Builder.text_field(Builder.new(), "a", bad)
                     end
      end

      assert_raise ArgumentError, ~r/^invalid rect, expected a positive number/, fn ->
        Builder.text_field(Builder.new(), "a", %{rect | width: 0})
      end

      assert_raise ArgumentError, ~r/^invalid :value, .* "Ж" is not one/, fn ->
        text_field.("a", value: "Жанна")
      end

      assert_raise ArgumentError, ~r/^invalid :default_value, .* "\\n" is not one/, fn ->
        text_field.("a", default_value: "two\nlines")
      end

      assert_raise ArgumentError, ~r/^invalid :tooltip/, fn -> text_field.("a", tooltip: 1) end
      assert_raise ArgumentError, ~r/^invalid :required/, fn -> text_field.("a", required: 1) end

      assert_raise ArgumentError, ~r/^invalid :checked/, fn ->
        Builder.check_box(Builder.new(), "a", rect, checked: :yes)
      end

      for kind <- [&Builder.combo_box/5, &Builder.list_box/5] do
        assert_raise ArgumentError, ~r/^invalid options, a choice field needs at least one/, fn ->
          kind.(Builder.new(), "a", rect, [], [])
        end

        assert_raise ArgumentError, ~r/^invalid options, each option must be distinct/, fn ->
          kind.(Builder.new(), "a", rect, ["x", "x"], [])
        end

        assert_raise ArgumentError, ~r/^invalid options, .* "日" is not one/, fn ->
          kind.(Builder.new(), "a", rect, ["日本"], [])
        end

        assert_raise ArgumentError,
                     ~r/^invalid :selected, expected one of the field's options/,
                     fn ->
                       kind.(Builder.new(), "a", rect, ["x"], selected: "y")
                     end
      end

      list_box = &Builder.list_box(Builder.new(), "a", rect, ["x", "y"], &1)

      assert_raise ArgumentError,
                   ~r/^invalid :selected, a list .* needs multi_select: true/,
                   fn ->
                     list_box.(selected: ["x"])
                   end

      assert_raise ArgumentError, ~r/^invalid :selected, expected a list of options/, fn ->
        list_box.(multi_select: true, selected: "x")
      end

      assert_raise ArgumentError, ~r/^invalid :selected, expected a list of option strings/, fn ->
        list_box.(multi_select: true, selected: [nil])
      end

      assert_raise ArgumentError, ~r/^invalid :selected, each option can be selected once/, fn ->
        list_box.(multi_select: true, selected: ["x", "x"])
      end

      assert_raise ArgumentError, ~r/^invalid caption, .* "Ж" is not one/, fn ->
        Builder.push_button(Builder.new(), "a", rect, "Жми")
      end

      assert_raise ArgumentError, ~r/unknown keys \[:required\]/, fn ->
        Builder.push_button(Builder.new(), "a", rect, "Go", required: true)
      end

      assert_raise ArgumentError, ~r/unknown keys \[:required\]/, fn ->
        Builder.signature_field(Builder.new(), "a", rect, required: true)
      end

      assert_raise ArgumentError, ~r/unknown keys \[:selected\]/, fn ->
        Builder.check_box(Builder.new(), "a", rect, selected: true)
      end
    end

    test "text starting with a byte-order mark's characters" do
      rect = %Rect{x: 72, y: 600, width: 100, height: 20}

      for mark <- ["þÿ", "ÿþ", "ï»¿"], text = mark <> "abc" do
        calls = [
          fn -> Builder.new(title: text) end,
          fn -> Builder.new(creator: text) end,
          fn -> Builder.text_field(Builder.new(), text, rect) end,
          fn -> Builder.text_field(Builder.new(), "a", rect, value: text) end,
          fn -> Builder.text_field(Builder.new(), "a", rect, default_value: text) end,
          fn -> Builder.check_box(Builder.new(), "a", rect, tooltip: text) end,
          fn -> Builder.combo_box(Builder.new(), "a", rect, [text]) end,
          fn -> Builder.push_button(Builder.new(), "a", rect, text) end
        ]

        for call <- calls do
          assert_raise ArgumentError, ~r/is read back as a byte-order mark/, call
        end
      end
    end

    test "form field text a PDF reader would decode as other characters" do
      rect = %Rect{x: 72, y: 600, width: 100, height: 20}

      for text <- ["a\u00A0b", "s\u00ADh", "x\u0085y", "x\u0001y"] do
        calls = [
          fn -> Builder.text_field(Builder.new(), text, rect) end,
          fn -> Builder.check_box(Builder.new(), "a", rect, tooltip: text) end,
          fn -> Builder.signature_field(Builder.new(), "a", rect, tooltip: text) end,
          fn -> Builder.text_field(Builder.new(), "a", rect, value: text) end,
          fn -> Builder.text_field(Builder.new(), "a", rect, default_value: text) end,
          fn -> Builder.list_box(Builder.new(), "a", rect, [text]) end,
          fn -> Builder.push_button(Builder.new(), "a", rect, text) end
        ]

        for call <- calls do
          assert_raise ArgumentError, ~r/a form field cannot hold/, call
        end
      end

      assert %Builder{} = Builder.check_box(Builder.new(), "a", rect, tooltip: "tab\there")
    end

    test "form field text that would read back as other UTF-8 text" do
      rect = %Rect{x: 72, y: 600, width: 100, height: 20}
      message = ~r/a form field cannot hold .*: written one byte per character, it reads back as/

      calls = [
        fn -> Builder.combo_box(Builder.new(), "a", rect, ["Â£", "£"]) end,
        fn -> Builder.text_field(Builder.new(), "Ã©", rect) end,
        fn -> Builder.text_field(Builder.new(), "a", rect, value: "Ã©") end,
        fn -> Builder.check_box(Builder.new(), "a", rect, tooltip: "Ã©") end
      ]

      for call <- calls, do: assert_raise(ArgumentError, message, call)
    end

    test "a form field too narrow to survive its position's float precision" do
      builder = Builder.new(page_size: {2.0e9, 1000})

      assert_raise ArgumentError,
                   ~r/^invalid rect, its width or height is under 0.00001 points/,
                   fn ->
                     Builder.text_field(builder, "a", %Rect{
                       x: 999_999_900,
                       y: 100,
                       width: 20,
                       height: 20
                     })
                   end

      assert_raise ArgumentError,
                   ~r/^invalid rect, its width or height is under 0.00001 points/,
                   fn ->
                     Builder.check_box(builder, "a", %Rect{
                       x: 100,
                       y: 100,
                       width: 20,
                       height: 1.0e-6
                     })
                   end

      assert_raise ArgumentError, ~r/^invalid rect, .* under 0.00001 points/, fn ->
        Builder.text_field(Builder.new(), "a", %Rect{x: 0, y: 600, width: 0.000001, height: 20})
      end

      assert [%{rect: %Rect{width: 20.0}}] =
               builder
               |> Builder.text_field("a", %Rect{x: 30_000_000, y: 100, width: 20, height: 20})
               |> written()
               |> PdfElixide.Form.fields!()
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
