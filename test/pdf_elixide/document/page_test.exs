defmodule PdfElixide.Document.PageTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Error

  @fixtures Path.join([__DIR__, "..", "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")
  @fonts_pdf Path.join(@fixtures, "fonts.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @metadata_pdf Path.join(@fixtures, "metadata.pdf")

  describe "inspect/1" do
    test "renders the page index" do
      doc = Document.open!(@valid_pdf)
      assert inspect(Document.page!(doc, 2)) == "#PdfElixide.Document.Page<2>"
    end
  end

  describe "width/1" do
    test "returns the page width in points" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 612.0} = Page.width(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.width(%Page{doc: doc, index: 99})
    end
  end

  describe "width!/1" do
    test "returns the width directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.width!(Document.page!(doc, 0)) == 612.0
    end
  end

  describe "height/1" do
    test "returns the page height in points" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, 792.0} = Page.height(Document.page!(doc, 0))
    end
  end

  describe "height!/1" do
    test "returns the height directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.height!(Document.page!(doc, 0)) == 792.0
    end
  end

  describe "text/1" do
    test "returns {:ok, text} for the page's content" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, text} = Page.text(Document.page!(doc, 1))
      assert text =~ "Page Two"
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.text(%Page{doc: doc, index: 99})
    end
  end

  describe "text!/1" do
    test "returns the text directly" do
      doc = Document.open!(@valid_pdf)
      assert Page.text!(Document.page!(doc, 0)) =~ "Page One"
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.text!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "words/1" do
    test "delegates to Document.words/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.words(page) == Document.words(doc, 1)
      assert {:ok, [%Word{text: "Page", page: 1}, %Word{text: "Two", page: 1}]} = Page.words(page)
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.words(%Page{doc: doc, index: 99})
    end
  end

  describe "words!/1" do
    test "returns the words directly" do
      doc = Document.open!(@valid_pdf)
      assert [%Word{text: "Page"}, %Word{text: "One"}] = Page.words!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.words!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "chars/1" do
    test "delegates to Document.chars/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.chars(page) == Document.chars(doc, 1)
      assert {:ok, chars} = Page.chars(page)
      assert Enum.map_join(chars, & &1.text) == "Page Two"
      assert Enum.all?(chars, &(&1.page == 1))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.chars(%Page{doc: doc, index: 99})
    end
  end

  describe "chars!/1" do
    test "returns the chars directly" do
      doc = Document.open!(@valid_pdf)
      assert [%Char{text: "P", page: 0} | _] = Page.chars!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.chars!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "spans/1" do
    test "delegates to Document.spans/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.spans(page) == Document.spans(doc, 1)
      assert {:ok, [%Span{text: "Page Two", page: 1}]} = Page.spans(page)
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.spans(%Page{doc: doc, index: 99})
    end
  end

  describe "spans!/1" do
    test "returns the spans directly" do
      doc = Document.open!(@valid_pdf)
      assert [%Span{text: "Page One", page: 0}] = Page.spans!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.spans!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "paths/1" do
    test "delegates to Document.paths/2 for the page" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      assert Page.paths(page) == Document.paths(doc, 0)
      assert {:ok, [%Document.Path{page: 0} | _]} = Page.paths(page)
    end

    test "returns {:ok, []} for a page with no vector graphics" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.paths(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert {:error, _reason} = Page.paths(%Page{doc: doc, index: 99})
    end
  end

  describe "paths!/1" do
    test "returns the paths directly" do
      doc = Document.open!(@table_pdf)
      assert [%Document.Path{page: 0} | _] = Page.paths!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Page.paths!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "images/1" do
    test "delegates to Document.images/2 for the page" do
      doc = Document.open!(@image_pdf)
      page = Document.page!(doc, 0)
      # Each extraction yields fresh image handles, so compare stable metadata
      # rather than the structs (whose :ref differ) directly.
      {:ok, via_page} = Page.images(page)
      {:ok, via_doc} = Document.images(doc, 0)
      assert Enum.map(via_page, & &1.page) == Enum.map(via_doc, & &1.page)
      assert length(via_page) == length(via_doc)
      assert {:ok, [%Document.Image{page: 0} | _]} = Page.images(page)
    end

    test "returns {:ok, []} for a page with no images" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.images(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@image_pdf)
      assert {:error, _reason} = Page.images(%Page{doc: doc, index: 99})
    end
  end

  describe "images!/1" do
    test "returns the images directly" do
      doc = Document.open!(@image_pdf)
      assert [%Document.Image{page: 0} | _] = Page.images!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@image_pdf)
      assert_raise Error, fn -> Page.images!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "fonts/1" do
    test "delegates to Document.fonts/2 for the page" do
      doc = Document.open!(@fonts_pdf)
      page = Document.page!(doc, 0)
      # Each extraction yields fresh font handles, so compare stable metadata
      # rather than the structs (whose :ref differ) directly.
      {:ok, via_page} = Page.fonts(page)
      {:ok, via_doc} = Document.fonts(doc, 0)
      assert Enum.map(via_page, & &1.base_font) == Enum.map(via_doc, & &1.base_font)
      assert length(via_page) == length(via_doc)
      assert {:ok, [%Document.Font{page: 0} | _]} = Page.fonts(page)
    end

    test "returns {:ok, []} for a page that references no fonts" do
      doc = Document.open!(@form_pdf)
      assert {:ok, []} = Page.fonts(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@fonts_pdf)
      assert {:error, _reason} = Page.fonts(%Page{doc: doc, index: 99})
    end
  end

  describe "fonts!/1" do
    test "returns the fonts directly" do
      doc = Document.open!(@fonts_pdf)
      assert [%Document.Font{page: 0} | _] = Page.fonts!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@fonts_pdf)
      assert_raise Error, fn -> Page.fonts!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "tables/1" do
    test "delegates to Document.tables/2 for the page" do
      doc = Document.open!(@table_pdf)
      page = Document.page!(doc, 0)
      assert Page.tables(page) == Document.tables(doc, 0)
      assert {:ok, [%Table{page: 0, col_count: 4}]} = Page.tables(page)
    end

    test "returns {:ok, []} for a page with no table" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, []} = Page.tables(Document.page!(doc, 0))
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert {:error, _reason} = Page.tables(%Page{doc: doc, index: 99})
    end
  end

  describe "tables!/1" do
    test "returns the tables directly" do
      doc = Document.open!(@table_pdf)
      assert [%Table{page: 0}] = Page.tables!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@table_pdf)
      assert_raise Error, fn -> Page.tables!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "text_lines/1" do
    test "delegates to Document.text_lines/2 for the page" do
      doc = Document.open!(@valid_pdf)
      page = Document.page!(doc, 1)
      assert Page.text_lines(page) == Document.text_lines(doc, 1)
      assert {:ok, [%TextLine{text: "Page Two", page: 1}]} = Page.text_lines(page)
    end

    test "returns {:error, reason} for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Page.text_lines(%Page{doc: doc, index: 99})
    end
  end

  describe "text_lines!/1" do
    test "returns the lines directly" do
      doc = Document.open!(@valid_pdf)
      assert [%TextLine{text: "Page One", page: 0}] = Page.text_lines!(Document.page!(doc, 0))
    end

    test "raises for an out-of-range page" do
      doc = Document.open!(@valid_pdf)
      assert_raise Error, fn -> Page.text_lines!(%Page{doc: doc, index: 99}) end
    end
  end

  describe "label/1" do
    test "returns the page's declared label" do
      doc = Document.open!(@metadata_pdf)
      assert {:ok, "i"} = Page.label(Document.page!(doc, 0))
      assert {:ok, "ii"} = Page.label(Document.page!(doc, 1))
      assert {:ok, "1"} = Page.label(Document.page!(doc, 2))
    end

    test "falls back to the decimal page number when no labels are declared" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, "3"} = Page.label(Document.page!(doc, 2))
    end
  end

  describe "label!/1" do
    test "returns the label directly" do
      doc = Document.open!(@metadata_pdf)
      assert Page.label!(Document.page!(doc, 0)) == "i"
    end
  end
end
