defmodule PdfElixide.PageTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Page

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")

  describe "inspect/1" do
    test "renders the page index" do
      doc = Document.open!(@valid_pdf)
      assert inspect(Document.page!(doc, 2)) == "#PdfElixide.Page<2>"
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
      assert_raise RuntimeError, fn -> Page.text!(%Page{doc: doc, index: 99}) end
    end
  end
end
