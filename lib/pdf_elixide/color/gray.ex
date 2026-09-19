defmodule PdfElixide.Color.Gray do
  @moduledoc """
  A DeviceGray color — a single intensity in the `0.0..1.0` range in a
  well-formed PDF, where `0.0` is black and `1.0` is white; see "Component
  range" in `PdfElixide.Color` for what a malformed one can hold.

  Only annotation colors can take this shape; see `PdfElixide.Color`.
  """
  @enforce_keys [:gray]

  defstruct @enforce_keys

  @type t :: %__MODULE__{gray: float()}
end
