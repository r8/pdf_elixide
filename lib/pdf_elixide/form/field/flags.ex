defmodule PdfElixide.Form.Field.Flags do
  @moduledoc """
  The `/Ff` field flags every AcroForm field has, whatever its type
  (ISO 32000-1 §12.7.3.1, Table 226).

  Carried by `PdfElixide.Form.Field.Unknown`, which has no type and so no
  type-specific bits. The other three kinds carry a struct of their own —
  `PdfElixide.Form.Field.Text.Flags`, `PdfElixide.Form.Field.Button.Flags` and
  `PdfElixide.Form.Field.Choice.Flags` — each repeating these three alongside
  its own.

  ## Fields

    * `:read_only` — the field may not be changed by the user.
    * `:required` — the field must have a value when the form is submitted.
    * `:no_export` — the field is omitted from a submission.
    * `:raw` — the undecoded `/Ff` integer, for bits this struct does not name.

  See the "Field kinds and flags" section of the [Forms](guides/forms.md) guide.
  """

  @enforce_keys [:read_only, :required, :no_export, :raw]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          read_only: boolean(),
          required: boolean(),
          no_export: boolean(),
          raw: non_neg_integer()
        }
end
