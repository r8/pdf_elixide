defmodule PdfElixide.Form.Field do
  @moduledoc """
  A single AcroForm field: its `:name`, its `:kind`, and its current `:value`.

  Obtained from `PdfElixide.Form.fields/1`. The `:name` is the field's fully
  qualified name and is what `PdfElixide.Form.set_value/3` addresses it by.
  """
  @enforce_keys [:name, :kind, :value]

  defstruct @enforce_keys

  @typedoc """
  The field's type, as declared by the PDF's `/FT` entry.

    * `:button` — push buttons, check boxes and radio groups.
    * `:text` — free-text entry.
    * `:choice` — list boxes and combo boxes.
    * `:signature` — a digital signature field.
    * `:unknown` — the field declares no recognized type.
  """
  @type kind ::
          :button
          | :text
          | :choice
          | :signature
          | :unknown

  @typedoc """
  A field's value, tagged by the shape the PDF stores it in.

  The tag follows the underlying PDF object rather than the field's `t:kind/0`,
  so match on the tag rather than inferring it from the kind:

    * `{:text, value}` — a text string. The usual shape for a `:text` field, and
      for a `:choice` field with one selection.
    * `{:boolean, value}` — a true/false toggle.
    * `{:name, value}` — a PDF name, without its leading slash. How a check box
      or radio group reports its state, typically `"Off"` when unset and the
      on-state's name when set.
    * `{:array, values}` — several strings, e.g. a multi-select `:choice` field.
    * `nil` — the field carries no value.

  `PdfElixide.Form.set_value/3` accepts exactly these shapes, so a value read
  from one field can be written to another unchanged. Anything else — a bare
  string, an unrecognized tag — raises `ArgumentError`.
  """
  @type value ::
          {:text, String.t()}
          | {:boolean, boolean()}
          | {:name, String.t()}
          | {:array, [String.t()]}
          | nil

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          value: value()
        }
end
