defmodule PdfElixide.Form.Field.Button do
  @moduledoc """
  A button field (`/FT /Btn`) — push buttons, check boxes and radio groups.

  `:kind` says which of the three it is, read from the `/Ff` bits `:flags`
  decodes.

  `:value` is `true`/`false` for the conventional `/Yes`, `/On` and `/No`,
  `/Off` states, a custom on-state name (e.g. `/Export1`) as its bare string, or
  `nil` when the field carries no `/V`. See `t:PdfElixide.Form.Field.value/0` for
  what a malformed one can put here. A `:push` button holds no value at all.

  `PdfElixide.Form.put_value/3` can write only `/Yes` and `/Off`, so writing a
  button's value back is not always faithful — see the "Check boxes and radio
  groups" section of the [Forms](guides/forms.md) guide before round-tripping
  one.
  """
  @enforce_keys [:name, :kind, :value, :flags]

  defstruct @enforce_keys

  @typedoc """
  Which kind of button the field is.

    * `:check_box` — a single box, toggled on and off. The default: this is what
      a button declaring neither of the two bits below is.
    * `:radio` — a group of buttons of which at most one is selected.
    * `:push` — a button that holds no value and acts only through its actions.
  """
  @type kind :: :check_box | :radio | :push

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          value: PdfElixide.Form.Field.value(),
          flags: PdfElixide.Form.Field.Button.Flags.t()
        }
end
