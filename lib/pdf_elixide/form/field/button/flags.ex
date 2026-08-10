defmodule PdfElixide.Form.Field.Button.Flags do
  @moduledoc """
  The `/Ff` field flags of a button field (ISO 32000-1 Table 227), alongside the
  three every field carries (Table 226).

  ## Fields

    * `:read_only` — the field may not be changed by the user.
    * `:required` — the field must have a value when the form is submitted.
    * `:no_export` — the field is omitted from a submission.
    * `:no_toggle_to_off` — one radio button in the group must always be
      selected; clicking the selected one does not clear it.
    * `:radio` — the field is a group of radio buttons.
    * `:push_button` — the field is a push button, which holds no value and acts
      only through its `/AA` actions.
    * `:radios_in_unison` — radio buttons in the group that share an on-state
      name are selected and cleared together.
    * `:raw` — the undecoded `/Ff` integer, for bits this struct does not name.

  `:radio` and `:push_button` are the two bits
  `PdfElixide.Form.Field.Button`'s `:kind` reports, with `:push_button` taking
  precedence over `:radio` on a field that sets both. See the "Field kinds and
  flags" section of the [Forms](guides/forms.md) guide.
  """

  @enforce_keys [
    :read_only,
    :required,
    :no_export,
    :no_toggle_to_off,
    :radio,
    :push_button,
    :radios_in_unison,
    :raw
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          read_only: boolean(),
          required: boolean(),
          no_export: boolean(),
          no_toggle_to_off: boolean(),
          radio: boolean(),
          push_button: boolean(),
          radios_in_unison: boolean(),
          raw: non_neg_integer()
        }
end
