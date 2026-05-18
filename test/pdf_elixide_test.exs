defmodule PdfElixideTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures")
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @invalid_pdf Path.join(@fixtures, "invalid.bin")
  @missing_pdf Path.join(@fixtures, "nonexistent.pdf")

  describe "open/1" do
    test "returns {:ok, doc} for a valid PDF file" do
      assert {:ok, doc} = PdfElixide.open(@valid_pdf)
      assert is_reference(doc)
    end

    test "returns {:error, reason} when file does not exist" do
      assert {:error, _reason} = PdfElixide.open(@missing_pdf)
    end

    test "returns {:error, reason} for a file that is not a valid PDF" do
      assert {:error, _reason} = PdfElixide.open(@invalid_pdf)
    end
  end

  describe "open!/1" do
    test "returns doc reference for a valid PDF file" do
      doc = PdfElixide.open!(@valid_pdf)
      assert is_reference(doc)
    end

    test "raises RuntimeError when file does not exist" do
      assert_raise RuntimeError, ~r/Failed to open PDF/, fn ->
        PdfElixide.open!(@missing_pdf)
      end
    end

    test "raises RuntimeError for a file that is not a valid PDF" do
      assert_raise RuntimeError, ~r/Failed to open PDF/, fn ->
        PdfElixide.open!(@invalid_pdf)
      end
    end
  end

  describe "from_binary/1" do
    test "returns {:ok, doc} for valid PDF bytes" do
      pdf_bytes = File.read!(@valid_pdf)
      assert {:ok, doc} = PdfElixide.from_binary(pdf_bytes)
      assert is_reference(doc)
    end

    test "returns {:error, reason} for invalid bytes" do
      assert {:error, _reason} = PdfElixide.from_binary("not a pdf")
    end

    test "returns {:error, reason} for empty binary" do
      assert {:error, _reason} = PdfElixide.from_binary(<<>>)
    end
  end

  describe "from_binary!/1" do
    test "returns doc reference for valid PDF bytes" do
      pdf_bytes = File.read!(@valid_pdf)
      doc = PdfElixide.from_binary!(pdf_bytes)
      assert is_reference(doc)
    end

    test "raises RuntimeError for invalid bytes" do
      assert_raise RuntimeError, ~r/Failed to open PDF from binary/, fn ->
        PdfElixide.from_binary!("not a pdf")
      end
    end
  end

  describe "page_count/1" do
    test "returns {:ok, 3} for the valid fixture" do
      doc = PdfElixide.open!(@valid_pdf)
      assert {:ok, 3} = PdfElixide.page_count(doc)
    end

    test "raises FunctionClauseError for non-reference input" do
      assert_raise FunctionClauseError, fn ->
        PdfElixide.page_count(:not_a_ref)
      end
    end
  end

  describe "page_count!/1" do
    test "returns the integer page count for the valid fixture" do
      doc = PdfElixide.open!(@valid_pdf)
      assert PdfElixide.page_count!(doc) == 3
    end

    test "raises FunctionClauseError for non-reference input" do
      assert_raise FunctionClauseError, fn ->
        PdfElixide.page_count!(:not_a_ref)
      end
    end
  end

  describe "version/1" do
    test "returns {:ok, {1, 4}} for the valid fixture" do
      doc = PdfElixide.open!(@valid_pdf)
      assert {:ok, {1, 4}} = PdfElixide.version(doc)
    end

    test "raises FunctionClauseError for non-reference input" do
      assert_raise FunctionClauseError, fn ->
        PdfElixide.version(:not_a_ref)
      end
    end
  end

  describe "version!/1" do
    test "returns the {major, minor} tuple for the valid fixture" do
      doc = PdfElixide.open!(@valid_pdf)
      assert PdfElixide.version!(doc) == {1, 4}
    end

    test "raises FunctionClauseError for non-reference input" do
      assert_raise FunctionClauseError, fn ->
        PdfElixide.version!(:not_a_ref)
      end
    end
  end

  describe "extract_text/2" do
    test "returns {:ok, text} containing the page's text for each page" do
      doc = PdfElixide.open!(@valid_pdf)
      assert {:ok, p0} = PdfElixide.extract_text(doc, 0)
      assert {:ok, p1} = PdfElixide.extract_text(doc, 1)
      assert {:ok, p2} = PdfElixide.extract_text(doc, 2)
      assert p0 =~ "Page One"
      assert p1 =~ "Page Two"
      assert p2 =~ "Page Three"
    end

    test "returns {:error, reason} for an out-of-range page index" do
      doc = PdfElixide.open!(@valid_pdf)
      assert {:error, _reason} = PdfElixide.extract_text(doc, 99)
    end

    test "raises FunctionClauseError for non-reference doc" do
      assert_raise FunctionClauseError, fn -> PdfElixide.extract_text(:not_a_ref, 0) end
    end

    test "raises FunctionClauseError for negative page index" do
      doc = PdfElixide.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> PdfElixide.extract_text(doc, -1) end
    end
  end

  describe "extract_text!/2" do
    test "returns the text for a valid page" do
      doc = PdfElixide.open!(@valid_pdf)
      assert PdfElixide.extract_text!(doc, 1) =~ "Page Two"
    end

    test "raises RuntimeError for an out-of-range page index" do
      doc = PdfElixide.open!(@valid_pdf)

      assert_raise RuntimeError, ~r/Failed to extract text/, fn ->
        PdfElixide.extract_text!(doc, 99)
      end
    end

    test "raises FunctionClauseError for non-integer page index" do
      doc = PdfElixide.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> PdfElixide.extract_text!(doc, :first) end
    end
  end
end
