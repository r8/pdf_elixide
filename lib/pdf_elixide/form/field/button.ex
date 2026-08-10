defmodule PdfElixide.Form.Field.Button do
  @moduledoc """
  A button field (`/FT /Btn`) — push buttons, check boxes and radio groups.

  `:value` is `true`/`false` for the conventional `/Yes`, `/On` and `/No`,
  `/Off` states, a custom on-state name (e.g. `/Export1`) as its bare string, or
  `nil` when the field carries no `/V`. See `t:PdfElixide.Form.Field.value/0` for
  what a malformed one can put here.

  `PdfElixide.Form.set_value/3` can write only `/Yes` and `/Off`, so writing a
  button's value back is not always faithful — see the "Check boxes and radio
  groups" section of `PdfElixide.Form` before round-tripping one.
  """
  @enforce_keys [:name, :value]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          value: PdfElixide.Form.Field.value()
        }
end
