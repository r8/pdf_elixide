defmodule PdfElixide.Form.Field.Text do
  @moduledoc """
  A free-text field (`/FT /Tx`) — the one kind whose value a caller types.

  `:kind` says whether the field holds one line or several, read from the `/Ff`
  bit `:flags` decodes as `:multiline`. The other bits a text field can carry —
  `:password`, `:comb`, `:rich_text` and the rest — are on
  `PdfElixide.Form.Field.Text.Flags`.

  `:value` is the entered text, or `nil` when the field carries no `/V`. A `/V`
  written as a PDF name arrives as its bare string; see
  `t:PdfElixide.Form.Field.value/0` for what a malformed one can put here.

  `:max_length` is the `/MaxLen` cap on how many characters may be entered,
  where `0` is a declared zero rather than an absence. `:alignment` says how the
  text is justified inside `:rect`. Both are inherited from a parent field, as
  `:flags` is; the "What a nested field inherits" section of the
  [Forms](guides/forms.md) guide says which keys are and which are not.

  See `PdfElixide.Form.Field` for how fields are named and what every struct
  carries.
  """
  alias PdfElixide.Form.Field
  alias PdfElixide.Geometry.Rect

  @enforce_keys [
    :name,
    :kind,
    :value,
    :default_value,
    :flags,
    :tooltip,
    :rect,
    :max_length,
    :alignment
  ]

  defstruct @enforce_keys

  @typedoc """
  Whether the field holds one line of text or several.

  `:single_line` is the default: this is what a field declaring no `/Ff`
  multiline bit is.
  """
  @type kind :: :single_line | :multiline

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          value: Field.value(),
          default_value: Field.value(),
          flags: PdfElixide.Form.Field.Text.Flags.t(),
          tooltip: String.t() | nil,
          rect: Rect.t() | nil,
          max_length: non_neg_integer() | nil,
          alignment: Field.alignment()
        }
end
