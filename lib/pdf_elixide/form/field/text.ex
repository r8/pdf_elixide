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

  See `PdfElixide.Form.Field` for how fields are named.
  """
  @enforce_keys [:name, :kind, :value, :flags]

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
          value: PdfElixide.Form.Field.value(),
          flags: PdfElixide.Form.Field.Text.Flags.t()
        }
end
