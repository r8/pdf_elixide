defmodule PdfElixide.Document.Metadata do
  @moduledoc """
  Document Info dictionary metadata — a PDF's classic `/Info` fields.

  Every field is optional and defaults to `nil`; a document with no `/Info`
  dictionary yields a struct with all fields `nil`. Obtain it with
  `PdfElixide.Document.metadata/1`.

  For richer, XML-based metadata (which many modern PDFs carry instead of, or in
  addition to, the Info dictionary) see `PdfElixide.Document.xmp_metadata/1`.

  ## Fields

    * `:title`, `:author`, `:subject` — document title, author, and subject.
    * `:keywords` — the raw `/Keywords` string (PDF stores it as a single string;
      the split list, when available, is on the XMP `:subjects` field).
    * `:creator` — the application that created the original document.
    * `:producer` — the application that produced the PDF.
    * `:creation_date`, `:mod_date` — the raw PDF date strings (e.g.
      `"D:20230101120000+00'00'"`); not parsed into `DateTime`.
    * `:trapped` — the `/Trapped` value (`"True"`, `"False"`, or `"Unknown"`).
  """

  @enforce_keys [
    :title,
    :author,
    :subject,
    :keywords,
    :creator,
    :producer,
    :creation_date,
    :mod_date,
    :trapped
  ]

  defstruct [
    :title,
    :author,
    :subject,
    :keywords,
    :creator,
    :producer,
    :creation_date,
    :mod_date,
    :trapped
  ]

  @type t :: %__MODULE__{
          title: String.t() | nil,
          author: String.t() | nil,
          subject: String.t() | nil,
          keywords: String.t() | nil,
          creator: String.t() | nil,
          producer: String.t() | nil,
          creation_date: String.t() | nil,
          mod_date: String.t() | nil,
          trapped: String.t() | nil
        }

  @doc false
  # Builds a `Metadata` from the raw map returned by the NIF. Fields already
  # arrive in their final shape (a string or `nil`).
  @spec from_nif(map()) :: t()
  def from_nif(map) when is_map(map) do
    struct(__MODULE__, map)
  end
end
