defmodule PdfElixide.Geometry.Rect do
  @moduledoc """
  An axis-aligned rectangle in PDF user-space coordinates.

  PDF user space has a bottom-left origin with y increasing upward, so the
  origin `{x, y}` is the **bottom-left** corner (the minimum x/y); the top edge
  is `y + height` and the right edge is `x + width`. `width` and `height` are
  always non-negative.
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
