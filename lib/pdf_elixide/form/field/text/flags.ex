defmodule PdfElixide.Form.Field.Text.Flags do
  @moduledoc """
  The `/Ff` field flags of a text field (ISO 32000-1 Table 228), alongside the
  three every field carries (Table 226).

  ## Fields

    * `:read_only` — the field may not be changed by the user.
    * `:required` — the field must have a value when the form is submitted.
    * `:no_export` — the field is omitted from a submission.
    * `:multiline` — the field holds more than one line of text. This is the bit
      `PdfElixide.Form.Field.Text`'s `:kind` reports as `:multiline`.
    * `:password` — the entered text is not echoed, and no value is saved.
    * `:file_select` — the value is the path name of a file to submit.
    * `:do_not_spell_check` — the text is not spell-checked.
    * `:do_not_scroll` — no more text is accepted than the field can display.
    * `:comb` — the text is laid out in equally spaced positions, which the
      specification allows only when a `/MaxLen` is present and none of
      `:multiline`, `:password` and `:file_select` is set.
    * `:rich_text` — the value is rich text.
    * `:raw` — the undecoded `/Ff` integer, for bits this struct does not name.

  See the "Field kinds and flags" section of the [Forms](guides/forms.md) guide.
  """

  @enforce_keys [
    :read_only,
    :required,
    :no_export,
    :multiline,
    :password,
    :file_select,
    :do_not_spell_check,
    :do_not_scroll,
    :comb,
    :rich_text,
    :raw
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          read_only: boolean(),
          required: boolean(),
          no_export: boolean(),
          multiline: boolean(),
          password: boolean(),
          file_select: boolean(),
          do_not_spell_check: boolean(),
          do_not_scroll: boolean(),
          comb: boolean(),
          rich_text: boolean(),
          raw: non_neg_integer()
        }
end
