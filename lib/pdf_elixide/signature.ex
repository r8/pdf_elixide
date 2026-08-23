defmodule PdfElixide.Signature do
  @moduledoc """
  Digital signatures present in a PDF document.

  `list/1` reports what each signature in a document *claims* — who signed, when,
  why, and which bytes the signature covers. It reads from either source
  (`t:source/0`), a read-only `PdfElixide.Document` or a `PdfElixide.Editor`.
  `verify/2` checks one of those signatures against the bytes it covers.

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
      own claim, checked against no timestamp token.

  `:unknown` is the absence of a finding: the blob parsed, but the check could
  not run — a signature algorithm this library cannot verify, an unrecognized
  digest, no content digest to compare against, or a signature format whose
  signed content is something other than the bytes `:byte_range` covers. Treat
  it as unverified.

  Signature *fields* are a different thing from the signatures reported here: an
  unsigned field is a placeholder with no dictionary behind it, and is not
  listed. `PdfElixide.Form` omits signature fields entirely and refuses to write
  to one; the [Forms](guides/forms.md) guide explains why.

  Signature reads reject some damaged documents that form reads tolerate. The
  [Forms](guides/forms.md) guide describes those cases.

  Both sources take a *shared* read; `verify/2`, `verify_signer/1` and
  `certificate/1` take no handle at all, so they take no lock. See the
  [Concurrency](guides/concurrency.md) guide.
  """

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

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

  @enforce_keys [
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

  Signatures come back in document order. A document with no AcroForm, no
  signature fields, or only unsigned ones answers `{:ok, []}`.

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
  the comparison this makes would not be about them.

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

  This is the *first* X.509 certificate the blob carries, which for the usual
  single-certificate blob is the signer's. Nothing matches it against the signer
  the blob names, so where a whole chain is embedded the certificate you get
  back need not be the one that signed.

  Nothing about the certificate is checked; it is the material for a trust
  decision rather than a trust decision. See "What verification proves" in the
  module documentation.

  For an `:rfc3161` signature the blob is a timestamp token, so the certificate
  is the timestamp authority's rather than a document signer's.

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` when the signature has no
  `:contents`, when `:contents` is not a CMS blob, and when the blob carries no
  X.509 certificate.
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
  Counts the signatures in the given PDF document or editor.

  Answers `0` for a document with no signatures. This reads the signatures to
  count them, so prefer `list/1` when the details are wanted too.
  """
  @spec count(source()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def count(source) do
    with {:ok, signatures} <- list(source) do
      {:ok, length(signatures)}
    end
  end

  @doc """
  Same as `count/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec count!(source()) :: non_neg_integer()
  def count!(source), do: source |> count() |> Wrap.unwrap!()
end
