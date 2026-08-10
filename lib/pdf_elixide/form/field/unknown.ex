defmodule PdfElixide.Form.Field.Unknown do
  @moduledoc """
  A field with no recognized `/FT` — either a grouping parent that declares no
  type at all, or a field whose `/FT` names a type that is not understood.

  The only kind carrying a `:raw_type`, which tells the two apart, and the only
  one with no `:kind` — there is no type whose bits would say what it is.
  `:flags` is therefore `PdfElixide.Form.Field.Flags`, holding only the three
  bits every field has.

  `:value` is whatever the field's `/V` holds, or `nil`; a grouping parent has
  none. See `t:PdfElixide.Form.Field.value/0`.
  """
  @enforce_keys [:name, :raw_type, :value, :flags]

  defstruct @enforce_keys

  @typedoc """
  The `/FT` name as written when one exists but is unrecognized (e.g.
  `"Barcode"`); `nil` when the field declares no `/FT` at all.

  `%PdfElixide.Form.Field.Unknown{raw_type: nil, value: nil}` is the observable
  signature of a grouping parent — the field named `"person"` in a form whose
  leaves are `"person.first"` and `"person.last"`.
  """
  @type raw_type :: String.t() | nil

  @type t :: %__MODULE__{
          name: String.t(),
          raw_type: raw_type(),
          value: PdfElixide.Form.Field.value(),
          flags: PdfElixide.Form.Field.Flags.t()
        }
end
