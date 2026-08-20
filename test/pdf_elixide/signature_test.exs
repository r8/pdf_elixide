defmodule PdfElixide.SignatureTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Signature

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @signature_pdf Path.join(@fixtures, "form_signature.pdf")
  @signature_edge_pdf Path.join(@fixtures, "form_signature_edge.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @no_form_pdf Path.join(@fixtures, "sample.pdf")
  @cyclic_pdf Path.join(@fixtures, "form_cyclic.pdf")
  @utf16_pdf Path.join(@fixtures, "form_signature_utf16.pdf")
  @values_pdf Path.join(@fixtures, "form_signature_values.pdf")
  @unreadable_pdf Path.join(@fixtures, "form_unreadable_field.pdf")
  @bad_value_pdf Path.join(@fixtures, "form_signature_value_not_a_dict.pdf")
  @dangling_value_pdf Path.join(@fixtures, "form_signature_value_dangling.pdf")
  @null_value_pdf Path.join(@fixtures, "form_signature_value_null.pdf")

  # No fixture's `/Contents` is a real CMS blob; each is a marker chosen so a
  # test can tell the signature dictionaries apart. Nothing here decodes them,
  # which is why a cryptographically real fixture is not needed.
  @deadbeef <<0xDE, 0xAD, 0xBE, 0xEF>>
  @cafebabe <<0xCA, 0xFE, 0xBA, 0xBE>>
  @coffee <<0xC0, 0xFF, 0xEE, 0x11>>

  defp open!(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  describe "list/1" do
    test "reports the signature dictionary a signed field points at" do
      assert {:ok, [signature]} = Signature.list(open!(@signature_pdf))

      assert signature.sub_filter == :pkcs7_detached
      assert signature.signing_time == "D:20240101000000Z"
      assert signature.contents == @deadbeef
      assert length(signature.byte_range) == 4
    end

    test "decodes text entries as PDF text strings, not as UTF-8" do
      assert {:ok, [signature]} = Signature.list(open!(@utf16_pdf))

      assert signature.signer_name == "Анна Петрова"
      assert signature.reason == "Проверка подписи"
      assert signature.location == "Café"
      refute signature.signer_name =~ "\uFFFD"
    end

    test "reports one signature per dictionary, however many fields reach it" do
      assert {:ok, signatures} = Signature.list(open!(@values_pdf))

      assert Enum.map(signatures, & &1.contents) == [
               <<0xBA, 0xAD, 0xF0, 0x0D>>,
               <<0xF0, 0x0D, 0xCA, 0xFE>>
             ]
    end

    test "refuses a field it cannot read, where reading fields tolerates it" do
      doc = open!(@unreadable_pdf)

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.list(doc)
      assert {:ok, []} = PdfElixide.Form.fields(doc)
    end

    test "refuses a /V that is not a signature dictionary" do
      doc = open!(@bad_value_pdf)

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.list(doc)
      assert {:ok, [%{name: "signer_name"}]} = PdfElixide.Form.fields(doc)
    end

    test "refuses a /V naming an object the file does not contain" do
      doc = open!(@dangling_value_pdf)

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.list(doc)
      assert {:ok, [%{name: "signer_name"}]} = PdfElixide.Form.fields(doc)
    end

    test "skips a field whose /V is null and lists the signed one" do
      assert {:ok, [signature]} = Signature.list(open!(@null_value_pdf))

      assert signature.contents == @coffee
    end

    test "finds a signature whose /FT is typed on an ancestor" do
      assert {:ok, [signature]} = Signature.list(open!(@signature_edge_pdf))

      assert signature.contents == @cafebabe
    end

    test "answers [] for a form with only fillable fields" do
      assert {:ok, []} = Signature.list(open!(@form_pdf))
    end

    test "answers [] for a document with no AcroForm" do
      assert {:ok, []} = Signature.list(open!(@no_form_pdf))
    end

    test "refuses a cyclic field tree instead of walking it" do
      assert {:error, %Error{reason: :invalid_pdf}} = Signature.list(open!(@cyclic_pdf))
    end

    test "reports a closed document" do
      doc = Document.open!(@signature_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Signature.list(doc)
    end

    test "reads from an editor and agrees with the document" do
      editor = Editor.open!(@signature_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert Signature.list(editor) == Signature.list(open!(@signature_pdf))
    end
  end

  describe "list!/1" do
    test "returns the signatures" do
      assert [%Signature{}] = Signature.list!(open!(@signature_pdf))
    end

    test "raises on a cyclic field tree" do
      doc = open!(@cyclic_pdf)

      assert_raise Error, fn -> Signature.list!(doc) end
    end
  end

  describe "covers_whole_document?/2" do
    setup do
      {:ok, [signature]} = Signature.list(open!(@signature_pdf))
      %{signature: signature}
    end

    test "true when the signed ranges end exactly at the last byte", %{signature: signature} do
      signature = %{signature | byte_range: [0, 840, 1962, 420]}

      assert Signature.covers_whole_document?(signature, 2382)
    end

    test "false when content was appended after signing", %{signature: signature} do
      signature = %{signature | byte_range: [0, 840, 1962, 420]}

      refute Signature.covers_whole_document?(signature, 4096)
    end

    test "false when the range does not start at zero", %{signature: signature} do
      signature = %{signature | byte_range: [16, 840, 1962, 420]}

      refute Signature.covers_whole_document?(signature, 2382)
    end

    test "false for a malformed range", %{signature: signature} do
      signature = %{signature | byte_range: [0, 840]}

      refute Signature.covers_whole_document?(signature, 2382)
    end

    test "false when the first range runs past the start of the second", %{signature: signature} do
      signature = %{signature | byte_range: [0, 2500, 2000, 0]}

      refute Signature.covers_whole_document?(signature, 2000)
    end

    test "false for a negative offset or length", %{signature: signature} do
      signature = %{signature | byte_range: [0, 10, 3000, -1000]}

      refute Signature.covers_whole_document?(signature, 2000)
    end

    test "raises for a size that is not a byte count", %{signature: signature} do
      assert_raise FunctionClauseError, fn ->
        Signature.covers_whole_document?(signature, "2382")
      end
    end
  end

  describe "count/1" do
    test "counts the signatures" do
      assert {:ok, 1} = Signature.count(open!(@signature_pdf))
      assert {:ok, 0} = Signature.count(open!(@form_pdf))
    end

    test "propagates a read failure" do
      assert {:error, %Error{reason: :invalid_pdf}} = Signature.count(open!(@cyclic_pdf))
    end

    test "count!/1 returns the bare count" do
      assert Signature.count!(open!(@signature_pdf)) == 1
    end
  end
end
