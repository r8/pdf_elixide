defmodule PdfElixide.SignatureTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Signature
  alias PdfElixide.Signature.DSS
  alias PdfElixide.Signature.Timestamp

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
  @unsigned_pdf Path.join(@fixtures, "form_signature_unsigned.pdf")
  @unnamed_pdf Path.join(@fixtures, "form_signature_unnamed.pdf")
  @cms_pdf Path.join(@fixtures, "form_signature_cms.pdf")
  @cms_tampered_pdf Path.join(@fixtures, "form_signature_cms_tampered.pdf")
  @pades_pdf Path.join(@fixtures, "form_signature_pades.pdf")
  @pades_t_pdf Path.join(@fixtures, "form_signature_pades_t.pdf")
  @pades_lt_pdf Path.join(@fixtures, "form_signature_pades_lt.pdf")
  @pades_t_mismatched_pdf Path.join(@fixtures, "form_signature_pades_t_mismatched.pdf")
  @pades_lta_pdf Path.join(@fixtures, "form_signature_pades_lta.pdf")
  @chain_pdf Path.join(@fixtures, "form_signature_chain.pdf")
  @dss_pdf Path.join(@fixtures, "signature_dss.pdf")
  @dss_empty_pdf Path.join(@fixtures, "signature_dss_empty.pdf")
  @doctimestamp_pdf Path.join(@fixtures, "signature_doctimestamp.pdf")
  @doctimestamp_decoy_pdf Path.join(@fixtures, "signature_doctimestamp_decoy.pdf")
  @doctimestamp_unsigned_pdf Path.join(@fixtures, "signature_doctimestamp_unsigned.pdf")
  @doctimestamp_gapped_pdf Path.join(@fixtures, "signature_doctimestamp_gapped.pdf")
  @doctimestamp_covering_pdf Path.join(@fixtures, "signature_doctimestamp_covering.pdf")
  @doctimestamp_mistyped_pdf Path.join(@fixtures, "signature_doctimestamp_mistyped.pdf")

  # Outside the CMS and PAdES sets, every fixture carries a marker rather than a
  # signature, chosen so a test can tell the dictionaries apart. Nothing decodes
  # a marker.
  @deadbeef <<0xDE, 0xAD, 0xBE, 0xEF>>
  @cafebabe <<0xCA, 0xFE, 0xBA, 0xBE>>
  @coffee <<0xC0, 0xFF, 0xEE, 0x11>>

  # A bare `TSTInfo` — the shape `Timestamp.parse/1` accepts alongside a full
  # CMS-wrapped token, and the one `Timestamp.verify/1` has no signature to
  # check. Lifted out of the timestamp the PAdES fixtures were generated with,
  # so it is a real one; it stands alone and no fixture has to agree with it.
  @bare_tst_info Base.decode16!(
                   "3081B0020101060A2B06010401868D1F01013031300D06096086480165" <>
                     "030402010500042083979245471247D4E0B5E7FC65BC51ABA099A6FAA5" <>
                     "161B0CE77E64216AE118E2020104180F32303236303832333037353030" <>
                     "335A3003020101020876F7765B0076DF09A049A4473045310B30090603" <>
                     "5504061302554131183016060355040A0C0F506466456C697869646520" <>
                     "54657374311C301A06035504030C13506466456C697869646520546573" <>
                     "7420545341"
                 )

  defp open!(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  # Flip a byte of the imprint the authority signed over. The token keeps its
  # length and still parses, so only the signature across it can report this.
  defp tamper(%Timestamp{token: token, message_imprint: imprint}) do
    {offset, _size} = :binary.match(token, imprint)
    <<head::binary-size(offset), byte, rest::binary>> = token

    head <> <<rem(byte + 1, 256)>> <> rest
  end

  describe "list/1" do
    test "reports the signature dictionary a signed field points at" do
      assert {:ok, [signature]} = Signature.list(open!(@signature_pdf))

      assert signature.field_name == "signature"
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

      assert Enum.map(signatures, & &1.field_name) == ["signature", "inherited_value.sig"]
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

    test "answers nil for a signature on a field the document does not name" do
      assert {:ok, [named, unnamed]} = Signature.list(open!(@unnamed_pdf))

      assert named.field_name == "signature"
      assert unnamed.field_name == nil
      assert unnamed.contents == <<0xFA, 0xCA, 0xDE, 0x02>>
    end

    test "finds a signature whose /FT is typed on an ancestor" do
      assert {:ok, [signature]} = Signature.list(open!(@signature_edge_pdf))

      assert signature.contents == @cafebabe
      assert signature.field_name == "inherited.leaf"
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

  describe "unsigned_fields/1" do
    test "reports the places left to sign, however the field is shaped" do
      doc = open!(@unsigned_pdf)

      assert {:ok, ["countersign", "witness", "group.slot"]} = Signature.unsigned_fields(doc)
    end

    test "does not report a field whose kids are fields of their own" do
      doc = open!(@unsigned_pdf)

      assert {:ok, unsigned} = Signature.unsigned_fields(doc)
      assert "group.slot" in unsigned
      refute "group" in unsigned

      assert {:ok, [%{field_name: "signature"}]} = Signature.list(doc)
    end

    test "does not report a field the document does not name" do
      doc = open!(@unnamed_pdf)

      assert {:ok, ["countersign"]} = Signature.unsigned_fields(doc)
    end

    test "partitions a form's signature fields with list/1" do
      doc = open!(@unsigned_pdf)

      assert {:ok, [signature]} = Signature.list(doc)
      assert signature.field_name == "signature"
      assert {:ok, unsigned} = Signature.unsigned_fields(doc)
      refute signature.field_name in unsigned
    end

    test "reports a field whose value was cleared" do
      doc = open!(@null_value_pdf)

      assert {:ok, ["unsigned"]} = Signature.unsigned_fields(doc)
      assert {:ok, [%{field_name: "signature"}]} = Signature.list(doc)
    end

    test "does not report a grouping field whose kid is signed" do
      doc = open!(@signature_edge_pdf)

      assert {:ok, []} = Signature.unsigned_fields(doc)
      assert {:ok, [%{field_name: "inherited.leaf"}]} = Signature.list(doc)
    end

    test "does not report a field whose widgets merely share its signature" do
      assert {:ok, []} = Signature.unsigned_fields(open!(@values_pdf))
    end

    test "answers [] for a form with only fillable fields" do
      assert {:ok, []} = Signature.unsigned_fields(open!(@form_pdf))
    end

    test "answers [] for a document with no AcroForm" do
      assert {:ok, []} = Signature.unsigned_fields(open!(@no_form_pdf))
    end

    test "counts a field carrying an unreadable value as signed, where list/1 refuses" do
      for path <- [@bad_value_pdf, @dangling_value_pdf] do
        doc = open!(path)

        assert {:ok, []} = Signature.unsigned_fields(doc)
        assert {:error, %Error{reason: :invalid_pdf}} = Signature.list(doc)
      end
    end

    test "refuses a field it cannot read" do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.unsigned_fields(open!(@unreadable_pdf))
    end

    test "refuses a cyclic field tree instead of walking it" do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.unsigned_fields(open!(@cyclic_pdf))
    end

    test "reports a closed document" do
      doc = Document.open!(@unsigned_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Signature.unsigned_fields(doc)
    end

    test "reads from an editor and agrees with the document" do
      editor = Editor.open!(@unsigned_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert Signature.unsigned_fields(editor) == Signature.unsigned_fields(open!(@unsigned_pdf))
    end
  end

  describe "unsigned_fields!/1" do
    test "returns the field names" do
      assert ["countersign", "witness", "group.slot"] =
               Signature.unsigned_fields!(open!(@unsigned_pdf))
    end

    test "raises on a cyclic field tree" do
      assert_raise Error, fn -> Signature.unsigned_fields!(open!(@cyclic_pdf)) end
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

    # Encoding order varies, so assert membership rather than identity.
    test "reads one certificate out of a blob carrying a chain", %{signature: signature} do
      {:ok, [chained]} = Signature.list(open!(@chain_pdf))
      {:ok, [%Signature{} = b_t]} = Signature.list(open!(@pades_t_pdf))
      {:ok, timestamp} = Signature.timestamp(b_t)

      signer = Signature.certificate!(signature)
      authority = Signature.certificate!(%{b_t | contents: timestamp.token})

      assert {:ok, der} = Signature.certificate(chained)
      assert :OTPCertificate = elem(:public_key.pkix_decode_cert(der, :otp), 0)
      assert der in [signer, authority]
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

  describe "pades_level/1" do
    setup do
      {:ok, [b_b]} = Signature.list(open!(@pades_pdf))
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))
      %{b_b: b_b, b_t: b_t}
    end

    test "separates a timestamped signature from a bare one", %{b_b: b_b, b_t: b_t} do
      assert b_b.sub_filter == :cades_detached
      assert b_t.sub_filter == :cades_detached

      assert Signature.pades_level(b_b) == {:ok, :b_b}
      assert Signature.pades_level(b_t) == {:ok, :b_t}
    end

    # Arity 1 passes no security store, which is what caps it at :b_t; the
    # pades_level/2 block covers the same signature reaching :b_lt with one.
    test "reports no level above :b_t without a store", %{b_t: b_t} do
      assert {:ok, level} = Signature.pades_level(b_t)
      assert level in [:b_b, :b_t]
    end

    test "answers nil for a signature the levels do not describe" do
      {:ok, [pkcs7]} = Signature.list(open!(@cms_pdf))
      assert pkcs7.sub_filter == :pkcs7_detached

      assert Signature.pades_level(pkcs7) == {:ok, nil}
      assert Signature.pades_level(%{pkcs7 | sub_filter: nil}) == {:ok, nil}
    end

    test "reads the declaration rather than the blob", %{b_b: b_b} do
      {:ok, [pkcs7]} = Signature.list(open!(@cms_pdf))

      assert Signature.pades_level(%{pkcs7 | sub_filter: :cades_detached}) == {:ok, :b_b}
      assert Signature.pades_level(%{b_b | sub_filter: :rfc3161}) == {:ok, nil}
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@pades_t_pdf)
      {:ok, [signature]} = Signature.list(doc)
      :ok = Document.close(doc)

      assert Signature.pades_level(signature) == {:ok, :b_t}
    end

    # :b_b is the floor rather than a finding, so an unreadable blob reaches it.
    test "reports the floor for contents it cannot read", %{b_b: b_b} do
      assert Signature.pades_level(%{b_b | contents: <<0, 1, 2>>}) == {:ok, :b_b}

      {:ok, [marker]} = Signature.list(open!(@signature_pdf))
      assert marker.contents == @deadbeef
      assert Signature.pades_level(%{marker | sub_filter: :cades_detached}) == {:ok, :b_b}
    end

    test "refuses a PAdES signature carrying no contents", %{b_b: b_b} do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.pades_level(%{b_b | contents: nil})
    end

    test "declines before looking at what it would have read", %{b_b: b_b} do
      signature = %{b_b | sub_filter: :pkcs7_detached, contents: nil}

      assert Signature.pades_level(signature) == {:ok, nil}
    end

    test "raises on a value the NIF cannot decode", %{b_b: b_b} do
      assert_raise ArgumentError, fn -> Signature.pades_level(%{b_b | contents: 42}) end
    end

    test "pades_level!/1 unwraps or raises", %{b_b: b_b, b_t: b_t} do
      assert Signature.pades_level!(b_t) == :b_t

      assert_raise Error, fn -> Signature.pades_level!(%{b_b | contents: nil}) end
    end

    test "the fixtures verify as the signatures they claim to be", %{b_b: b_b, b_t: b_t} do
      assert Signature.verify(b_b, File.read!(@pades_pdf)) == {:ok, :valid}
      assert Signature.verify(b_t, File.read!(@pades_t_pdf)) == {:ok, :valid}
    end
  end

  describe "pades_level/2" do
    setup do
      doc = open!(@pades_lt_pdf)
      {:ok, [b_lt]} = Signature.list(doc)
      {:ok, dss} = Signature.dss(doc)
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))
      %{b_lt: b_lt, b_t: b_t, dss: dss, other_dss: Signature.dss!(open!(@dss_pdf))}
    end

    test "reaches :b_lt only with the store that names the signature", %{b_lt: b_lt, dss: dss} do
      assert Signature.pades_level(b_lt, dss) == {:ok, :b_lt}
      assert Signature.pades_level(b_lt, nil) == {:ok, :b_t}
      assert Signature.pades_level(b_lt) == {:ok, :b_t}
    end

    # The store is real but its one /VRI entry is keyed on another signature, so
    # the lookup misses and the answer stays where arity 1 left it.
    test "a store with no matching entry lifts nothing", %{b_lt: b_lt, other_dss: other} do
      assert Signature.pades_level(b_lt, other) == {:ok, :b_t}
    end

    test "a timestamp alone is not :b_lt", %{b_t: b_t, dss: dss} do
      assert Signature.pades_level(b_t, dss) == {:ok, :b_t}
    end

    # The lookup is on the entry's key, so an entry holding nothing lifts the
    # level as a full one does. No fixture: no signer writes an empty entry.
    test "an entry carrying nothing still reaches :b_lt", %{b_lt: b_lt} do
      empty = %DSS.VRI{
        signature_digest: Base.encode16(:crypto.hash(:sha, b_lt.contents)),
        certificates: [],
        crls: [],
        ocsp_responses: [],
        timestamp: nil
      }

      store = %DSS{certificates: [], crls: [], ocsp_responses: [], vri: [empty]}

      assert Signature.pades_level(b_lt, store) == {:ok, :b_lt}
    end

    test "a store cannot raise a signature the levels do not describe", %{dss: dss} do
      {:ok, [pkcs7]} = Signature.list(open!(@cms_pdf))

      assert Signature.pades_level(pkcs7, dss) == {:ok, nil}
      assert Signature.pades_level(%{pkcs7 | sub_filter: nil}, dss) == {:ok, nil}
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@pades_lt_pdf)
      {:ok, [signature]} = Signature.list(doc)
      {:ok, dss} = Signature.dss(doc)
      :ok = Document.close(doc)

      assert Signature.pades_level(signature, dss) == {:ok, :b_lt}
    end

    test "refuses a PAdES signature carrying no contents", %{b_lt: b_lt, dss: dss} do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.pades_level(%{b_lt | contents: nil}, dss)
    end

    test "raises on a store it cannot decode", %{b_lt: b_lt, dss: dss} do
      assert_raise FunctionClauseError, fn -> Signature.pades_level(b_lt, %{}) end
      assert_raise ArgumentError, fn -> Signature.pades_level(b_lt, %{dss | vri: [42]}) end
    end

    test "pades_level!/2 unwraps or raises", %{b_lt: b_lt, dss: dss} do
      assert Signature.pades_level!(b_lt, dss) == :b_lt

      assert_raise Error, fn -> Signature.pades_level!(%{b_lt | contents: nil}, dss) end
    end
  end

  describe "pades_level/3" do
    setup do
      doc = open!(@pades_lta_pdf)
      {:ok, [signature]} = Signature.list(doc)
      {:ok, dss} = Signature.dss(doc)

      %{signature: signature, dss: dss, bytes: File.read!(@pades_lta_pdf)}
    end

    test "reaches :b_lta with the store and the file's own bytes", ctx do
      assert Signature.pades_level(ctx.signature, ctx.dss, ctx.bytes) == {:ok, :b_lta}
    end

    test "adds nothing without the store", ctx do
      assert Signature.pades_level(ctx.signature, nil, ctx.bytes) == {:ok, :b_t}
      assert Signature.pades_level(ctx.signature, ctx.dss) == {:ok, :b_lt}
    end

    test "a signature that does not reach :b_lt cannot reach :b_lta", ctx do
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))

      assert Signature.pades_level(b_t, ctx.dss, ctx.bytes) == {:ok, :b_t}
    end

    test "stays :b_lt for bytes carrying no archival timestamp", ctx do
      assert Signature.pades_level(ctx.signature, ctx.dss, File.read!(@pades_lt_pdf)) ==
               {:ok, :b_lt}
    end

    test "stays :b_lt for bytes that only carry the names", ctx do
      assert Signature.pades_level(ctx.signature, ctx.dss, File.read!(@doctimestamp_decoy_pdf)) ==
               {:ok, :b_lt}
    end

    test "stays :b_lt for an archival timestamp that does not hold up", ctx do
      for pdf <- [
            @doctimestamp_unsigned_pdf,
            @doctimestamp_gapped_pdf,
            @doctimestamp_mistyped_pdf
          ] do
        assert Signature.pades_level(ctx.signature, ctx.dss, File.read!(pdf)) == {:ok, :b_lt}
      end
    end

    test "the bytes cannot raise a signature the levels do not describe", ctx do
      {:ok, [pkcs7]} = Signature.list(open!(@cms_pdf))

      assert Signature.pades_level(pkcs7, ctx.dss, ctx.bytes) == {:ok, nil}
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@pades_lta_pdf)
      {:ok, [signature]} = Signature.list(doc)
      {:ok, dss} = Signature.dss(doc)
      :ok = Document.close(doc)

      assert Signature.pades_level(signature, dss, File.read!(@pades_lta_pdf)) == {:ok, :b_lta}
    end

    test "refuses a PAdES signature carrying no contents", ctx do
      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.pades_level(%{ctx.signature | contents: nil}, ctx.dss, ctx.bytes)
    end

    test "raises on bytes that are not a binary", ctx do
      assert_raise FunctionClauseError, fn ->
        Signature.pades_level(ctx.signature, ctx.dss, 42)
      end
    end

    test "pades_level!/3 unwraps or raises", ctx do
      assert Signature.pades_level!(ctx.signature, ctx.dss, ctx.bytes) == :b_lta

      assert_raise Error, fn ->
        Signature.pades_level!(%{ctx.signature | contents: nil}, ctx.dss, ctx.bytes)
      end
    end
  end

  describe "document_timestamp?/1" do
    test "finds the archival timestamp an archived document carries" do
      assert Signature.document_timestamp?(File.read!(@pades_lta_pdf))
    end

    test "answers false for a document carrying none" do
      refute Signature.document_timestamp?(File.read!(@pades_lt_pdf))
      refute Signature.document_timestamp?(File.read!(@no_form_pdf))
    end

    test "is not satisfied by the two names appearing in the file" do
      refute Signature.document_timestamp?(File.read!(@doctimestamp_decoy_pdf))
    end

    test "is not satisfied by a timestamp whose byte range covers nothing" do
      refute Signature.document_timestamp?(File.read!(@doctimestamp_pdf))
    end

    # Its imprint matches and its byte range is the real one; the CMS wrapper is
    # the only thing separating it from the archived document it was cut from.
    test "is not satisfied by a token nobody signed" do
      refute Signature.document_timestamp?(File.read!(@doctimestamp_unsigned_pdf))
    end

    # Its token is real and made over exactly the bytes its range covers; the
    # width of the excluded hole is the only thing wrong with it.
    test "is not satisfied by a timestamp excluding more than its own contents" do
      refute Signature.document_timestamp?(File.read!(@doctimestamp_gapped_pdf))
    end

    # One byte from the archived file it was cut from: the token's encapsulated
    # content is typed as something other than a TSTInfo, so the document itself
    # says this is not a timestamp.
    test "is not satisfied by a token that does not say it is one" do
      refute Signature.document_timestamp?(File.read!(@doctimestamp_mistyped_pdf))
    end

    test "is lost when a covered byte changes" do
      bytes = File.read!(@pades_lta_pdf)
      at = :binary.match(bytes, "(Alice)") |> elem(0)

      tampered =
        :binary.part(bytes, 0, at + 5) <>
          "f" <> :binary.part(bytes, at + 6, byte_size(bytes) - at - 6)

      assert byte_size(tampered) == byte_size(bytes)
      refute Signature.document_timestamp?(tampered)
    end

    test "does not come from the signatures the document lists" do
      doc = open!(@pades_lta_pdf)

      assert {:ok, [signature]} = Signature.list(doc)
      assert signature.sub_filter == :cades_detached
      assert Signature.document_timestamp?(File.read!(@pades_lta_pdf))
    end

    test "answers false rather than raising for bytes that are not a document" do
      refute Signature.document_timestamp?(<<>>)
      refute Signature.document_timestamp?("nothing here")
    end

    test "raises on bytes that are not a binary" do
      assert_raise FunctionClauseError, fn -> Signature.document_timestamp?(42) end
    end
  end

  describe "document_timestamp/1" do
    test "hands back the token an archived document carries" do
      assert {:ok, %Timestamp{} = timestamp} =
               Signature.document_timestamp(File.read!(@pades_lta_pdf))

      assert timestamp.hash_algorithm == :sha256
      assert %DateTime{} = timestamp.time
    end

    test "reaches a token that can then be verified" do
      timestamp = Signature.document_timestamp!(File.read!(@pades_lta_pdf))

      assert Timestamp.verify(timestamp) == {:ok, :valid}
    end

    test "keeps an unreadable document apart from one carrying no timestamp" do
      assert Signature.document_timestamp(File.read!(@pades_lt_pdf)) == {:ok, nil}
      assert Signature.document_timestamp(File.read!(@doctimestamp_decoy_pdf)) == {:ok, nil}
      assert Signature.document_timestamp(File.read!(@doctimestamp_unsigned_pdf)) == {:ok, nil}
      assert Signature.document_timestamp(File.read!(@doctimestamp_gapped_pdf)) == {:ok, nil}
      assert Signature.document_timestamp(File.read!(@doctimestamp_mistyped_pdf)) == {:ok, nil}

      assert {:error, %Error{}} = Signature.document_timestamp("nothing here")
    end

    test "document_timestamp!/1 unwraps or raises" do
      assert Signature.document_timestamp!(File.read!(@pades_lt_pdf)) == nil

      assert_raise Error, fn -> Signature.document_timestamp!("nothing here") end
    end

    test "raises on bytes that are not a binary" do
      assert_raise FunctionClauseError, fn -> Signature.document_timestamp(42) end
    end
  end

  describe "signing_time_utc/1" do
    setup do
      {:ok, [signature]} = Signature.list(open!(@cms_pdf))

      %{signature: signature}
    end

    test "parses the time the signer claimed", %{signature: signature} do
      assert {:ok, %DateTime{} = signed_at} = Signature.signing_time_utc(signature)

      assert signed_at.time_zone == "Etc/UTC"

      assert String.starts_with?(
               signature.signing_time,
               "D:" <> Calendar.strftime(signed_at, "%Y%m%d")
             )
    end

    test "answers nil for a signature claiming no time", %{signature: signature} do
      assert Signature.signing_time_utc(%{signature | signing_time: nil}) == {:ok, nil}
    end

    test "answers nil for a claim it cannot read", %{signature: signature} do
      assert Signature.signing_time_utc(%{signature | signing_time: "not a date"}) == {:ok, nil}
      assert Signature.signing_time_utc(%{signature | signing_time: ""}) == {:ok, nil}
    end

    test "answers nil rather than the date a bad claim is nearest to", %{signature: signature} do
      for claim <- [
            "D:20240231000000Z",
            "D:20240101990000Z",
            "D:20240101000000+99'00'",
            "D:2024AB",
            "D:20241301000000Z",
            "D:20240421126000Z",
            "D:20240421120060Z",
            "D:20230229000000Z"
          ] do
        assert Signature.signing_time_utc(%{signature | signing_time: claim}) == {:ok, nil}, claim
      end
    end

    test "keeps reading every shape the grammar allows", %{signature: signature} do
      read = fn claim ->
        {:ok, at} = Signature.signing_time_utc(%{signature | signing_time: claim})
        at
      end

      assert read.("D:20240421") == ~U[2024-04-21 00:00:00Z]
      assert read.("D:20240421120000Z") == ~U[2024-04-21 12:00:00Z]
      assert read.("D:20240421120000Z00'00'") == ~U[2024-04-21 12:00:00Z]
      assert read.("D:20240421140000+02'00'") == ~U[2024-04-21 12:00:00Z]
      assert read.("D:20240421140000+02") == ~U[2024-04-21 12:00:00Z]
      assert read.("D:20240421080000-04'00'") == ~U[2024-04-21 12:00:00Z]
      assert read.("D:20240229235959Z") == ~U[2024-02-29 23:59:59Z]
    end

    test "does not require the D: prefix", %{signature: signature} do
      assert {:ok, bare} =
               Signature.signing_time_utc(%{signature | signing_time: "20240102030405Z"})

      assert {:ok, prefixed} =
               Signature.signing_time_utc(%{signature | signing_time: "D:20240102030405Z"})

      assert bare == prefixed
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@cms_pdf)
      {:ok, [signature]} = Signature.list(doc)
      :ok = Document.close(doc)

      assert {:ok, %DateTime{}} = Signature.signing_time_utc(signature)
    end

    test "raises on a value the NIF cannot decode", %{signature: signature} do
      assert_raise ArgumentError, fn ->
        Signature.signing_time_utc(%{signature | signing_time: 42})
      end
    end

    test "signing_time_utc!/1 unwraps", %{signature: signature} do
      assert %DateTime{} = Signature.signing_time_utc!(signature)
      assert Signature.signing_time_utc!(%{signature | signing_time: nil}) == nil
    end
  end

  describe "dss/1" do
    test "reads every list a store carries" do
      assert {:ok, dss} = Signature.dss(open!(@dss_pdf))

      assert dss.certificates == ["DOC-CERT"]
      assert dss.crls == ["DOC-CRL"]
      assert dss.ocsp_responses == ["DOC-OCSP"]
      assert [vri] = dss.vri
      assert vri.certificates == ["VRI-CERT"]
      assert vri.crls == ["VRI-CRL"]
      assert vri.ocsp_responses == ["VRI-OCSP"]
      assert vri.timestamp == "D:20240102030405+02'00'"
    end

    # The fixture's /Certs names an object that is not in the file, and its /VRI
    # carries a /Type key that is not an entry. Both are stepped over rather than
    # failing the read, which is what makes a store readable at all.
    test "steps over an entry it cannot read" do
      assert {:ok, dss} = Signature.dss(open!(@dss_pdf))

      assert length(dss.certificates) == 1
      assert length(dss.vri) == 1
    end

    test "reads a store a signer wrote" do
      assert {:ok, dss} = Signature.dss(open!(@pades_lt_pdf))
      {:ok, [signature]} = Signature.list(open!(@pades_lt_pdf))

      assert [der] = dss.certificates
      assert {:OTPCertificate, _, _, _} = :public_key.pkix_decode_cert(der, :otp)
      assert DSS.vri_for(dss, signature)
    end

    test "answers nil for a document carrying no store" do
      assert Signature.dss(open!(@no_form_pdf)) == {:ok, nil}
      assert Signature.dss(open!(@pades_t_pdf)) == {:ok, nil}
    end

    # A /DSS that is present but yields nothing is indistinguishable from an
    # absent one here; dss/1 documents that rather than inventing a difference.
    test "answers nil for a store nothing could be read out of" do
      assert Signature.dss(open!(@dss_empty_pdf)) == {:ok, nil}
    end

    test "an editor reads the document it was opened from" do
      editor = Editor.open!(@dss_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert Signature.dss(editor) == Signature.dss(open!(@dss_pdf))
    end

    test "reports a closed handle" do
      doc = Document.open!(@dss_pdf)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Signature.dss(doc)
    end

    test "dss!/1 unwraps or raises" do
      assert %DSS{} = Signature.dss!(open!(@dss_pdf))
      assert Signature.dss!(open!(@no_form_pdf)) == nil

      doc = Document.open!(@dss_pdf)
      :ok = Document.close(doc)
      assert_raise Error, fn -> Signature.dss!(doc) end
    end
  end

  describe "DSS.vri_for/2" do
    setup do
      %{dss: Signature.dss!(open!(@dss_pdf))}
    end

    # The fixture's key is the SHA-1 of form_signature.pdf's <DEADBEEF> marker,
    # so the lookup can be shown comparing digests and nothing else: the store
    # and the signature come from different documents.
    test "finds the entry filed under the signature's digest", %{dss: dss} do
      {:ok, [marker]} = Signature.list(open!(@signature_pdf))
      assert marker.contents == @deadbeef

      assert %DSS.VRI{} = entry = DSS.vri_for(dss, marker)
      assert entry.signature_digest == Base.encode16(:crypto.hash(:sha, @deadbeef))
    end

    test "answers nil for a signature the store does not name", %{dss: dss} do
      {:ok, [other]} = Signature.list(open!(@cms_pdf))

      assert DSS.vri_for(dss, other) == nil
    end

    test "answers nil for a signature with no contents", %{dss: dss} do
      {:ok, [marker]} = Signature.list(open!(@signature_pdf))

      assert DSS.vri_for(dss, %{marker | contents: nil}) == nil
    end

    # The digest is over the padded /Contents, so a caller who trimmed the blob
    # themselves would look under a key no document writes.
    test "keys on the raw contents rather than the DER value inside them", %{dss: dss} do
      {:ok, [signature]} = Signature.list(open!(@pades_lt_pdf))
      lt = Signature.dss!(open!(@pades_lt_pdf))

      assert DSS.vri_for(lt, signature)

      assert DSS.vri_for(lt, %{signature | contents: binary_part(signature.contents, 0, 100)}) ==
               nil

      assert DSS.vri_for(dss, signature) == nil
    end
  end

  describe "inspecting a /VRI entry" do
    setup do
      %{dss: Signature.dss!(open!(@dss_pdf))}
    end

    test "shows the digest it was filed under", %{dss: dss} do
      assert [vri] = dss.vri

      assert inspect(vri) ==
               ~s(#PdfElixide.Signature.DSS.VRI<"#{vri.signature_digest}" 1c/1r/1o>)
    end

    # The digest is a PDF name key, whose #XX escapes decode to any byte, so a
    # document could otherwise write a newline or a terminal escape straight
    # into a log line.
    test "escapes a digest the document controls" do
      vri = %DSS.VRI{
        signature_digest: "SAFE\nINJECTED\e[31m",
        certificates: [],
        crls: [],
        ocsp_responses: [],
        timestamp: nil
      }

      rendered = inspect(vri)

      refute rendered =~ "\n"
      refute rendered =~ "\e"
      assert rendered =~ "SAFE"
      assert rendered =~ "INJECTED"
    end
  end

  describe "timestamp/1" do
    setup do
      {:ok, [b_b]} = Signature.list(open!(@pades_pdf))
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))

      %{b_b: b_b, b_t: b_t}
    end

    test "opens the token a B-T signature carries", %{b_t: b_t} do
      assert {:ok, %Timestamp{} = timestamp} = Signature.timestamp(b_t)

      assert timestamp.hash_algorithm == :sha256
      assert timestamp.tsa_name =~ "PdfElixide Test TSA"
      assert byte_size(timestamp.token) > 0
    end

    # Both blobs are real CMS that simply carries no timestamp attribute, which
    # is what makes nil a finding here rather than a failure to look — the
    # distinction the marker test below guards.
    test "answers nil for a signature carrying no timestamp", %{b_b: b_b} do
      assert Signature.timestamp(b_b) == {:ok, nil}

      {:ok, [pkcs7]} = Signature.list(open!(@cms_pdf))
      assert Signature.timestamp(pkcs7) == {:ok, nil}
    end

    # A damaged signature must not answer as an intact one carrying nothing, and
    # the same bytes must not mean two things depending on the way in.
    test "refuses a marker fixture's contents" do
      {:ok, [signature]} = Signature.list(open!(@signature_pdf))
      assert signature.contents == @deadbeef

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.timestamp(signature)
      assert {:error, %Error{reason: :invalid_pdf}} = Timestamp.parse(signature.contents)

      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.timestamp(%{signature | contents: <<>>})
    end

    # The B-LT fixture's attribute holds upstream's mock token rather than a real
    # one, which is the shape this must not report as "no timestamp".
    test "refuses an attribute holding something that is not a token" do
      {:ok, [b_lt]} = Signature.list(open!(@pades_lt_pdf))

      assert {:error, %Error{reason: :invalid_pdf}} = Signature.timestamp(b_lt)
    end

    test "reads a document timestamp's contents as the token itself" do
      {:ok, [signature]} = Signature.list(open!(@doctimestamp_pdf))

      assert signature.sub_filter == :rfc3161
      assert {:ok, %Timestamp{} = timestamp} = Signature.timestamp(signature)
      # The fixture pads its /Contents as a signer would; the token is shorter.
      assert byte_size(timestamp.token) < byte_size(signature.contents)
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@pades_t_pdf)
      {:ok, [signature]} = Signature.list(doc)
      Document.close(doc)

      assert {:ok, %Timestamp{}} = Signature.timestamp(signature)
    end

    test "refuses a signature carrying no contents", %{b_t: b_t} do
      assert {:error, %Error{reason: :invalid_pdf}} = Signature.timestamp(%{b_t | contents: nil})

      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.timestamp(%{b_t | sub_filter: :rfc3161, contents: nil})
    end

    test "raises on a value the NIF cannot decode", %{b_t: b_t} do
      assert_raise ArgumentError, fn -> Signature.timestamp(%{b_t | contents: 42}) end
    end

    test "timestamp!/1 unwraps or raises", %{b_b: b_b, b_t: b_t} do
      assert %Timestamp{} = Signature.timestamp!(b_t)
      assert Signature.timestamp!(b_b) == nil
      assert_raise Error, fn -> Signature.timestamp!(%{b_t | contents: nil}) end
    end
  end

  describe "verify_timestamp/2" do
    setup do
      %{
        signature: fn path -> open!(path) |> Signature.list!() |> hd() end,
        verify: fn path ->
          Signature.verify_timestamp(open!(path) |> Signature.list!() |> hd(), File.read!(path))
        end
      }
    end

    test "confirms a B-T token was made over the signature it sits beside", ctx do
      assert ctx.verify.(@pades_t_pdf) == {:ok, :valid}
      assert ctx.verify.(@pades_lta_pdf) == {:ok, :valid}
    end

    # The token is a real one the authority issued and `Timestamp.verify/1`
    # answers `:valid` for it; it was simply made over something else. Nothing
    # but this call separates the two.
    test "reports a B-T token made over something else", ctx do
      signature = ctx.signature.(@pades_t_mismatched_pdf)

      assert Timestamp.verify(Signature.timestamp!(signature)) == {:ok, :valid}
      assert ctx.verify.(@pades_t_mismatched_pdf) == {:ok, :invalid}
    end

    test "confirms a document timestamp was made over the bytes it covers", ctx do
      assert ctx.verify.(@doctimestamp_covering_pdf) == {:ok, :valid}
    end

    test "reports a document timestamp whose byte range covers nothing", ctx do
      assert ctx.verify.(@doctimestamp_pdf) == {:ok, :invalid}
    end

    test "does not read the bytes for a B-T signature", ctx do
      signature = ctx.signature.(@pades_t_pdf)

      assert Signature.verify_timestamp(signature, <<>>) == {:ok, :valid}
      assert Signature.verify_timestamp(signature, File.read!(@pades_t_pdf)) == {:ok, :valid}
    end

    test "refuses a signature carrying no timestamp", ctx do
      assert {:error, %Error{reason: :not_found}} = ctx.verify.(@cms_pdf)
    end

    # The retained 9-byte mock fails one step earlier, at the parse, so it can
    # never reach a verdict.
    test "refuses an attribute holding something that is not a token", ctx do
      assert {:error, %Error{reason: :invalid_pdf}} = ctx.verify.(@pades_lt_pdf)
    end

    test "refuses a signature carrying no contents", ctx do
      signature = ctx.signature.(@pades_t_pdf)

      assert {:error, %Error{reason: :invalid_pdf}} =
               Signature.verify_timestamp(%{signature | contents: nil}, <<>>)
    end

    test "keeps answering after the document is closed" do
      doc = Document.open!(@pades_t_pdf)
      {:ok, [signature]} = Signature.list(doc)
      :ok = Document.close(doc)

      assert Signature.verify_timestamp(signature, <<>>) == {:ok, :valid}
    end

    test "raises on bytes that are not a binary", ctx do
      signature = ctx.signature.(@pades_t_pdf)

      assert_raise FunctionClauseError, fn -> Signature.verify_timestamp(signature, 42) end
    end

    test "verify_timestamp!/2 unwraps or raises", ctx do
      signature = ctx.signature.(@pades_t_pdf)

      assert Signature.verify_timestamp!(signature, <<>>) == :valid

      assert_raise Error, fn ->
        Signature.verify_timestamp!(%{signature | contents: nil}, <<>>)
      end
    end
  end

  describe "Timestamp.parse/1" do
    setup do
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))
      {:ok, timestamp} = Signature.timestamp(b_t)

      %{timestamp: timestamp}
    end

    test "reports every field of the token", %{timestamp: timestamp} do
      assert {:ok, parsed} = Timestamp.parse(timestamp.token)

      assert parsed == timestamp
      assert %DateTime{} = parsed.time
      assert parsed.time.time_zone == "Etc/UTC"
      assert parsed.serial =~ ~r/\A[0-9A-F]+\z/
      assert parsed.policy_oid =~ ~r/\A[0-9.]+\z/
      assert parsed.hash_algorithm == :sha256
      # SHA-256, so the imprint the authority signed over is 32 bytes.
      assert byte_size(parsed.message_imprint) == 32
    end

    test "tolerates the padding a token stored in a PDF carries" do
      {:ok, [signature]} = Signature.list(open!(@doctimestamp_pdf))

      assert {:ok, parsed} = Timestamp.parse(signature.contents)
      assert byte_size(parsed.token) < byte_size(signature.contents)
    end

    test "refuses bytes that are not a token" do
      assert {:error, %Error{reason: :invalid_pdf}} = Timestamp.parse(@deadbeef)
      assert {:error, %Error{reason: :invalid_pdf}} = Timestamp.parse(<<>>)
    end

    test "raises on a value the NIF cannot decode" do
      assert_raise FunctionClauseError, fn -> Timestamp.parse(42) end
    end

    test "parse!/1 unwraps or raises", %{timestamp: timestamp} do
      assert %Timestamp{} = Timestamp.parse!(timestamp.token)
      assert_raise Error, fn -> Timestamp.parse!(@deadbeef) end
    end
  end

  describe "Timestamp.verify/1" do
    setup do
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))
      {:ok, timestamp} = Signature.timestamp(b_t)

      %{timestamp: timestamp}
    end

    test "confirms the authority signed the token", %{timestamp: timestamp} do
      assert Timestamp.verify(timestamp) == {:ok, :valid}
    end

    # Flipping a byte of the encapsulated TSTInfo leaves the token parseable and
    # the same length, so only the authority's signature over it can tell.
    test "reports a token altered after it was issued", %{timestamp: timestamp} do
      assert {:ok, altered} = Timestamp.parse(tamper(timestamp))

      assert Timestamp.verify(altered) == {:ok, :invalid}
    end

    test "refuses a token carrying no signature to check", %{timestamp: timestamp} do
      # A bare TSTInfo — what `parse/1` also accepts — has no outer SignedData.
      assert {:error, %Error{reason: :invalid_pdf}} =
               Timestamp.verify(%{timestamp | token: @bare_tst_info})
    end

    test "verify!/1 unwraps or raises", %{timestamp: timestamp} do
      assert Timestamp.verify!(timestamp) == :valid
      assert_raise Error, fn -> Timestamp.verify!(%{timestamp | token: @deadbeef}) end
    end
  end

  describe "inspecting a timestamp" do
    test "shows the time and the serial" do
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))
      {:ok, timestamp} = Signature.timestamp(b_t)

      assert inspect(timestamp) ==
               ~s(#PdfElixide.Signature.Timestamp<#{DateTime.to_iso8601(timestamp.time)}, ) <>
                 ~s("#{timestamp.serial}">)
    end

    # The serial is hex from the document, so nothing should be able to write a
    # terminal escape into a log line through it.
    test "escapes a serial the document controls" do
      {:ok, [b_t]} = Signature.list(open!(@pades_t_pdf))
      {:ok, timestamp} = Signature.timestamp(b_t)

      rendered = inspect(%{timestamp | serial: "SAFE\nINJECTED\e[31m"})

      refute rendered =~ "\n"
      refute rendered =~ "\e"
      assert rendered =~ "INJECTED"
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

    test "counts exactly what list/1 lists" do
      for path <- [
            @signature_pdf,
            @values_pdf,
            @signature_edge_pdf,
            @unsigned_pdf,
            @unnamed_pdf,
            @null_value_pdf,
            @form_pdf,
            @no_form_pdf
          ] do
        doc = open!(path)

        assert {:ok, signatures} = Signature.list(doc)
        assert Signature.count(doc) == {:ok, length(signatures)}
      end
    end

    test "refuses what list/1 refuses" do
      for path <- [@cyclic_pdf, @unreadable_pdf, @bad_value_pdf, @dangling_value_pdf] do
        doc = open!(path)

        assert {:error, %Error{reason: :invalid_pdf}} = Signature.count(doc)
        assert {:error, %Error{reason: :invalid_pdf}} = Signature.list(doc)
      end
    end

    test "reports a closed document" do
      doc = Document.open!(@signature_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Signature.count(doc)
    end

    test "reads from an editor" do
      editor = Editor.open!(@values_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, 2} = Signature.count(editor)
    end

    test "count!/1 returns the bare count" do
      assert Signature.count!(open!(@signature_pdf)) == 1
    end
  end
end
