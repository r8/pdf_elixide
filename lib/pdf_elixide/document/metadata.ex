defmodule PdfElixide.Document.Metadata do
  @moduledoc """
  Document Info dictionary metadata — a PDF's classic `/Info` fields.

  Every field is optional and defaults to `nil`; a document with no `/Info`
  dictionary yields a struct with all fields `nil`. Obtain it with
  `PdfElixide.Document.metadata/1`.

  For richer, XML-based metadata (which many modern PDFs carry instead of, or in
  addition to, the Info dictionary) see `PdfElixide.Document.xmp_metadata/1`.

  ## Text encoding

  String fields are decoded as PDF text strings (ISO 32000-1 §7.9.2.2): a
  `FE FF` or `FF FE` byte-order mark selects UTF-16, PDF 2.0's `EF BB BF`
  selects UTF-8, and anything else is PDFDocEncoding — Latin-1 except over
  `0x80`–`0x9F`, where the PDF glyphs (`0x85` en dash, `0x90` right single
  quote, `0x92` trademark) replace the C1 controls.

  A byte-order-mark-less string that happens to be valid UTF-8 is decoded as
  UTF-8. That is `pdf_oxide`'s deliberate leniency towards the many producers
  that write raw UTF-8 rather than what the spec says, so a Latin-1 string
  whose bytes are also well-formed UTF-8 decodes as the latter. A value that
  decodes to whitespace only is `nil`, as an absent one is.

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

  defstruct @enforce_keys

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
  @spec from_nif(map()) :: t()
  def from_nif(%{
        title: title,
        author: author,
        subject: subject,
        keywords: keywords,
        creator: creator,
        producer: producer,
        creation_date: creation_date,
        mod_date: mod_date,
        trapped: trapped
      }) do
    %__MODULE__{
      title: title,
      author: author,
      subject: subject,
      keywords: keywords,
      creator: creator,
      producer: producer,
      creation_date: creation_date,
      mod_date: mod_date,
      trapped: trapped
    }
  end
end
