defmodule PdfElixide.Color.RGB do
  @moduledoc """
  A DeviceRGB color — red, green, and blue, each in the `0.0..1.0` range.

  This is the only color shape text and vector graphics can take; see
  `PdfElixide.Color` for why.
  """
  @enforce_keys [:r, :g, :b]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          r: float(),
          g: float(),
          b: float()
        }
end
