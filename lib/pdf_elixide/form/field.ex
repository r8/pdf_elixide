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
  `PdfElixide.Form.value/2` and `PdfElixide.Form.put_value/3` address it by,
  identical whether the form was read from a `PdfElixide.Document` or a
  `PdfElixide.Editor` — `:value`, a plain term (`t:value/0`) — `:default_value`,
  the reset value the field itself declares, in the same shapes — `:flags`, the
  decoded `/Ff` bits its type can carry — `:tooltip`, the text a viewer shows on
  hover — and `:rect`, the box the field occupies, which is `nil` for a field
  whose widgets are separate objects.

  Beyond those, `Text` carries `:max_length` and `:alignment`, and `Choice`
  `:alignment` and `:options`. The "What else a field reports" section of the
  [Forms](guides/forms.md) guide covers all of it.

  A field nested under a parent inherits the parent's *type* — so it is that
  type's struct rather than `Unknown` — along with `:flags`, `:options`,
  `:alignment` and `:max_length`, wherever it declares none of its own. It does
  **not** inherit `:value` or `:default_value` — each is read off the field's own
  dictionary, so a field whose parent carries the value and which carries none
  itself reports `nil`. The "What a nested field inherits" section of the guide
  says what to do instead.

  The first three also carry a `:kind`, naming the widget the type covers —
  `t:PdfElixide.Form.Field.Text.kind/0`,
  `t:PdfElixide.Form.Field.Button.kind/0` and
  `t:PdfElixide.Form.Field.Choice.kind/0` each list their own. `Unknown` has none, having no type
  whose bits would say.

  A parent that carries a name but declares no type is itself reported as a
  field, so a nested form yields a struct for the grouping level as well as for
  each leaf under it.

  The "Field kinds and flags" section of the [Forms](guides/forms.md) guide
  covers both in full.
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
  `PdfElixide.Form.put_value/3` accepts — anything else raises `ArgumentError` —
  so a value read from one form can be written straight into another.

  Button fields are the exception, and writing one back is not always faithful —
  see the [Forms](guides/forms.md) guide before round-tripping a
  `PdfElixide.Form.Field.Button`.

  Each struct's moduledoc describes the subset a well-formed PDF can put on its
  kind; a malformed `/V` whose PDF type is foreign to the field's kind (say, an
  array on a text field) is passed through as the corresponding plain term
  rather than dropped, so any of these shapes can in principle appear on any
  struct.
  """
  @type value :: String.t() | boolean() | [String.t()] | nil

  @typedoc """
  How a field's text is justified inside its box, from `/Q`.

  `nil` when the field declares no `/Q`, and also when it declares a value the
  PDF specification does not define — those two are not distinguished.
  """
  @type alignment :: :left | :center | :right | nil

  @typedoc """
  One entry of a choice field's option list.

  A bare string when the PDF spells the option as a single value, and
  `{export, display}` when it spells it as a pair: `export` is what a selection
  is stored and submitted as — and so what `PdfElixide.Form.value/2` reports and
  `PdfElixide.Form.put_value/3` takes — while `display` is only what a viewer
  shows.
  """
  @type option :: String.t() | {export :: String.t(), display :: String.t()}
end
