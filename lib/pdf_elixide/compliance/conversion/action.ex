defmodule PdfElixide.Compliance.Conversion.Action do
  @moduledoc """
  One change made by `PdfElixide.Compliance.convert/3`.

    * `:type` — what was done; see `t:type/0`.
    * `:description` — a human-readable account of the change.
    * `:fixed` — the code of the finding the change resolves, such as
      `"XMP-001"`, matching `PdfElixide.Compliance.Issue`'s `:code`. `nil` when
      the change resolves no single finding.
  """

  @typedoc """
  The kind of change.

    * `:added_xmp_metadata` — the document had no XMP metadata, and a packet
      declaring the requested level was added.
    * `:added_pdfa_identification` — the level was declared in the document's
      existing XMP metadata.
    * `:added_output_intent` — an output intent identified as sRGB was added,
      embedding an sRGB profile or the `:icc_profile` given to the conversion.
    * `:embedded_font` — a font the document names but does not carry was
      embedded from the fonts installed on the machine. Only with
      `embed_fonts: true`.
    * `:removed_javascript` — document JavaScript and JavaScript actions were
      removed.
    * `:removed_embedded_files` — the document's attached files were removed.
    * `:added_language` — the document's language was set to `en`, because a
      level `a` conversion requires one and the document declared none.
  """
  @type type ::
          :added_xmp_metadata
          | :added_pdfa_identification
          | :added_output_intent
          | :embedded_font
          | :removed_javascript
          | :removed_embedded_files
          | :added_language

  @enforce_keys [:type, :description, :fixed]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          type: type(),
          description: String.t(),
          fixed: String.t() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{kind: type, description: description, fixed: fixed}) do
    %__MODULE__{type: type, description: description, fixed: fixed}
  end
end
