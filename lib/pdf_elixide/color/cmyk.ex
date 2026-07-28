defmodule PdfElixide.Color.CMYK do
  @moduledoc """
  A DeviceCMYK color — cyan, magenta, yellow, and key (black), each in the
  `0.0..1.0` range.

  Only annotation colors can take this shape; see `PdfElixide.Color`.
  """
  @enforce_keys [:c, :m, :y, :k]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          c: float(),
          m: float(),
          y: float(),
          k: float()
        }
end
