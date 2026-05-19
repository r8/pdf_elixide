defmodule PdfElixide.DocumentTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")

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

  describe "extract_text/2" do
    test "returns {:ok, text} containing the page's text for each page" do
      doc = Document.open!(@valid_pdf)
      assert {:ok, p0} = Document.extract_text(doc, 0)
      assert {:ok, p1} = Document.extract_text(doc, 1)
      assert {:ok, p2} = Document.extract_text(doc, 2)
      assert p0 =~ "Page One"
      assert p1 =~ "Page Two"
      assert p2 =~ "Page Three"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert {:error, _reason} = Document.extract_text(doc, 99)
    end

    test "raises FunctionClauseError for negative page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.extract_text(doc, -1) end
    end
  end

  describe "extract_text!/2" do
    test "returns the text for a valid page" do
      doc = Document.open!(@valid_pdf)
      assert Document.extract_text!(doc, 1) =~ "Page Two"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise RuntimeError, fn -> Document.extract_text!(doc, 99) end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = Document.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Document.extract_text!(doc, :first) end
    end
  end
end
