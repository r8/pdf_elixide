defmodule PdfElixide.Form.Field.Choice.Flags do
  @moduledoc """
  The `/Ff` field flags of a choice field (ISO 32000-1 Table 230), alongside the
  three every field carries (Table 226).

  ## Fields

    * `:read_only` — the field may not be changed by the user.
    * `:required` — the field must have a value when the form is submitted.
    * `:no_export` — the field is omitted from a submission.
    * `:combo` — the field is a combo box rather than a list box. This is the bit
      `PdfElixide.Form.Field.Choice`'s `:kind` reports as `:combo_box`.
    * `:edit` — the combo box includes an editable text box, so its value need
      not be one of the offered options. Meaningful only with `:combo`.
    * `:sort` — the options are sorted alphabetically. This is a hint to the
      software that produces the field, not to the one that displays it.
    * `:multi_select` — more than one option may be selected at once, which is
      how a choice field comes to hold a list value.
    * `:do_not_spell_check` — an editable combo box's text is not spell-checked.
    * `:commit_on_sel_change` — the new value is committed as soon as a selection
      is made, rather than when the field loses focus.
    * `:raw` — the undecoded `/Ff` integer, for bits this struct does not name.

  See the "Field kinds and flags" section of the [Forms](guides/forms.md) guide.
  """

  @enforce_keys [
    :read_only,
    :required,
    :no_export,
    :combo,
    :edit,
    :sort,
    :multi_select,
    :do_not_spell_check,
    :commit_on_sel_change,
    :raw
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          read_only: boolean(),
          required: boolean(),
          no_export: boolean(),
          combo: boolean(),
          edit: boolean(),
          sort: boolean(),
          multi_select: boolean(),
          do_not_spell_check: boolean(),
          commit_on_sel_change: boolean(),
          raw: non_neg_integer()
        }
end
