defmodule PdfElixide.ContentOrder do
  @moduledoc false

  # Requires an uncompressed write with page 0's /Contents as the first array.
  # In flatten.pdf, the other page keeps a single stream reference.
  @spec page0_bodies(binary()) :: [binary()]
  def page0_bodies(bytes) when is_binary(bytes) do
    [_, refs] = Regex.run(~r{/Contents \[([^\]]*)\]}, bytes)

    ~r/(\d+) 0 R/
    |> Regex.scan(refs)
    |> Enum.map(fn [_, number] -> stream_body(bytes, number) end)
  end

  @spec page0(binary()) :: [:original | :whiteout | :flattened]
  def page0(bytes) when is_binary(bytes) do
    bytes |> page0_bodies() |> Enum.map(&classify/1)
  end

  defp stream_body(bytes, number) do
    [_, body] = Regex.run(~r/\n#{number} 0 obj\s*<<[^>]*>>\s*stream\n(.*?)endstream/s, bytes)
    body
  end

  defp classify(body) do
    cond do
      String.contains?(body, "1 1 1 rg") -> :whiteout
      String.contains?(body, "Do") -> :flattened
      true -> :original
    end
  end
end
