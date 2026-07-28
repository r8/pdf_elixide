defmodule PdfElixide.Color.Unknown do
  @moduledoc """
  Color components whose colorspace could not be identified, preserved verbatim.

  Annotation colors are decoded by counting components — one is DeviceGray,
  three DeviceRGB, four DeviceCMYK. Any other count lands here rather than being
  guessed at or discarded.
  """
  @enforce_keys [:components]

  defstruct @enforce_keys

  @type t :: %__MODULE__{components: [float()]}
end
