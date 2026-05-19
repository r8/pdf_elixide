defmodule PdfElixideTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures")
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @invalid_pdf Path.join(@fixtures, "invalid.bin")
  @missing_pdf Path.join(@fixtures, "nonexistent.pdf")

  describe "open/1" do
    test "returns {:ok, doc} for a valid PDF file" do
      assert {:ok, doc} = PdfElixide.open(@valid_pdf)
      assert %PdfElixide.Document{} = doc
    end

    test "returns {:error, reason} when file does not exist" do
      assert {:error, _reason} = PdfElixide.open(@missing_pdf)
    end

    test "returns {:error, reason} for a file that is not a valid PDF" do
      assert {:error, _reason} = PdfElixide.open(@invalid_pdf)
    end
  end

  describe "open!/1" do
    test "returns a Document struct for a valid PDF file" do
      assert %PdfElixide.Document{} = PdfElixide.open!(@valid_pdf)
    end

    test "raises RuntimeError when file does not exist" do
      assert_raise RuntimeError, fn -> PdfElixide.open!(@missing_pdf) end
    end

    test "raises RuntimeError for a file that is not a valid PDF" do
      assert_raise RuntimeError, fn -> PdfElixide.open!(@invalid_pdf) end
    end
  end

  describe "from_binary/1" do
    test "returns {:ok, doc} for valid PDF bytes" do
      pdf_bytes = File.read!(@valid_pdf)
      assert {:ok, doc} = PdfElixide.from_binary(pdf_bytes)
      assert %PdfElixide.Document{} = doc
    end

    test "returns {:error, reason} for invalid bytes" do
      assert {:error, _reason} = PdfElixide.from_binary("not a pdf")
    end

    test "returns {:error, reason} for empty binary" do
      assert {:error, _reason} = PdfElixide.from_binary(<<>>)
    end
  end

  describe "from_binary!/1" do
    test "returns a Document struct for valid PDF bytes" do
      pdf_bytes = File.read!(@valid_pdf)
      assert %PdfElixide.Document{} = PdfElixide.from_binary!(pdf_bytes)
    end

    test "raises RuntimeError for invalid bytes" do
      assert_raise RuntimeError, fn -> PdfElixide.from_binary!("not a pdf") end
    end
  end
end
