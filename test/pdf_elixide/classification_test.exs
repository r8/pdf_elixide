defmodule PdfElixide.ClassificationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import PdfElixide.Handles
  import PdfElixide.Untyped

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.PageClassification
  alias PdfElixide.Document.PageClassification.Signals
  alias PdfElixide.Error

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @classification_pdf Path.join(@fixtures, "classification.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @encrypted_objstm_pdf Path.join(@fixtures, "encrypted_objstm.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  @form_metadata_pdf Path.join(@fixtures, "form_metadata.pdf")
  @no_pages_pdf Path.join(@fixtures, "no_pages.pdf")

  describe "classify/1" do
    test "gives one verdict per page, in page order" do
      pages = @classification_pdf |> open() |> Document.classify!()

      assert Enum.map(pages, &{&1.page, &1.kind, &1.reason}) == [
               {0, :text_layer, :native_text_high_confidence},
               {1, :scanned, :no_text_layer_present},
               {2, :image_text, :ok},
               {3, :empty, :empty}
             ]

      assert Enum.all?(pages, &(&1.confidence > 0.0 and &1.confidence <= 1.0))
    end

    test "marks the pages whose text is only in images" do
      pages = @classification_pdf |> open() |> Document.classify!()

      assert for(%{needs_ocr?: true, page: index} <- pages, do: index) == [1, 2]
    end

    test "returns the measurements behind each verdict" do
      [text, scan, figure, blank] = @classification_pdf |> open() |> Document.classify!()

      assert %Signals{image_area_ratio: +0.0, codec: :none, empty?: false} = text.signals
      assert text.signals.text_glyph_count > 24

      assert %Signals{text_glyph_count: 0, codec: :other} = scan.signals
      assert scan.signals.image_area_ratio == 1.0

      assert figure.signals.text_glyph_count > 24
      assert figure.signals.image_area_ratio > 0.05 and figure.signals.image_area_ratio < 0.8

      assert %Signals{text_glyph_count: 0, image_area_ratio: +0.0, empty?: true} = blank.signals
    end

    test "is empty for a document without pages" do
      assert {:ok, []} = @no_pages_pdf |> open() |> Document.classify()
    end

    test "fails on an unreadable page, naming it" do
      assert {:error, %Error{reason: :invalid_pdf, message: "page 2: " <> _}} =
               @broken_page_pdf |> open() |> Document.classify()
    end

    test "fails on a document that needs a password, until it is authenticated" do
      doc = open(@encrypted_pdf)

      assert {:error, %Error{reason: :encrypted, message: message}} = Document.classify(doc)
      refute message =~ "page"
      assert {:error, %Error{reason: :encrypted}} = Document.classify(doc, 0)

      assert {:ok, true} = Document.authenticate(doc, "secret")
      assert {:ok, [%PageClassification{} | _]} = Document.classify(doc)
    end

    test "fails on a document whose page count needs a password" do
      assert {:error, %Error{reason: :encrypted}} =
               @encrypted_objstm_pdf |> open() |> Document.classify()
    end

    test "raises from the bang variant" do
      assert_raise Error, ~r/page 2: /, fn ->
        @broken_page_pdf |> open() |> Document.classify!()
      end
    end
  end

  describe "classify/2" do
    test "classifies one page as classify/1 does" do
      doc = open(@classification_pdf)

      assert {:ok, Enum.at(Document.classify!(doc), 1)} == Document.classify(doc, 1)
      assert Document.classify!(doc, 1) == Page.classify!(Enum.at(doc, 1))
    end

    test "rejects an index past the last page" do
      assert {:error, %Error{reason: :out_of_range}} =
               @classification_pdf |> open() |> Document.classify(4)
    end

    test "raises for an index that is not a non-negative integer" do
      doc = open(@classification_pdf)

      assert_raise FunctionClauseError, fn -> Document.classify(doc, untyped(-1)) end
      assert_raise FunctionClauseError, fn -> Document.classify!(doc, untyped(:first)) end
    end

    test "calls a page empty when its only text is form-field values" do
      doc = open(@form_metadata_pdf)

      assert %PageClassification{kind: :empty, needs_ocr?: false} = Document.classify!(doc, 0)
      assert Document.text!(doc, 0) =~ "John Doe"
    end

    test "a closed document is :closed" do
      doc = open(@classification_pdf)
      page = Enum.at(doc, 0)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.classify(doc)
      assert {:error, %Error{reason: :closed}} = Document.classify(doc, 0)
      assert {:error, %Error{reason: :closed}} = Page.classify(page)
    end
  end
end
