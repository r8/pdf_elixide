defmodule PdfElixide.Color.Gray do
  @moduledoc """
  A DeviceGray color — a single intensity in the `0.0..1.0` range, where `0.0` is
  black and `1.0` is white.

  Only annotation colors can take this shape; see `PdfElixide.Color`.
  """
  @enforce_keys [:gray]

  defstruct [:gray]

  @type t :: %__MODULE__{gray: float()}
end
