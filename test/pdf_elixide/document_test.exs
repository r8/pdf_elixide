defmodule PdfElixide.DocumentTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Page

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @tagged_pdf Path.join(@fixtures, "tagged.pdf")
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
      assert {:error, _reason} = Document.page(doc, 99)
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
      assert_raise RuntimeError, fn -> Document.page!(doc, 99) end
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
      assert {:error, "Authentication failed: wrong password"} =
               Document.open(@encrypted_pdf, password: "wrong")
    end

    test "password: nil is a no-op (unencrypted PDF opens normally)" do
      assert {:ok, %Document{}} = Document.open(@valid_pdf, password: nil)
    end

    test "extracts text after open-with-password" do
      doc = Document.open!(@encrypted_pdf, password: @password)
      assert Document.extract_text!(doc, 0) =~ "Page One"
    end
  end

  describe "from_binary/2 with password option" do
    test "opens an encrypted PDF binary with the correct password" do
      bytes = File.read!(@encrypted_pdf)
      assert {:ok, %Document{}} = Document.from_binary(bytes, password: @password)
    end

    test "returns {:error, _} with the wrong password" do
      bytes = File.read!(@encrypted_pdf)

      assert {:error, "Authentication failed: wrong password"} =
               Document.from_binary(bytes, password: "wrong")
    end
  end

  describe "open!/2 and from_binary!/2 bang variants" do
    test "open! raises with the wrong-password message" do
      assert_raise RuntimeError, "Authentication failed: wrong password", fn ->
        Document.open!(@encrypted_pdf, password: "wrong")
      end
    end

    test "from_binary! raises with the wrong-password message" do
      bytes = File.read!(@encrypted_pdf)

      assert_raise RuntimeError, "Authentication failed: wrong password", fn ->
        Document.from_binary!(bytes, password: "wrong")
      end
    end
  end
end
