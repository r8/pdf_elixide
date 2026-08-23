defmodule PdfElixide.Signature do
  @moduledoc """
  Digital signatures present in a PDF document.

  `list/1` reports what each signature in a document *claims* — who signed, when,
  why, which bytes the signature covers, and which field it sits in. It reads
  from either source (`t:source/0`), a read-only `PdfElixide.Document` or a
  `PdfElixide.Editor`. `unsigned_fields/1` reports the signature fields still
  waiting for a signature, so the two together account for every one a form has.
  `verify/2` checks one of those signatures against the bytes it covers,
  `pades_level/2` says what kind of signature it is, `timestamp/1` opens the
  timestamp one carries, `signing_time_utc/1` parses the time one claims, and
  `dss/1` reads the material the document carries for validating them later.

      {:ok, doc} = PdfElixide.Document.open("signed.pdf")
      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      signature.signer_name

  ## What `list/1` reports are claims

  Nothing `list/1` returns is checked, and none of it is read from the
  certificate. Every field comes from the signature dictionary alone, so a
  value is only as trustworthy as the document it came from: a forged
  `:signer_name` reads exactly like a genuine one, and a document altered after
  signing still lists its signature. Treat these as claims, not findings;
  `verify/2` is what turns one into a finding.

  The certificate's own subject, issuer and validity window are not fields
  here: they live in the certificate inside the signature blob rather than in
  the dictionary. `certificate/1` hands that certificate back as DER for
  `:public_key` to decode, and `:contents` carries the whole blob; `t:t/0` says
  what it includes.

  Whether a signature covers the whole file is likewise not a field. Use
  `covers_whole_document?/2`.

  ## What verification proves

  `verify/2` answers about the bytes `:byte_range` covers, and about nothing
  else. `{:ok, :valid}` means the signed attributes carry an authentic signature
  from the certificate embedded in the blob, and the content digest those
  attributes carry matches those covered bytes. Three claims it deliberately
  does not make:

    * **That the file is intact.** A byte range need not reach the end of the
      file, and whatever lies outside it — an appended incremental update, a
      revision added after signing — is not covered and cannot be.
      `covers_whole_document?/2` answers that half.
    * **That the signer is who the certificate says.** No trust decision is
      made: the certificate is not chained to any root, not checked against a
      revocation list, and its validity dates are compared to nothing. An
      expired or self-signed certificate verifies exactly like a trusted one.
      `certificate/1` is how you reach the certificate to decide for yourself.
    * **That the claimed signing time is true.** `:signing_time` is the signer's
      own claim, and verification compares it to nothing. Where a signature
      carries a timestamp, `timestamp/1` reaches a third party's account of when
      the signature existed, which is the thing to weigh it against.

  `:unknown` is the absence of a finding: the blob parsed, but the check could
  not run — a signature algorithm this library cannot verify, an unrecognized
  digest, no content digest to compare against, or a signature format whose
  signed content is something other than the bytes `:byte_range` covers. Treat
  it as unverified.

  Deciding whether to *trust* a verified signature needs more than the signature:
  the certificate chain, revocation lists and OCSP responses that were current
  when it was signed. A document built for long-term validation carries them,
  and `dss/1` is what reads them; `PdfElixide.Signature.DSS` says what they are
  and what is — and is not — done with them.

  Signature *fields* are a different thing from the signatures reported here: an
  unsigned field is a placeholder with no dictionary behind it, so `list/1` has
  nothing to report for one and `unsigned_fields/1` names it instead.
  `PdfElixide.Form` omits signature fields entirely, signed or not, and refuses
  to write to one; the [Forms](guides/forms.md) guide explains why.

  Signature reads reject some damaged documents that form reads tolerate. The
  [Forms](guides/forms.md) guide describes those cases.

  Signatures are read here and never produced: nothing in this library signs a
  document. The [Forms](guides/forms.md) guide says why, and what to do instead.

  `list/1`, `unsigned_fields/1`, `count/1` and `dss/1` take a *shared* read on
  either source;
  `verify/2`, `verify_signer/1`, `certificate/1`, `timestamp/1`,
  `signing_time_utc/1`, `document_timestamp?/1` and every arity of `pades_level`
  take no handle at all, so they take no lock. See the
  [Concurrency](guides/concurrency.md) guide.
  """

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap
  alias PdfElixide.Signature.DSS
  alias PdfElixide.Signature.Timestamp

  @type source :: Document.t() | Editor.t()

  @typedoc """
  The signature format, from the dictionary's `/SubFilter`.

  `nil` covers two cases that cannot be told apart here: no `/SubFilter` at all,
  and one naming a format this library does not recognize.

  Two of these sign something other than the bytes `:byte_range` covers, so
  `verify/2` cannot check them and says so rather than guessing.
  """
  @type sub_filter :: :pkcs7_detached | :pkcs7_sha1 | :cades_detached | :rfc3161 | nil

  @encapsulated [:pkcs7_sha1, :rfc3161]

  @typedoc """
  What a verification call concluded. "What verification proves" in the module
  documentation says what each one does and does not establish.
  """
  @type verdict :: :valid | :invalid | :unknown

  @typedoc """
  The PAdES baseline level a signature reaches. Each value below names the
  arity that can report it.

    * `:b_b` — a CAdES baseline signature.
    * `:b_t` — `:b_b` and the unsigned attribute that carries an RFC 3161
      timestamp token, present beside the signature. The level reports its
      presence and nothing more; `timestamp/1` opens it.
    * `:b_lt` — `:b_t` and an entry filed under this signature in the document's
      security store: the entry's presence, whatever it holds. Reported by
      `pades_level/2` and `pades_level/3`, having been given that store;
      `pades_level/1` answers `:b_t` for the same signature.
    * `:b_lta` — `:b_lt` and an archival timestamp over the whole file. Only
      `pades_level/3` reports it, having been given the document's bytes;
      `pades_level/1` and `pades_level/2` answer `:b_lt` for the same signature.
      See `document_timestamp?/1` for how loosely that timestamp is detected.
    * `nil` — not a PAdES signature at all. The levels are defined for
      `:cades_detached` and describe nothing else.

  These levels are structural, not verification results. A damaged signature
  whose timestamp cannot be found still reaches `:b_b`, a `:b_lt` store entry
  may itself be empty, and a `:b_lta` archival timestamp is neither read nor
  checked against the signature it is supposed to cover.
  """
  @type pades_level :: :b_b | :b_t | :b_lt | :b_lta | nil

  @enforce_keys [
    :field_name,
    :signer_name,
    :signing_time,
    :reason,
    :location,
    :contact_info,
    :sub_filter,
    :byte_range,
    :contents
  ]

  defstruct @enforce_keys

  @typedoc """
  One signature dictionary.

  Every field is optional, because a signature dictionary need only carry
  `/ByteRange` and `/Contents`.

  * `:field_name` — the full dotted name of the field this signature sits in,
    such as `"applicant.signature"`. It is `nil` when a malformed form leaves
    the field unnamed or writes it directly into the form rather than by
    reference; the signature is still reported.
  * `:signer_name` — the name the signer claimed (`/Name`). It is the signer's
    own claim rather than the subject of the certificate the signature carries;
    `certificate/1` is what reaches that.
  * `:signing_time` — the claimed signing time (`/M`), as a raw PDF date string
    such as `"D:20230101120000+00'00'"`. Not parsed into a `DateTime`, matching
    `PdfElixide.Document.Metadata`.
  * `:reason`, `:location`, `:contact_info` — free text supplied by the signer.
  * `:byte_range` — the byte offsets and lengths the signature covers, as
    `[start, length, start, length]`: everything except the hole holding
    `:contents` itself. Normally four integers, but a malformed document can
    produce any number, so match on it rather than assuming. Pass it to
    `covers_whole_document?/2` to find out whether content was appended after
    signing.
  * `:contents` — the raw signature blob (`/Contents`), typically a few
    kilobytes per signature and held in memory for as long as the struct is.
    This is the whole of what the document reserved for it: a signer normally
    asks for more room than the CMS value needs and pads the remainder with
    zero bytes, so the DER value is followed by trailing padding a strict
    decoder will reject. Bound it by that value's own encoded length before
    decoding it — which `verify/2`, `verify_signer/1` and `certificate/1`
    already do.
  """
  @type t :: %__MODULE__{
          field_name: String.t() | nil,
          signer_name: String.t() | nil,
          signing_time: String.t() | nil,
          reason: String.t() | nil,
          location: String.t() | nil,
          contact_info: String.t() | nil,
          sub_filter: sub_filter(),
          byte_range: [integer()],
          contents: binary() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        field_name: field_name,
        signer_name: signer_name,
        signing_time: signing_time,
        reason: reason,
        location: location,
        contact_info: contact_info,
        sub_filter: sub_filter,
        byte_range: byte_range,
        contents: contents
      }) do
    %__MODULE__{
      field_name: field_name,
      signer_name: signer_name,
      signing_time: signing_time,
      reason: reason,
      location: location,
      contact_info: contact_info,
      sub_filter: sub_filter,
      byte_range: byte_range,
      contents: contents
    }
  end

  @doc """
  Lists the signatures in the given PDF document or editor.

  Signatures come back in document order, each naming the field it sits in. A
  document with no AcroForm, no signature fields, or only unsigned ones answers
  `{:ok, []}`; `unsigned_fields/1` is what reports the last of those.

  Reading from an editor reads the document as it was opened.

  These are the signer's claims rather than findings; `verify/2` is what checks
  one against the bytes it covers.
  """
  @spec list(source()) :: {:ok, [t()]} | {:error, Error.t()}
  def list(%Document{ref: ref}) do
    with {:ok, signatures} <- Wrap.call(fn -> Native.document_signatures(ref) end) do
      {:ok, Enum.map(signatures, &from_nif/1)}
    end
  end

  def list(%Editor{ref: ref}) do
    with {:ok, signatures} <- Wrap.call(fn -> Native.editor_signatures(ref) end) do
      {:ok, Enum.map(signatures, &from_nif/1)}
    end
  end

  @doc """
  Same as `list/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec list!(source()) :: [t()]
  def list!(source), do: source |> list() |> Wrap.unwrap!()

  @doc """
  Lists the signature fields that carry no signature — the places left to sign.

      {:ok, doc} = PdfElixide.Document.open("half_signed.pdf")
      PdfElixide.Signature.unsigned_fields(doc)
      #=> {:ok, ["witness.signature"]}

  Names are the full dotted ones `list/1` reports in `:field_name`, in document
  order. On a well-formed form, the two calls account for every named place to
  sign; a cleared value counts as unsigned.

  Grouping and unnamed fields are omitted, as are fields holding something
  other than a signature dictionary. The [Forms](guides/forms.md) guide covers
  malformed fields and the damaged hierarchies this call refuses.

  Reading from an editor reads the document as it was opened; nothing this
  library does adds or fills a signature field.
  """
  @spec unsigned_fields(source()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def unsigned_fields(%Document{ref: ref}) do
    Wrap.call(fn -> Native.document_unsigned_signature_fields(ref) end)
  end

  def unsigned_fields(%Editor{ref: ref}) do
    Wrap.call(fn -> Native.editor_unsigned_signature_fields(ref) end)
  end

  @doc """
  Same as `unsigned_fields/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec unsigned_fields!(source()) :: [String.t()]
  def unsigned_fields!(source), do: source |> unsigned_fields() |> Wrap.unwrap!()

  @doc """
  Reads the document security store, the material a document carries for
  validating its own signatures later.

      {:ok, doc} = PdfElixide.Document.open("signed.pdf")
      {:ok, dss} = PdfElixide.Signature.dss(doc)
      length(dss.certificates)
      #=> 1

  Returns `{:ok, %PdfElixide.Signature.DSS{}}` for a document carrying a store,
  or `{:ok, nil}` for one that does not. Reading from an editor reads the
  document as it was opened.

  `{:ok, nil}` is also the answer for a document whose store is *there* but
  yields nothing — every entry unreadable, or the whole `/DSS` a reference to an
  object that is not in the file. The two cannot be told apart here, so treat
  `nil` as "no material reached me" rather than as "this document carries none".

  Nothing in the store is validated, and its presence proves nothing about the
  signatures beside it. `PdfElixide.Signature.DSS` says what that means and how
  to decode a blob.
  """
  @spec dss(source()) :: {:ok, DSS.t() | nil} | {:error, Error.t()}
  def dss(%Document{ref: ref}) do
    with {:ok, store} <- Wrap.call(fn -> Native.document_dss(ref) end) do
      {:ok, store && DSS.from_nif(store)}
    end
  end

  def dss(%Editor{ref: ref}) do
    with {:ok, store} <- Wrap.call(fn -> Native.editor_dss(ref) end) do
      {:ok, store && DSS.from_nif(store)}
    end
  end

  @doc """
  Same as `dss/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec dss!(source()) :: DSS.t() | nil
  def dss!(source), do: source |> dss() |> Wrap.unwrap!()

  @doc """
  Verifies the signature against the bytes it covers.

  `pdf_bytes` must be the exact bytes of the file the signature came from —
  `File.read!/1` for a document opened from a path, or the binary given to
  `PdfElixide.Document.from_binary/2`. A handle does not carry them.

      doc = PdfElixide.Document.open!("signed.pdf")
      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      PdfElixide.Signature.verify(signature, File.read!("signed.pdf"))
      #=> {:ok, :valid}

  The verdict covers the range in `:byte_range` and nothing else, so
  `{:ok, :valid}` is not "this file is unchanged": pair it with
  `covers_whole_document?/2`. See "What verification proves" in the module
  documentation.

  A `:pkcs7_sha1` or `:rfc3161` signature answers `{:ok, :unknown}` without being
  checked: both sign content held inside the blob rather than the byte range, so
  the comparison this makes would not be about them. An `:rfc3161` signature is
  a document timestamp, and `timestamp/1` is what reads and checks one.

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` rather than a verdict when
  the signature has no `:contents`, its `:byte_range` is not four non-negative
  integers, that range reaches past `pdf_bytes`, or `:contents` is not a CMS
  blob.
  """
  @spec verify(t(), binary()) :: {:ok, verdict()} | {:error, Error.t()}
  # These two carry the bytes they sign inside the CMS blob, so its digest covers
  # that content rather than the byte range. Checking it against the range would
  # report a sound signature as an altered document.
  def verify(%__MODULE__{sub_filter: sub_filter}, pdf_bytes)
      when is_binary(pdf_bytes) and sub_filter in @encapsulated,
      do: {:ok, :unknown}

  def verify(%__MODULE__{contents: contents, byte_range: byte_range}, pdf_bytes)
      when is_binary(pdf_bytes) do
    Wrap.call(fn -> Native.signature_verify_detached(contents, byte_range, pdf_bytes) end)
  end

  @doc """
  Same as `verify/2`, but raises `PdfElixide.Error` on failure.
  """
  @spec verify!(t(), binary()) :: verdict()
  def verify!(signature, pdf_bytes), do: signature |> verify(pdf_bytes) |> Wrap.unwrap!()

  @doc """
  Verifies the signature blob on its own, without the document.

  This checks that the signed attributes inside `:contents` carry an authentic
  signature from the certificate embedded beside them. It does not compare the
  content digest those attributes carry against any document, so a file altered
  after signing answers `{:ok, :valid}` here while `verify/2` answers
  `{:ok, :invalid}` for the same signature.

  It is meaningful for every `t:sub_filter/0`, including the two `verify/2`
  declines to check. Prefer `verify/2` when the covered bytes are available.
  Neither function makes a trust claim about the certificate; see "What
  verification proves" in the module documentation.
  """
  @spec verify_signer(t()) :: {:ok, verdict()} | {:error, Error.t()}
  def verify_signer(%__MODULE__{contents: contents}) do
    Wrap.call(fn -> Native.signature_verify_signer(contents) end)
  end

  @doc """
  Same as `verify_signer/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec verify_signer!(t()) :: verdict()
  def verify_signer!(signature), do: signature |> verify_signer() |> Wrap.unwrap!()

  @doc """
  The certificate embedded in the signature blob, as DER-encoded X.509 bytes.

  Decode it with OTP's `:public_key` to reach the subject, the issuer, the
  serial and the validity window:

      {:ok, der} = PdfElixide.Signature.certificate(signature)
      :public_key.pkix_decode_cert(der, :otp)

  This is the certificate selected for `verify/2` and `verify_signer/1`. For an
  embedded chain, it matches the signer's issuer and serial number; signatures
  using another identifier fall back to the first certificate.

  Nothing about the certificate is checked; it is the material for a trust
  decision rather than a trust decision. See "What verification proves" in the
  module documentation.

  For an `:rfc3161` signature the blob is a timestamp token, so the certificate
  is the timestamp authority's rather than a document signer's.

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` when the signature has no
  `:contents`, when `:contents` is not a CMS blob, when the blob names no signer
  at all, and when it carries no X.509 certificate.
  """
  @spec certificate(t()) :: {:ok, binary()} | {:error, Error.t()}
  def certificate(%__MODULE__{contents: contents}) do
    Wrap.call(fn -> Native.signature_certificate(contents) end)
  end

  @doc """
  Same as `certificate/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec certificate!(t()) :: binary()
  def certificate!(signature), do: signature |> certificate() |> Wrap.unwrap!()

  @doc """
  The RFC 3161 timestamp the signature carries, or `nil` when it carries none.

  A PAdES B-T signature holds a timestamp token beside the signature, in the
  CMS unsigned attributes; a `:rfc3161` signature — a document timestamp — *is*
  one. Both arrive here as a `PdfElixide.Signature.Timestamp`, which is where
  the token's fields, and what verifying it does and does not prove, are
  described.

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      {:ok, timestamp} = PdfElixide.Signature.timestamp(signature)
      timestamp.time
      #=> ~U[2026-08-23 07:50:03Z]

  `{:ok, nil}` means the signature was read and carries no timestamp attribute,
  which is the ordinary shape for `pades_level/1`'s `:b_b`. It is never the
  answer for a signature that could not be read: a document claiming a timestamp
  it cannot produce, or a signature blob that is damaged beyond recognition, is
  not a document without one, and reporting `nil` for either would let a broken
  file pass as an intact one carrying nothing.

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` when the signature has no
  `:contents`, when `:contents` is not a CMS blob, and when the timestamp
  attribute is present but holds no token or one that will not parse.
  """
  @spec timestamp(t()) :: {:ok, Timestamp.t() | nil} | {:error, Error.t()}
  # A document timestamp signs a `TSTInfo` rather than the byte range, so its
  # `/Contents` is the token itself rather than a blob carrying one.
  def timestamp(%__MODULE__{sub_filter: :rfc3161, contents: contents})
      when is_binary(contents),
      do: Timestamp.parse(contents)

  def timestamp(%__MODULE__{contents: contents}) do
    with {:ok, timestamp} <- Wrap.call(fn -> Native.signature_timestamp(contents) end) do
      {:ok, timestamp && Timestamp.from_nif(timestamp)}
    end
  end

  @doc """
  Same as `timestamp/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec timestamp!(t()) :: Timestamp.t() | nil
  def timestamp!(signature), do: signature |> timestamp() |> Wrap.unwrap!()

  @doc """
  The PAdES baseline level the signature reaches, judged from the signature
  alone.

  Same as `pades_level/2` with no security store, and capped at `:b_t` for that
  reason — see there for what each answer means. Reach for the two-argument form
  when the document is at hand and `:b_lt` matters.

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      PdfElixide.Signature.pades_level(signature)
      #=> {:ok, :b_t}
  """
  @spec pades_level(t()) :: {:ok, pades_level()} | {:error, Error.t()}
  def pades_level(%__MODULE__{} = signature), do: pades_level(signature, nil)

  @doc """
  Same as `pades_level/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec pades_level!(t()) :: pades_level()
  def pades_level!(signature), do: signature |> pades_level() |> Wrap.unwrap!()

  @doc """
  The PAdES baseline level the signature reaches, given the document's security
  store.

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      {:ok, dss} = PdfElixide.Signature.dss(doc)
      PdfElixide.Signature.pades_level(signature, dss)
      #=> {:ok, :b_lt}

  `:b_t` means the unsigned attribute that carries an RFC 3161 timestamp token
  is present beside the signature value; `:b_b` means it is not. `:b_lt` adds
  that `dss` carries an entry filed under this signature, which is where the
  material for judging it after its certificates expire would be kept.

  Pass `nil` for `dss` — what `pades_level/1` does — when there is no store, or
  when the distinction does not matter.

  Capped at `:b_lt`: reach for `pades_level/3` when the document's bytes are at
  hand and `:b_lta` matters.

  Nothing here is verified. See `t:pades_level/0` for the exact meaning and
  limitations of each answer, `timestamp/1` to read and verify the timestamp,
  and `PdfElixide.Signature.DSS` for the store material.

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` when a `:cades_detached`
  signature carries no `:contents`.
  """
  @spec pades_level(t(), DSS.t() | nil) :: {:ok, pades_level()} | {:error, Error.t()}
  def pades_level(signature, dss)

  def pades_level(%__MODULE__{sub_filter: :cades_detached, contents: contents}, dss)
      when is_nil(dss) or is_struct(dss, DSS) do
    Wrap.call(fn -> Native.signature_pades_level(contents, dss) end)
  end

  # The `:cades_detached` gate belongs in the head: it is what makes a non-PAdES
  # signature carrying no `:contents` answer `nil` rather than fail.
  def pades_level(%__MODULE__{}, dss) when is_nil(dss) or is_struct(dss, DSS), do: {:ok, nil}

  @doc """
  Same as `pades_level/2`, but raises `PdfElixide.Error` on failure.
  """
  @spec pades_level!(t(), DSS.t() | nil) :: pades_level()
  def pades_level!(signature, dss), do: signature |> pades_level(dss) |> Wrap.unwrap!()

  @doc """
  The PAdES baseline level the signature reaches, given the document's security
  store and the document's own bytes.

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      {:ok, dss} = PdfElixide.Signature.dss(doc)
      PdfElixide.Signature.pades_level(signature, dss, File.read!("signed.pdf"))
      #=> {:ok, :b_lta}

  Same as `pades_level/2`, but reports `:b_lta` when a `:b_lt` signature's
  document carries an archival timestamp.

  `pdf_bytes` must be the bytes from which the signature was read. Timestamp
  detection is structural and does not verify the timestamp; see
  `document_timestamp?/1` and `t:pades_level/0`.
  """
  @spec pades_level(t(), DSS.t() | nil, binary()) :: {:ok, pades_level()} | {:error, Error.t()}
  def pades_level(%__MODULE__{} = signature, dss, pdf_bytes) when is_binary(pdf_bytes) do
    with {:ok, level} <- pades_level(signature, dss) do
      {:ok, if(level == :b_lt and document_timestamp?(pdf_bytes), do: :b_lta, else: level)}
    end
  end

  @doc """
  Same as `pades_level/3`, but raises `PdfElixide.Error` on failure.
  """
  @spec pades_level!(t(), DSS.t() | nil, binary()) :: pades_level()
  def pades_level!(signature, dss, pdf_bytes),
    do: signature |> pades_level(dss, pdf_bytes) |> Wrap.unwrap!()

  @doc """
  Whether the document carries an archival timestamp over the whole file.

      PdfElixide.Signature.document_timestamp?(File.read!("archived.pdf"))
      #=> true

  This scans the raw bytes for `/DocTimeStamp` and `/ETSI.RFC3161`; it does not
  parse or verify a timestamp, relate the markers to one object, or check what
  it covers. Treat `true` only as evidence that the file has the shape of an
  archived document. `pades_level/3` uses this result for the `:b_lta` level.
  """
  @spec document_timestamp?(binary()) :: boolean()
  def document_timestamp?(pdf_bytes) when is_binary(pdf_bytes) do
    Wrap.call!(fn -> Native.signature_has_document_timestamp(pdf_bytes) end)
  end

  @doc """
  Whether the signature covers the whole of a file `size` bytes long.

  `true` means a structurally valid byte range starts at byte zero and ends at
  `size`. This checks coverage only; `verify/2` checks the signature, and
  answers only about the range this reports on.

  The size has to come from you: a document handle does not carry the length of
  the bytes behind it.

      size = File.stat!("signed.pdf").size
      PdfElixide.Signature.covers_whole_document?(signature, size)
      #=> true

  `false` can mean content was appended after signing, the file was truncated,
  `size` is wrong, or `:byte_range` is malformed. Malformed ranges answer
  `false` rather than raising.
  """
  @spec covers_whole_document?(t(), non_neg_integer()) :: boolean()
  def covers_whole_document?(signature, size)

  # Reject overlapping ranges; explicit integer guards avoid Erlang term
  # ordering making values such as `"x" >= 0` true.
  def covers_whole_document?(%__MODULE__{byte_range: [0, first_length, start, length]}, size)
      when is_integer(size) and size >= 0 and
             is_integer(first_length) and is_integer(start) and is_integer(length) and
             first_length >= 0 and length >= 0 and start >= first_length,
      do: start + length == size

  def covers_whole_document?(%__MODULE__{}, size) when is_integer(size) and size >= 0,
    do: false

  @doc """
  The claimed signing time as a `DateTime`, or `nil` when there is none to read.

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      PdfElixide.Signature.signing_time_utc(signature)
      #=> {:ok, ~U[2026-08-23 07:50:03Z]}

  This parses `:signing_time`, applies its UTC offset, and returns the resulting
  instant in UTC. `{:ok, nil}` means the claim is absent, unreadable, invalid, or
  outside `DateTime`'s range; inspect `:signing_time` to distinguish absence.

  Like `:signing_time` itself, this is the signer's own claim and is compared to
  nothing. `timestamp/1` reaches a third party's account of when the signature
  existed, which is the thing to weigh it against.
  """
  @spec signing_time_utc(t()) :: {:ok, DateTime.t() | nil} | {:error, Error.t()}
  def signing_time_utc(%__MODULE__{signing_time: signing_time}) do
    with {:ok, seconds} <- Wrap.call(fn -> Native.signature_signing_time(signing_time) end) do
      {:ok, seconds && DateTime.from_unix!(seconds)}
    end
  end

  @doc """
  Same as `signing_time_utc/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec signing_time_utc!(t()) :: DateTime.t() | nil
  def signing_time_utc!(signature), do: signature |> signing_time_utc() |> Wrap.unwrap!()

  @doc """
  Counts the signatures in the given PDF document or editor.

  Answers `0` for a document with no signatures and counts exactly what
  `list/1` lists, without materializing the signature metadata. Use `list/1`
  when those details are needed too.
  """
  @spec count(source()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def count(%Document{ref: ref}) do
    Wrap.call(fn -> Native.document_signature_count(ref) end)
  end

  def count(%Editor{ref: ref}) do
    Wrap.call(fn -> Native.editor_signature_count(ref) end)
  end

  @doc """
  Same as `count/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec count!(source()) :: non_neg_integer()
  def count!(source), do: source |> count() |> Wrap.unwrap!()
end
