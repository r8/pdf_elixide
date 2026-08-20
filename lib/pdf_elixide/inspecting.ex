defmodule PdfElixide.Inspecting do
  @moduledoc false

  @doc false
  @spec source(binary() | nil) :: binary()
  def source(nil), do: "<binary>"

  def source(path) do
    base = Path.basename(path)

    # Inspect output must be valid UTF-8 even when the filesystem path is not.
    if String.valid?(base), do: base, else: Kernel.inspect(base)
  end
end
