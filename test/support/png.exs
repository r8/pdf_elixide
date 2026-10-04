defmodule PdfElixide.Png do
  @moduledoc false

  @channels %{gray: 1, gray_alpha: 2, rgb: 3, rgba: 4}
  @color_type %{gray: 0, gray_alpha: 4, rgb: 2, rgba: 6}

  # `pixels` is the raw samples, row by row, big-endian at depth 16.
  def encode(width, height, color, depth \\ 8, pixels) do
    row = div(width * Map.fetch!(@channels, color) * depth, 8)
    ^height = div(byte_size(pixels), row)

    rows = for <<line::binary-size(^row) <- pixels>>, into: <<>>, do: <<0, line::binary>>
    header = <<width::32, height::32, depth, Map.fetch!(@color_type, color), 0, 0, 0>>

    <<0x89, "PNG\r\n", 0x1A, "\n">> <>
      chunk("IHDR", header) <> chunk("IDAT", :zlib.compress(rows)) <> chunk("IEND", <<>>)
  end

  # Every sample set to `value`.
  def solid(width, height, color, value \\ 128) do
    encode(width, height, color, :binary.copy(<<value>>, width * height * @channels[color]))
  end

  # A PNG claiming any size with no pixel data, so a test can exceed a budget
  # without allocating it.
  def header(width, height, color, depth \\ 8) do
    ihdr = <<width::32, height::32, depth, Map.fetch!(@color_type, color), 0, 0, 0>>

    <<0x89, "PNG\r\n", 0x1A, "\n">> <>
      chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(<<>>)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end
end
