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

  `:options` is what the field permits, in the order the PDF lists them, or
  `nil` when it declares none — each entry a `t:PdfElixide.Form.Field.option/0`,
  so `{"DE", "Germany"}` is one option and not two. It and `:alignment` are both
  inherited from a parent field, as `:flags` is; the "What a nested field
  inherits" section of the [Forms](guides/forms.md) guide says which keys are
  and which are not.

  See `PdfElixide.Form.Field` for how fields are named and what every struct
  carries, and the "What else a field reports" section of the
  [Forms](guides/forms.md) guide for working with the option list.
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
    :alignment,
    :options
  ]

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
          value: Field.value(),
          default_value: Field.value(),
          flags: PdfElixide.Form.Field.Choice.Flags.t(),
          tooltip: String.t() | nil,
          rect: Rect.t() | nil,
          alignment: Field.alignment(),
          options: [Field.option()] | nil
        }
end
