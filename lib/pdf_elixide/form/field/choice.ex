defmodule PdfElixide.Form.Field.Choice do
  @moduledoc """
  A choice field (`/FT /Ch`) — list boxes and combo boxes.

  The one kind whose value is *expected* to be a list, since only a list box can
  hold more than one selection at a time.

  `:value` is a single selection as a string (whether the PDF spells it as a
  text string or a name), several selections as a list of strings, or `nil`. See
  `t:PdfElixide.Form.Field.value/0` for what a malformed one can put here.
  """
  @enforce_keys [:name, :value]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          value: PdfElixide.Form.Field.value()
        }
end
