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
  @cms_pdf Path.join(@fixtures, "form_signature_cms.pdf")
  @cms_tampered_pdf Path.join(@fixtures, "form_signature_cms_tampered.pdf")

  # Every fixture but the two CMS ones carries a marker rather than a signature,
  # chosen so a test can tell the dictionaries apart. Nothing decodes a marker.
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

  describe "a genuinely signed document" do
    setup do
      {:ok, [signature]} = Signature.list(open!(@cms_pdf))
      %{signature: signature}
    end

    test "reports the dictionary the signer wrote", %{signature: signature} do
      assert signature.sub_filter == :pkcs7_detached
      assert signature.signer_name == "Alice Example"
      assert signature.reason == "Approval"
      assert signature.location == "Kyiv"
      assert signature.contact_info == nil

      # `/M` is the moment the fixture was generated, so only its shape is fixed.
      assert signature.signing_time =~ ~r/\AD:\d{14}Z\z/
      assert [0, _, _, _] = signature.byte_range
    end

    test "carries a CMS blob bounded by its own DER length", %{signature: signature} do
      assert <<0x30, 0x82, der_length::16, _::binary>> = signature.contents

      padding = byte_size(signature.contents) - (4 + der_length)
      assert padding > 0
      assert binary_part(signature.contents, 4 + der_length, padding) == <<0::size(padding * 8)>>
    end

    test "covers every byte of the file", %{signature: signature} do
      assert Signature.covers_whole_document?(signature, File.stat!(@cms_pdf).size)
    end

    test "reports the same claims for a document altered after signing", %{signature: signature} do
      assert {:ok, [tampered]} = Signature.list(open!(@cms_tampered_pdf))
      assert tampered == signature

      # The altered byte is a form value inside the signed range, so what the
      # signature claims is unmoved while what it covers is not.
      assert {:ok, [%{value: "Alice"}]} = PdfElixide.Form.fields(open!(@cms_pdf))
      assert {:ok, [%{value: "Alicf"}]} = PdfElixide.Form.fields(open!(@cms_tampered_pdf))
    end
  end

  describe "verify/2 and verify_signer/1" do
    setup do
      {:ok, [signature]} = Signature.list(open!(@cms_pdf))
      {:ok, [tampered]} = Signature.list(open!(@cms_tampered_pdf))

      %{
        signature: signature,
        tampered: tampered,
        bytes: File.read!(@cms_pdf),
        tampered_bytes: File.read!(@cms_tampered_pdf)
      }
    end

    test "accepts the bytes it was signed over", %{signature: signature, bytes: bytes} do
      assert Signature.verify(signature, bytes) == {:ok, :valid}
    end

    test "follows the bytes it is handed, not the struct", %{
      signature: signature,
      tampered_bytes: tampered_bytes
    } do
      assert Signature.verify(signature, tampered_bytes) == {:ok, :invalid}
    end

    test "separates a claim from a finding", %{
      signature: signature,
      tampered: tampered,
      bytes: bytes,
      tampered_bytes: tampered_bytes
    } do
      assert tampered == signature

      assert Signature.verify(signature, bytes) == {:ok, :valid}
      assert Signature.verify(tampered, tampered_bytes) == {:ok, :invalid}
    end

    test "reports the blob alone as valid either way", %{
      signature: signature,
      tampered: tampered
    } do
      assert Signature.verify_signer(signature) == {:ok, :valid}
      assert Signature.verify_signer(tampered) == {:ok, :valid}
    end

    test "keeps answering after the document is closed", %{bytes: bytes} do
      doc = Document.open!(@cms_pdf)
      {:ok, [signature]} = Signature.list(doc)
      :ok = Document.close(doc)

      assert Signature.verify(signature, bytes) == {:ok, :valid}
      assert Signature.verify_signer(signature) == {:ok, :valid}
    end

    test "refuses a signature carrying no contents", %{signature: signature, bytes: bytes} do
      signature = %{signature | contents: nil}

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify(signature, bytes)
      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify_signer(signature)
    end

    test "refuses contents that are not a CMS blob", %{signature: signature, bytes: bytes} do
      signature = %{signature | contents: <<0, 1, 2>>}

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify(signature, bytes)
    end

    test "refuses a marker fixture's contents", %{bytes: bytes} do
      {:ok, [signature]} = Signature.list(open!(@signature_pdf))
      assert signature.contents == @deadbeef

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify_signer(signature)
      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify(signature, bytes)
    end

    test "refuses a byte range that is not four entries", %{
      signature: signature,
      bytes: bytes
    } do
      signature = %{signature | byte_range: [0, 10]}

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify(signature, bytes)
    end

    test "refuses a negative byte range", %{signature: signature, bytes: bytes} do
      signature = %{signature | byte_range: [0, 0, -1, 2]}

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.verify(signature, bytes)
    end

    test "refuses a byte range reaching past the bytes given", %{
      signature: signature,
      bytes: bytes
    } do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.verify(signature, binary_part(bytes, 0, 100))
    end

    # No fixture uses an encapsulated sub-filter, so override the signed one.
    test "declines a sub-filter whose signed content is not the byte range", %{
      signature: signature,
      bytes: bytes
    } do
      assert Signature.verify(%{signature | sub_filter: :pkcs7_sha1}, bytes) == {:ok, :unknown}
      assert Signature.verify(%{signature | sub_filter: :rfc3161}, bytes) == {:ok, :unknown}
    end

    test "still checks the sub-filters that are detached", %{
      signature: signature,
      bytes: bytes
    } do
      assert Signature.verify(%{signature | sub_filter: :cades_detached}, bytes) == {:ok, :valid}
      assert Signature.verify(%{signature | sub_filter: nil}, bytes) == {:ok, :valid}
    end

    test "declines before looking at what it would have checked", %{
      signature: signature,
      bytes: bytes
    } do
      signature = %{signature | sub_filter: :rfc3161, contents: nil}

      assert Signature.verify(signature, bytes) == {:ok, :unknown}
    end

    test "verifies the blob alone whatever the sub-filter says", %{signature: signature} do
      assert Signature.verify_signer(%{signature | sub_filter: :rfc3161}) == {:ok, :valid}
    end

    test "raises on a value the NIF cannot decode", %{signature: signature, bytes: bytes} do
      assert_raise ArgumentError, fn ->
        Signature.verify(%{signature | byte_range: [0, "x", 0, 0]}, bytes)
      end

      assert_raise ArgumentError, fn ->
        Signature.verify(%{signature | contents: 42}, bytes)
      end
    end

    test "raises on bytes that are not a binary", %{signature: signature} do
      assert_raise FunctionClauseError, fn -> Signature.verify(signature, :not_bytes) end
    end

    test "verify!/2 and verify_signer!/1 unwrap or raise", %{
      signature: signature,
      bytes: bytes
    } do
      assert Signature.verify!(signature, bytes) == :valid
      assert Signature.verify_signer!(signature) == :valid

      unsigned = %{signature | contents: nil}

      assert_raise Error, fn -> Signature.verify!(unsigned, bytes) end
      assert_raise Error, fn -> Signature.verify_signer!(unsigned) end
    end
  end

  describe "certificate/1" do
    setup do
      {:ok, [signature]} = Signature.list(open!(@cms_pdf))
      %{signature: signature}
    end

    test "hands back DER that :public_key decodes", %{signature: signature} do
      assert {:ok, der} = Signature.certificate(signature)

      assert :OTPCertificate = elem(:public_key.pkix_decode_cert(der, :otp), 0)

      # The fixture's signer certificate is self-signed, which is a property of
      # the certificate rather than of its regenerable subject name.
      assert :public_key.pkix_is_self_signed(der)
    end

    test "reads the same certificate out of a document altered after signing", %{
      signature: signature
    } do
      {:ok, [tampered]} = Signature.list(open!(@cms_tampered_pdf))

      assert Signature.certificate(tampered) == Signature.certificate(signature)
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@cms_pdf)
      {:ok, [signature]} = Signature.list(doc)
      :ok = Document.close(doc)

      assert {:ok, <<0x30, _::binary>>} = Signature.certificate(signature)
    end

    test "reads the blob whatever the sub-filter says", %{signature: signature} do
      assert Signature.certificate(%{signature | sub_filter: :rfc3161}) ==
               Signature.certificate(signature)
    end

    test "refuses a signature carrying no contents", %{signature: signature} do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.certificate(%{signature | contents: nil})
    end

    test "refuses contents that are not a CMS blob", %{signature: signature} do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.certificate(%{signature | contents: <<0, 1, 2>>})
    end

    test "refuses a marker fixture's contents" do
      {:ok, [signature]} = Signature.list(open!(@signature_pdf))
      assert signature.contents == @deadbeef

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.certificate(signature)
    end

    test "raises on a value the NIF cannot decode", %{signature: signature} do
      assert_raise ArgumentError, fn -> Signature.certificate(%{signature | contents: 42}) end
    end

    test "certificate!/1 unwraps or raises", %{signature: signature} do
      assert <<0x30, _::binary>> = Signature.certificate!(signature)

      assert_raise Error, fn -> Signature.certificate!(%{signature | contents: nil}) end
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
