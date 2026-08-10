defmodule PdfElixide.Form.Field do
  @moduledoc """
  A single AcroForm field, one struct per field type this API covers:

    * `PdfElixide.Form.Field.Text` — free-text entry (`/Tx`).
    * `PdfElixide.Form.Field.Button` — push buttons, check boxes and radio
      groups (`/Btn`).
    * `PdfElixide.Form.Field.Choice` — list boxes and combo boxes (`/Ch`).
    * `PdfElixide.Form.Field.Unknown` — no recognized `/FT`, including the
      grouping parents a nested form reports.

  Obtained from `PdfElixide.Form.fields/1`, or one at a time from
  `PdfElixide.Form.field/2`.

  Every struct carries `:name` — the fully qualified, dotted name
  (`"person.first"`, not `"first"`) that `PdfElixide.Form.field/2`,
  `PdfElixide.Form.value/2` and `PdfElixide.Form.set_value/3` address it by,
  identical whether the form was read from a `PdfElixide.Document` or a
  `PdfElixide.Editor` — and `:value`, a plain term (`t:value/0`).

  A parent that carries a name but declares no type is itself reported as a
  field, so a nested form yields a struct for the grouping level as well as for
  each leaf under it.
  """
  alias PdfElixide.Form.Field.Button
  alias PdfElixide.Form.Field.Choice
  alias PdfElixide.Form.Field.Text
  alias PdfElixide.Form.Field.Unknown

  @typedoc "Any form field."
  @type t :: Text.t() | Button.t() | Choice.t() | Unknown.t()

  @typedoc """
  A field's value as a plain term: a string, a boolean, a list of strings, or
  `nil` for a field carrying no value.

  This is both what a field reports and exactly what
  `PdfElixide.Form.set_value/3` accepts — anything else raises `ArgumentError` —
  so a value read from one form can be written straight into another.

  Button fields are the exception, and writing one back is not always faithful —
  see the "Check boxes and radio groups" section of `PdfElixide.Form` before
  round-tripping a `PdfElixide.Form.Field.Button`.

  Each struct's moduledoc describes the subset a well-formed PDF can put on its
  kind; a malformed `/V` whose PDF type is foreign to the field's kind (say, an
  array on a text field) is passed through as the corresponding plain term
  rather than dropped, so any of these shapes can in principle appear on any
  struct.
  """
  @type value :: String.t() | boolean() | [String.t()] | nil
end
