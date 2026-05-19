defmodule PdfElixide.Form.Field do
  @moduledoc """
  Representation of a form field within a PDF document.
  """
  @enforce_keys [:name, :kind, :value]

  defstruct [
    :name,
    :kind,
    :value
  ]

  @type kind ::
          :button
          | :text
          | :choice
          | :signature
          | :unknown

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
