defmodule PdfElixide.Document.EmbeddedFile do
  @moduledoc """
  One file attachment carried inside a PDF — an entry of the catalog's
  `/Names /EmbeddedFiles` name tree.

  Obtain the list with `PdfElixide.Document.embedded_files/1` or
  `PdfElixide.Editor.embedded_files/1`, and add one with
  `PdfElixide.Editor.embed_file/4`.

  ## Memory

  The bytes are on the struct rather than behind a handle, so a document with
  large attachments costs their full size on every call. Both listing functions
  decode every attachment together, so as the call returns the bytes exist twice
  — natively and as the binaries encoded from them.

  ## Fields

    * `:name` — the attachment's file name, from `/UF` if readable and `/F`
      otherwise. `"attachment"` when the entry names itself in neither.
    * `:data` — the decoded file contents.
    * `:description` — the entry's `/Desc`, or `nil`.
    * `:mime_type` — the media type the attachment declares (`"text/csv"`), or
      `nil`. See the "Attachments" section of `PdfElixide.Editor` for why an
      attachment this library writes declares none.
    * `:relationship` — how the attachment relates to the document, see
      `t:relationship/0`, or `nil` when the entry declares none or declares one
      outside that set.
    * `:size` — the size in bytes the entry *declares*, or `nil`. A producer
      writes it alongside the data rather than from it, so it can disagree with
      `byte_size(data)`; compare the two if that matters.
    * `:checksum` — the raw MD5 digest of the file contents the entry declares,
      or `nil`. Unverified, and MD5 is not a defence against deliberate
      tampering.
    * `:created`, `:modified` — the entry's declared timestamps, as raw PDF date
      strings (`"D:20260101120000+00'00'"`), or `nil`.
  """

  @typedoc """
  How an attachment relates to the document that carries it (PDF 2.0
  `/AFRelationship`).

  `:unspecified` is a declared absence of a relationship, which is not the same
  as the field being absent — that reads as `nil`.
  """
  @type relationship ::
          :source
          | :data
          | :alternative
          | :supplement
          | :encrypted_payload
          | :form_data
          | :schema
          | :unspecified

  @enforce_keys [
    :name,
    :data,
    :description,
    :mime_type,
    :relationship,
    :size,
    :checksum,
    :created,
    :modified
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          data: binary(),
          description: String.t() | nil,
          mime_type: String.t() | nil,
          relationship: relationship() | nil,
          size: non_neg_integer() | nil,
          checksum: binary() | nil,
          created: String.t() | nil,
          modified: String.t() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        name: name,
        data: data,
        description: description,
        mime_type: mime_type,
        relationship: relationship,
        size: size,
        checksum: checksum,
        created: created,
        modified: modified
      }) do
    %__MODULE__{
      name: name,
      data: data,
      description: description,
      mime_type: mime_type,
      relationship: relationship,
      size: size,
      checksum: checksum,
      created: created,
      modified: modified
    }
  end
end
