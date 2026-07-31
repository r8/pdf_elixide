defmodule PdfElixide.Inspecting do
  @moduledoc false

  @doc """
  Renders a `:source_path` for the `Document` and `Editor` `Inspect` impls.

  A path is opaque bytes, so `Path.basename/1` can hand back a binary with no
  UTF-8 spelling — and an `Inspect` result carrying those bytes makes
  `IO.puts/1` raise `:no_translation`. Falls back to `Kernel.inspect/1` there.
  """
  @spec source(binary() | nil) :: binary()
  def source(nil), do: "<binary>"

  def source(path) do
    base = Path.basename(path)

    if String.valid?(base), do: base, else: Kernel.inspect(base)
  end
end
