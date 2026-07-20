defmodule PdfElixide.Color do
  @moduledoc """
  An RGB color, each channel in the `0.0..1.0` range.
  """
  @enforce_keys [:r, :g, :b]

  defstruct [
    :r,
    :g,
    :b
  ]

  @type t :: %__MODULE__{
          r: float(),
          g: float(),
          b: float()
        }
end
