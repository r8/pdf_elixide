defmodule PdfElixide.DocumentTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Color
  alias PdfElixide.Document
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @tagged_pdf Path.join(@fixtures, "tagged.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")
  @image_jpeg_pdf Path.join(@fixtures, "image_jpeg.pdf")
  @password "secret"

  describe "page_count/1" do
    test "returns {:ok, 3} for the valid fixture" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 3} = Document.page_count(doc)
    end
  end

  describe "page_count!/1" do
    test "returns the integer page count for the valid fixture" do
      doc = Document.open!(@valid_pdf)
      assert Document.page_count!(doc) == 3
    end
  end

  describe "version/1" do
    test "returns the {major, minor} tuple for the valid fixture" do
      doc = Document.open!(@valid_pdf)
      assert Document.version(doc) == {1, 4}
    end
  end

  describe "text/1" do
    test "returns {:ok, text} containing every page's text" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, text} = Document.text(doc)
      assert text =~ "Page One"
      assert text =~ "Page Two"
      assert text =~ "Page Three"
    end

    test "separates pages with a form-feed character" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, text} = Document.text(doc)
      assert text =~ "\f"
    end
  end

  describe "text!/1" do
    test "returns the combined text of the whole document" do
      doc = Document.open!(@valid_pdf)
      text = Document.text!(doc)
      assert text =~ "Page One"
      assert text =~ "Page Three"
    end
  end

  describe "text/2" do
    test "returns {:ok, text} containing the page's text for each page" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, p0} = Document.text(doc, 0)
      assert {:ok, p1} = Document.text(doc, 1)
      assert {:ok, p2} = Document.text(doc, 2)
      assert p0 =~ "Page One"
      assert p1 =~ "Page Two"
      assert p2 =~ "Page Three"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.text(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text(doc, -1) end
    end
  end

  describe "text!/2" do
    test "returns the text for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert Document.text!(doc, 1) =~ "Page Two"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.text!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text!(doc, :first) end
    end
  end

  describe "words/1" do
    test "returns {:ok, words} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, words} = Document.words(doc)
      assert Enum.all?(words, &match?(%Word{}, &1))

      text = Enum.map_join(words, " ", & &1.text)
      assert text =~ "Page One"
      assert text =~ "Page Two"
      assert text =~ "Page Three"
    end

    test "length equals the sum of the per-page word counts" do
      doc = Document.open!(@valid_pdf)
      {:ok, all} = Document.words(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.words(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each word carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, words} = Document.words(doc)
      assert Enum.map(words, & &1.page) == [0, 0, 1, 1, 2, 2]
    end
  end

  describe "words!/1" do
    test "returns the flat word list of the whole document" do
      doc = Document.open!(@valid_pdf)
      words = Document.words!(doc)
      assert Enum.all?(words, &match?(%Word{}, &1))
      assert Enum.any?(words, &(&1.text == "One"))
      assert Enum.any?(words, &(&1.text == "Three"))
    end
  end

  describe "words/2" do
    test "returns {:ok, words} carrying text, bbox and font metadata" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%Word{} = word | _]} = Document.words(doc, 0)

      assert word.text == "Page"
      assert word.page == 0
      assert %Rect{} = word.bbox
      assert word.bbox.width > 0
      assert word.bbox.height > 0
      assert is_float(word.font_size)
      assert is_binary(word.font)
      assert is_boolean(word.bold?)
      assert is_boolean(word.italic?)
    end

    test "returns each page's words" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, w0} = Document.words(doc, 0)
      assert {:ok, w1} = Document.words(doc, 1)
      assert Enum.map(w0, & &1.text) == ["Page", "One"]
      assert Enum.map(w1, & &1.text) == ["Page", "Two"]
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.words(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.words(doc, -1) end
    end
  end

  describe "Word inspect/1" do
    test "renders the text, page, and bounding-box origin" do
      doc = Document.open!(@valid_pdf)
      [word | _] = Document.words!(doc, 0)
      assert inspect(word) == ~s(#PdfElixide.Document.Word<"Page" @ p0 72.0,720.0>)
    end
  end

  describe "words!/2" do
    test "returns the words for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%Word{text: "Page"}, %Word{text: "One"}] = Document.words!(doc, 0)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.words!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.words!(doc, :first) end
    end
  end

  describe "text_lines/1" do
    test "returns {:ok, lines} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, lines} = Document.text_lines(doc)
      assert Enum.all?(lines, &match?(%TextLine{}, &1))
      assert Enum.map(lines, & &1.text) == ["Page One", "Page Two", "Page Three"]
    end

    test "each line carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, lines} = Document.text_lines(doc)
      assert Enum.map(lines, & &1.page) == [0, 1, 2]
    end
  end

  describe "text_lines!/1" do
    test "returns the flat line list of the whole document" do
      doc = Document.open!(@valid_pdf)
      lines = Document.text_lines!(doc)
      assert Enum.all?(lines, &match?(%TextLine{}, &1))
      assert Enum.any?(lines, &(&1.text == "Page Three"))
    end
  end

  describe "text_lines/2" do
    test "returns {:ok, lines} carrying text, page, bbox and nested words" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%TextLine{} = line]} = Document.text_lines(doc, 0)

      assert line.text == "Page One"
      assert line.page == 0
      assert %Rect{} = line.bbox
      assert line.bbox.width > 0
      assert line.bbox.height > 0
      assert [%Word{text: "Page"}, %Word{text: "One"}] = line.words
      assert Enum.all?(line.words, &(&1.page == 0))
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.text_lines(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text_lines(doc, -1) end
    end
  end

  describe "text_lines!/2" do
    test "returns the lines for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%TextLine{text: "Page Two"}] = Document.text_lines!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.text_lines!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.text_lines!(doc, :first) end
    end
  end

  describe "TextLine inspect/1" do
    test "renders the text, page, and word count" do
      doc = Document.open!(@valid_pdf)
      [line] = Document.text_lines!(doc, 0)
      assert inspect(line) == ~s|#PdfElixide.Document.TextLine<"Page One" @ p0 (2 words)>|
    end
  end

  describe "chars/1" do
    test "returns {:ok, chars} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, chars} = Document.chars(doc)
      assert Enum.all?(chars, &match?(%Char{}, &1))

      text = Enum.map_join(chars, & &1.text)
      assert text =~ "Page One"
      assert text =~ "Page Two"
      assert text =~ "Page Three"
    end

    test "length equals the sum of the per-page char counts" do
      doc = Document.open!(@valid_pdf)
      {:ok, all} = Document.chars(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.chars(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each char carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, chars} = Document.chars(doc)
      assert chars |> Enum.map(& &1.page) |> Enum.uniq() == [0, 1, 2]
    end
  end

  describe "chars!/1" do
    test "returns the flat char list of the whole document" do
      doc = Document.open!(@valid_pdf)
      chars = Document.chars!(doc)
      assert Enum.all?(chars, &match?(%Char{}, &1))
      assert Enum.all?(chars, &(String.length(&1.text) == 1))
    end
  end

  describe "chars/2" do
    test "returns {:ok, chars} carrying text, bbox, font and typographic metadata" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%Char{} = char | _]} = Document.chars(doc, 0)

      assert char.text == "P"
      assert char.page == 0
      assert %Rect{} = char.bbox
      assert char.bbox.width > 0
      assert char.bbox.height > 0
      assert is_float(char.font_size)
      assert is_binary(char.font)
      assert is_integer(char.font_weight)
      assert is_boolean(char.bold?)
      assert is_boolean(char.italic?)
      assert is_boolean(char.monospace?)
      assert %Color{r: r, g: g, b: b} = char.color
      assert Enum.all?([r, g, b], &is_float/1)
      assert {origin_x, origin_y} = char.origin
      assert is_float(origin_x) and is_float(origin_y)
      assert is_float(char.rotation)
      assert char.advance_width > 0
      assert char.rendered_advance > 0
      assert char.ascent > 0
      assert char.descent < 0
      assert is_nil(char.mcid)
    end

    test "returns each page's chars in reading order" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, c0} = Document.chars(doc, 0)
      assert {:ok, c1} = Document.chars(doc, 1)
      assert Enum.map_join(c0, & &1.text) == "Page One"
      assert Enum.map_join(c1, & &1.text) == "Page Two"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.chars(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.chars(doc, -1) end
    end
  end

  describe "chars!/2" do
    test "returns the chars for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%Char{text: "P"} | _] = Document.chars!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.chars!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.chars!(doc, :first) end
    end
  end

  describe "Char inspect/1" do
    test "renders the text, page, and baseline origin" do
      doc = Document.open!(@valid_pdf)
      [char | _] = Document.chars!(doc, 0)
      assert inspect(char) == ~s(#PdfElixide.Document.Char<"P" @ p0 72.0,720.0>)
    end
  end

  describe "spans/1" do
    test "returns {:ok, spans} for every page as a flat list" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, spans} = Document.spans(doc)
      assert Enum.all?(spans, &match?(%Span{}, &1))
      assert Enum.map(spans, & &1.text) == ["Page One", "Page Two", "Page Three"]
    end

    test "length equals the sum of the per-page span counts" do
      doc = Document.open!(@valid_pdf)
      {:ok, all} = Document.spans(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.spans(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each span carries its zero-based page index" do
      doc = Document.open!(@valid_pdf)
      {:ok, spans} = Document.spans(doc)
      assert spans |> Enum.map(& &1.page) |> Enum.uniq() == [0, 1, 2]
    end
  end

  describe "spans!/1" do
    test "returns the flat span list of the whole document" do
      doc = Document.open!(@valid_pdf)
      spans = Document.spans!(doc)
      assert Enum.all?(spans, &match?(%Span{}, &1))
      assert Enum.any?(spans, &(&1.text == "Page Three"))
    end
  end

  describe "spans/2" do
    test "returns {:ok, spans} carrying text, bbox, font and text-state metadata" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, [%Span{} = span | _]} = Document.spans(doc, 0)

      assert span.text == "Page One"
      assert span.page == 0
      assert %Rect{} = span.bbox
      assert span.bbox.width > 0
      assert span.bbox.height > 0
      assert is_float(span.font_size)
      assert is_binary(span.font)
      assert is_integer(span.font_weight)
      assert is_boolean(span.bold?)
      assert is_boolean(span.italic?)
      assert is_boolean(span.monospace?)
      assert %Color{r: r, g: g, b: b} = span.color
      assert Enum.all?([r, g, b], &is_float/1)
      assert is_float(span.rotation)
      assert is_float(span.char_spacing)
      assert is_float(span.word_spacing)
      assert span.horizontal_scaling == 100.0
      assert is_float(span.text_rise)
      assert is_nil(span.heading_level)
      assert is_nil(span.mcid)
    end

    test "returns each page's spans" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, s0} = Document.spans(doc, 0)
      assert {:ok, s1} = Document.spans(doc, 1)
      assert Enum.map(s0, & &1.text) == ["Page One"]
      assert Enum.map(s1, & &1.text) == ["Page Two"]
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.spans(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.spans(doc, -1) end
    end
  end

  describe "spans!/2" do
    test "returns the spans for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert [%Span{text: "Page Two"}] = Document.spans!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.spans!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.spans!(doc, :first) end
    end
  end

  describe "Span inspect/1" do
    test "renders the text, page, and bounding-box origin" do
      doc = Document.open!(@valid_pdf)
      [span | _] = Document.spans!(doc, 0)
      assert inspect(span) == ~s(#PdfElixide.Document.Span<"Page One" @ p0 72.0,720.0>)
    end
  end

  describe "paths/1" do
    test "returns {:ok, paths} for every page as a flat list of structs" do
      doc = Document.open!(@table_pdf)
      assert {:ok, paths} = Document.paths(doc)
      assert paths != []
      assert Enum.all?(paths, &match?(%Document.Path{}, &1))
    end

    test "length equals the sum of the per-page path counts" do
      doc = Document.open!(@table_pdf)
      {:ok, all} = Document.paths(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.paths(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each path carries its zero-based page index" do
      doc = Document.open!(@table_pdf)
      {:ok, paths} = Document.paths(doc)
      assert Enum.all?(paths, &(&1.page == 0))
    end
  end

  describe "paths!/1" do
    test "returns the flat path list of the whole document" do
      doc = Document.open!(@table_pdf)
      paths = Document.paths!(doc)
      assert Enum.all?(paths, &match?(%Document.Path{}, &1))
    end
  end

  describe "paths/2" do
    test "returns {:ok, paths} carrying operations, bbox, colors and stroke style" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Document.Path{} = path | _]} = Document.paths(doc, 0)

      assert path.page == 0
      assert %Rect{} = path.bbox
      assert [{:move_to, mx, my} | _] = path.operations
      assert is_float(mx) and is_float(my)
      assert Enum.any?(path.operations, &match?({:line_to, _, _}, &1))
      assert %Color{r: r, g: g, b: b} = path.stroke_color
      assert Enum.all?([r, g, b], &is_float/1)
      assert is_nil(path.fill_color) or match?(%Color{}, path.fill_color)
      assert is_float(path.stroke_width)
      assert path.line_cap in [:butt, :round, :square]
      assert path.line_join in [:miter, :round, :bevel]
      assert is_nil(path.dash_pattern) or match?({_, _}, path.dash_pattern)
      assert is_nil(path.layer) or is_binary(path.layer)
    end

    test "returns {:ok, []} for a page with no vector graphics" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.paths(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.paths(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.paths(doc, -1) end
    end
  end

  describe "paths!/2" do
    test "returns the paths for a valid page" do
      doc = Document.open!(@table_pdf)
      assert [%Document.Path{} | _] = Document.paths!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.paths!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.paths!(doc, :first) end
    end
  end

  describe "Path inspect/1" do
    test "renders the page index and operation count" do
      doc = Document.open!(@table_pdf)
      [path | _] = Document.paths!(doc, 0)
      assert inspect(path) == "#PdfElixide.Document.Path<p0 2 ops>"
    end
  end

  describe "images/1" do
    test "returns {:ok, images} for every page as a flat list of structs" do
      doc = Document.open!(@image_pdf)
      assert {:ok, images} = Document.images(doc)
      assert images != []
      assert Enum.all?(images, &match?(%Document.Image{}, &1))
    end

    test "length equals the sum of the per-page image counts" do
      doc = Document.open!(@image_pdf)
      {:ok, all} = Document.images(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.images(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "each image carries its zero-based page index" do
      doc = Document.open!(@image_pdf)
      {:ok, images} = Document.images(doc)
      assert Enum.all?(images, &(&1.page == 0))
    end
  end

  describe "images!/1" do
    test "returns the flat image list of the whole document" do
      doc = Document.open!(@image_pdf)
      images = Document.images!(doc)
      assert Enum.all?(images, &match?(%Document.Image{}, &1))
    end
  end

  describe "images/2" do
    test "returns {:ok, images} carrying a handle, source format, dimensions and metadata" do
      doc = Document.open!(@image_pdf)
      assert {:ok, [%Document.Image{} = image | _]} = Document.images(doc, 0)

      assert image.page == 0
      assert image.format in [:jpeg, :raw]
      assert is_reference(image.ref)
      assert image.width > 0
      assert image.height > 0
      assert is_nil(image.bbox) or match?(%Rect{}, image.bbox)
      assert is_atom(image.color_space)
      assert is_integer(image.bits_per_component)
      assert is_integer(image.rotation_degrees)
    end

    test "reports :jpeg source format for a JPEG-stored image" do
      doc = Document.open!(@image_jpeg_pdf)
      assert {:ok, [%Document.Image{format: :jpeg} | _]} = Document.images(doc, 0)
    end

    test "returns {:ok, []} for a page with no images" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.images(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.images(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.images(doc, -1) end
    end
  end

  describe "images!/2" do
    test "returns the images for a valid page" do
      doc = Document.open!(@image_pdf)
      assert [%Document.Image{} | _] = Document.images!(doc, 0)
    end

    test "raises Error for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.images!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.images!(doc, :first) end
    end
  end

  describe "Image.to_binary/2" do
    test "defaults to PNG bytes" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)

      assert {:ok, <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>} =
               Document.Image.to_binary(image)
    end

    test "encodes JPEG bytes when format: :jpeg" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert {:ok, <<255, 216, 255, _::binary>>} = Document.Image.to_binary(image, format: :jpeg)
    end

    test "passes the original bytes through for a JPEG-stored image" do
      [image | _] = Document.open!(@image_jpeg_pdf) |> Document.images!(0)
      assert image.format == :jpeg
      assert {:ok, <<255, 216, 255, _::binary>>} = Document.Image.to_binary(image, format: :jpeg)
    end

    test "raises ArgumentError for an unsupported format" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert_raise ArgumentError, fn -> Document.Image.to_binary(image, format: :gif) end
    end

    test "to_binary!/2 returns the bytes directly" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert <<137, 80, 78, 71, _::binary>> = Document.Image.to_binary!(image)
    end
  end

  describe "Image.data/1" do
    test "returns the original JPEG blob for a JPEG-stored image" do
      [image | _] = Document.open!(@image_jpeg_pdf) |> Document.images!(0)
      assert image.format == :jpeg
      assert {:ok, {:jpeg, <<255, 216, 255, _::binary>>}} = Document.Image.data(image)
    end

    test "returns raw pixels with their layout for a raw-stored image" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      assert image.format == :raw
      assert {:ok, {:raw, pixels, pixel_format}} = Document.Image.data(image)
      assert pixel_format in [:rgb, :grayscale, :cmyk]
      assert is_binary(pixels)
      # DeviceRGB fixture: one byte per component, three components per pixel.
      assert pixel_format == :rgb
      assert byte_size(pixels) == image.width * image.height * 3
    end

    test "data!/1 returns the raw data directly" do
      [image | _] = Document.open!(@image_jpeg_pdf) |> Document.images!(0)
      assert {:jpeg, <<255, 216, 255, _::binary>>} = Document.Image.data!(image)
    end
  end

  describe "Image.save/3" do
    @describetag :tmp_dir

    test "infers PNG from a .png path", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "out.png")
      assert :ok = Document.Image.save(image, path)
      assert <<137, 80, 78, 71, _::binary>> = File.read!(path)
    end

    test "infers JPEG from a .jpg path", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "out.jpg")
      assert :ok = Document.Image.save(image, path)
      assert <<255, 216, 255, _::binary>> = File.read!(path)
    end

    test "the :format option overrides the extension", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "thumb.bin")
      assert :ok = Document.Image.save(image, path, format: :jpeg)
      assert <<255, 216, 255, _::binary>> = File.read!(path)
    end

    test "raises ArgumentError for an unknown extension with no :format", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "out.bmp")
      assert_raise ArgumentError, fn -> Document.Image.save(image, path) end
    end

    test "save!/3 returns :ok", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, "bang.png")
      assert :ok = Document.Image.save!(image, path)
      assert File.exists?(path)
    end
  end

  describe "Image inspect/1" do
    test "renders the page index, dimensions and source format" do
      doc = Document.open!(@image_pdf)
      [image | _] = Document.images!(doc, 0)

      assert inspect(image) ==
               "#PdfElixide.Document.Image<p0 #{image.width}x#{image.height} #{image.format}>"
    end
  end

  describe "tables/2" do
    test "returns {:ok, tables} carrying geometry, grid shape and rows" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Table{} = table]} = Document.tables(doc, 0)

      assert table.page == 0
      assert table.col_count == 4
      assert length(table.rows) == 5
      assert table.real_grid?
      assert is_boolean(table.has_header?)
      assert %Rect{} = table.bbox
      assert table.bbox.width > 0
      assert table.bbox.height > 0
    end

    test "keeps each row's cells aligned with their values" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)

      grid = Enum.map(table.rows, fn row -> Enum.map(row.cells, & &1.text) end)

      assert ["Age", "0.042", "0.011", "0.001"] in grid
      assert ["Diabetes", "0.694", "0.233", "0.003"] in grid
    end

    test "cells carry their geometry, spans and grid placement" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      [%Table.Row{} = row | _] = table.rows
      [%Table.Cell{} = cell | _] = row.cells

      assert cell.text == "Age"
      assert cell.colspan == 1
      assert cell.rowspan == 1
      assert is_boolean(cell.header?)
      assert cell.mcids == []
      assert %Rect{} = cell.bbox
      assert [%Span{text: "Age", page: 0}] = cell.spans
    end

    test "returns {:ok, []} for a page with no table" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.tables(doc, 0)
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@table_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.tables(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@table_pdf)
      assert_raise FunctionClauseError, fn -> Document.tables(doc, -1) end
    end
  end

  describe "tables/1" do
    test "returns {:ok, tables} for every page as a flat list" do
      doc = Document.open!(@table_pdf)
      assert {:ok, [%Table{page: 0}]} = Document.tables(doc)
    end

    test "length equals the sum of the per-page table counts" do
      doc = Document.open!(@table_pdf)
      {:ok, all} = Document.tables(doc)

      per_page_total =
        0..(Document.page_count!(doc) - 1)//1
        |> Enum.map(fn i -> length(elem(Document.tables(doc, i), 1)) end)
        |> Enum.sum()

      assert length(all) == per_page_total
    end

    test "returns an empty list for a document with no tables" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Document.tables(doc)
    end
  end

  describe "tables!/1" do
    test "returns the flat table list of the whole document" do
      doc = Document.open!(@table_pdf)
      assert [%Table{col_count: 4}] = Document.tables!(doc)
    end
  end

  describe "tables!/2" do
    test "returns the tables for a valid page" do
      doc = Document.open!(@table_pdf)
      assert [%Table{page: 0}] = Document.tables!(doc, 0)
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Document.tables!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@table_pdf)
      assert_raise FunctionClauseError, fn -> Document.tables!(doc, :first) end
    end
  end

  describe "Table inspect/1" do
    test "renders the page and grid shape" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      assert inspect(table) == "#PdfElixide.Document.Table<p0 5x4>"
    end

    test "marks a table with an explicit header section" do
      table = %Table{
        page: 2,
        bbox: nil,
        col_count: 3,
        has_header?: true,
        real_grid?: true,
        rows: []
      }

      assert inspect(table) == "#PdfElixide.Document.Table<p2 0x3 (header)>"
    end

    test "renders the cell count of a row and the text of a cell" do
      doc = Document.open!(@table_pdf)
      [table] = Document.tables!(doc, 0)
      [row | _] = table.rows
      [cell | _] = row.cells

      assert inspect(row) == "#PdfElixide.Document.Table.Row<4 cells>"
      assert inspect(cell) == ~s(#PdfElixide.Document.Table.Cell<"Age">)
    end
  end

  describe "pages/1" do
    test "returns a lazy handle for every page" do
      doc = Document.open!(@valid_pdf)

      assert [%Page{doc: ^doc, index: 0}, %Page{doc: ^doc, index: 1}, %Page{doc: ^doc, index: 2}] =
               Document.pages(doc)
    end
  end

  describe "Enumerable" do
    test "Enum.count/1 returns the page count" do
      doc = Document.open!(@valid_pdf)
      assert Enum.count(doc) == 3
    end

    test "Enum.at/2 returns the page at a zero-based index" do
      doc = Document.open!(@valid_pdf)
      assert %Page{doc: ^doc, index: 0} = Enum.at(doc, 0)
    end

    test "Enum.at/2 supports negative indexing" do
      doc = Document.open!(@valid_pdf)
      assert %Page{doc: ^doc, index: 2} = Enum.at(doc, -1)
    end

    test "Enum.at/2 returns nil for an out-of-range index" do
      doc = Document.open!(@valid_pdf)
      assert Enum.at(doc, 99) == nil
    end

    test "Enum.to_list/1 matches pages/1" do
      doc = Document.open!(@valid_pdf)
      assert Enum.to_list(doc) == Document.pages(doc)
    end

    test "is iterable page by page" do
      doc = Document.open!(@valid_pdf)
      assert Enum.map(doc, & &1.index) == [0, 1, 2]
    end

    test "Enum.slice/2 returns the requested pages" do
      doc = Document.open!(@valid_pdf)
      assert [%Page{index: 1}, %Page{index: 2}] = Enum.slice(doc, 1..2)
    end

    test "membership is true for an in-range page of the same document" do
      doc = Document.open!(@valid_pdf)
      assert Enum.member?(doc, %Page{doc: doc, index: 2})
    end

    test "membership is false for an out-of-range page or a foreign page" do
      doc = Document.open!(@valid_pdf)
      other = Document.open!(@valid_pdf)
      refute Enum.member?(doc, %Page{doc: doc, index: 99})
      refute Enum.member?(doc, %Page{doc: other, index: 0})
      refute Enum.member?(doc, :not_a_page)
    end
  end

  describe "page/2" do
    test "returns {:ok, page} for a valid index" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, %Page{doc: ^doc, index: 1}} = Document.page(doc, 1)
    end

    test "returns {:error, reason} for an out-of-range index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.page(doc, 99)
    end

    test "raises FunctionClauseError for negative index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.page(doc, -1) end
    end
  end

  describe "page!/2" do
    test "returns the page for a valid index" do
      doc = Document.open!(@valid_pdf)
      assert %Page{doc: ^doc, index: 1} = Document.page!(doc, 1)
    end

    test "raises RuntimeError for an out-of-range index" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Document.page!(doc, 99) end
    end
  end

  describe "encrypted?/1" do
    test "returns false for an unencrypted PDF" do
      doc = Document.open!(@valid_pdf)
      refute Document.encrypted?(doc)
    end

    test "returns true for an encrypted PDF" do
      doc = Document.open!(@encrypted_pdf)
      assert Document.encrypted?(doc)
    end
  end

  describe "has_structure_tree?/1" do
    test "returns false for the untagged sample fixture" do
      doc = Document.open!(@valid_pdf)
      refute Document.has_structure_tree?(doc)
    end

    test "returns true for a tagged PDF" do
      doc = Document.open!(@tagged_pdf)
      assert Document.has_structure_tree?(doc)
    end
  end

  describe "authenticate/2" do
    test "returns {:ok, true} for an unencrypted PDF" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, true} = Document.authenticate(doc, "anything")
    end

    test "returns {:ok, true} with the correct password" do
      doc = Document.open!(@encrypted_pdf)
      assert {:ok, true} = Document.authenticate(doc, @password)
    end

    test "returns {:ok, false} with the wrong password" do
      doc = Document.open!(@encrypted_pdf)
      assert {:ok, false} = Document.authenticate(doc, "wrong")
    end

    test "raises FunctionClauseError for a non-binary password" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.authenticate(doc, :secret) end
    end
  end

  describe "authenticate!/2" do
    test "returns true with the correct password" do
      doc = Document.open!(@encrypted_pdf)
      assert Document.authenticate!(doc, @password) == true
    end

    test "returns false (does not raise) with the wrong password" do
      doc = Document.open!(@encrypted_pdf)
      assert Document.authenticate!(doc, "wrong") == false
    end
  end

  describe "open/2 with password option" do
    test "opens an encrypted PDF with the correct password" do
      assert {:ok, %Document{}} = Document.open(@encrypted_pdf, password: @password)
    end

    test "returns {:error, _} with the wrong password" do
      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@encrypted_pdf, password: "wrong")
    end

    test "password: nil is a no-op (unencrypted PDF opens normally)" do
      assert {:ok, %Document{}} = Document.open(@valid_pdf, password: nil)
    end

    test "extracts text after open-with-password" do
      doc = Document.open!(@encrypted_pdf, password: @password)
      assert Document.text!(doc, 0) =~ "Page One"
    end
  end

  describe "from_binary/2 with password option" do
    test "opens an encrypted PDF binary with the correct password" do
      bytes = File.read!(@encrypted_pdf)
      assert {:ok, %Document{}} = Document.from_binary(bytes, password: @password)
    end

    test "returns {:error, _} with the wrong password" do
      bytes = File.read!(@encrypted_pdf)

      assert {:error, %Error{reason: :wrong_password}} =
               Document.from_binary(bytes, password: "wrong")
    end
  end

  describe "open!/2 and from_binary!/2 bang variants" do
    test "open! raises with the wrong-password message" do
      assert_raise Error, "Authentication failed: wrong password", fn ->
        Document.open!(@encrypted_pdf, password: "wrong")
      end
    end

    test "from_binary! raises with the wrong-password message" do
      bytes = File.read!(@encrypted_pdf)

      assert_raise Error, "Authentication failed: wrong password", fn ->
        Document.from_binary!(bytes, password: "wrong")
      end
    end
  end

  describe "structured error reasons" do
    test "wrong password carries reason :wrong_password" do
      assert {:error, %Error{reason: :wrong_password, message: message}} =
               Document.open(@encrypted_pdf, password: "wrong")

      assert is_binary(message)
    end

    test "invalid PDF bytes carry reason :invalid_pdf" do
      assert {:error, %Error{reason: :invalid_pdf}} = Document.from_binary("not a pdf")
    end

    test "an out-of-range page index carries reason :out_of_range" do
      doc = Document.open!(@valid_pdf)
      assert {:error, %Error{reason: :out_of_range}} = Document.text(doc, 99)
    end

    test "bang variants raise PdfElixide.Error with the reason preserved" do
      doc = Document.open!(@valid_pdf)

      error =
        assert_raise Error, fn -> Document.text!(doc, 99) end

      assert error.reason == :out_of_range
    end
  end
end
