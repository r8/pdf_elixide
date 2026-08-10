defmodule PdfElixide.Form.Field.Text do
  @moduledoc """
  A free-text field (`/FT /Tx`) — the one kind whose value a caller types.

  `:value` is the entered text, or `nil` when the field carries no `/V`. A `/V`
  written as a PDF name arrives as its bare string; see
  `t:PdfElixide.Form.Field.value/0` for what a malformed one can put here.

  See `PdfElixide.Form.Field` for how fields are named.
  """
  @enforce_keys [:name, :value]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          value: PdfElixide.Form.Field.value()
        }
end
