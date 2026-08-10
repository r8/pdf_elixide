defmodule PdfElixide.Form.Field.Choice do
  @moduledoc """
  A choice field (`/FT /Ch`) — list boxes and combo boxes.

  `:kind` says which of the two it is, read from the `/Ff` bit `:flags` decodes
  as `:combo`.

  The one kind whose value is *expected* to be a list, since only a list box can
  hold more than one selection at a time — and only one whose `:flags` carry
  `:multi_select`.

  `:value` is a single selection as a string (whether the PDF spells it as a
  text string or a name), several selections as a list of strings, or `nil`. See
  `t:PdfElixide.Form.Field.value/0` for what a malformed one can put here.
  """
  @enforce_keys [:name, :kind, :value, :flags]

  defstruct @enforce_keys

  @typedoc """
  Which kind of choice field it is.

  `:list_box` is the default: this is what a field declaring no `/Ff` combo bit
  is.
  """
  @type kind :: :combo_box | :list_box

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          value: PdfElixide.Form.Field.value(),
          flags: PdfElixide.Form.Field.Choice.Flags.t()
        }
end
