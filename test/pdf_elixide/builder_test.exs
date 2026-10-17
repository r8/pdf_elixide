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
  end

  describe "page/2" do
    test "the first content starts a page, so a leading page/2 adds no blank one" do
      doc = Builder.new() |> Builder.page(:a4) |> Builder.paragraph("A4") |> written()

      assert Document.page_count!(doc) == 1
      assert %{width: 595.0, height: 842.0} = Page.media_box!(Document.page!(doc, 0))
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
