defmodule PdfElixide.Geometry.Rect do
  @moduledoc """
  An axis-aligned rectangle in PDF user-space coordinates.

  The origin `{x, y}` is the top-left corner and `width`/`height` are always
  non-negative.
  """
  @enforce_keys [:x, :y, :width, :height]

  defstruct [
    :x,
    :y,
    :width,
    :height
  ]

  @type t :: %__MODULE__{
          x: float(),
          y: float(),
          width: float(),
          height: float()
        }
end
