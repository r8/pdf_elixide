defmodule PdfElixide.Signature do
  @moduledoc """
  Digital signatures present in a PDF document.

  `list/1` reports what each signature in a document *claims* — who signed, when,
  why, and which bytes the signature covers. It reads from either source
  (`t:source/0`), a read-only `PdfElixide.Document` or a `PdfElixide.Editor`.

      {:ok, doc} = PdfElixide.Document.open("signed.pdf")
      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      signature.signer_name

  ## What this does not do

  Nothing here verifies anything, and nothing here reads the certificate. Every
  field comes from the signature dictionary alone, so a value is only as
  trustworthy as the document it came from: a forged `:signer_name` reads
  exactly like a genuine one, and a document altered after signing still lists
  its signature. Treat these as claims, not findings.

  The signer certificate, its issuer and its validity window are not reported:
  they live inside the signature blob rather than the dictionary. `:contents`
  carries that blob for callers who want to decode it themselves; `t:t/0` says
  what it includes.

  Whether a signature covers the whole file is likewise not a field. Use
  `covers_whole_document?/2`.

  Signature *fields* are a different thing from the signatures reported here: an
  unsigned field is a placeholder with no dictionary behind it, and is not
  listed. `PdfElixide.Form` omits signature fields entirely and refuses to write
  to one; the [Forms](guides/forms.md) guide explains why.

  Signature reads reject some damaged documents that form reads tolerate. The
  [Forms](guides/forms.md) guide describes those cases.

  Both sources take a *shared* read. See the
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
  """
  @type sub_filter :: :pkcs7_detached | :pkcs7_sha1 | :cades_detached | :rfc3161 | nil

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
    own claim rather than the subject of the signing certificate, which is not
    reported here.
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
    decoding it.
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

  None of the returned values are verified; see the module documentation.
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
  Whether the signature covers the whole of a file `size` bytes long.

  `true` means a structurally valid byte range starts at byte zero and ends at
  `size`. This checks coverage only; it does not verify the signature.

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
