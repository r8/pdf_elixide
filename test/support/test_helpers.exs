defmodule PdfElixide.TestHelpers do
  @moduledoc false

  alias PdfElixide.Document.RenderedPage

  def lines(count), do: Enum.map_join(1..count, "\n", &"line #{&1}")

  def texts(items), do: Enum.map(items, & &1.text)

  def pixel(%RenderedPage{format: :rgba8} = rendered, col, row) do
    <<r, g, b, a>> = binary_part(rendered.data, (row * rendered.width + col) * 4, 4)
    {r, g, b, a}
  end
end
