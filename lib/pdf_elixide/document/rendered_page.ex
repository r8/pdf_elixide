defmodule PdfElixide.Document.RenderedPage do
  @moduledoc """
  A page rasterized to an image, with the encoded bytes and their pixel
  dimensions.

      page = PdfElixide.Document.page!(doc, 0)
      rendered = PdfElixide.Document.Page.render!(page, dpi: 150)

      File.write!("page0.png", rendered.data)
      {rendered.width, rendered.height}
      #=> {1275, 1650}

  `:data` is a complete file for `:png` and `:jpeg`. For `:rgba8` it is bare
  pixels instead — premultiplied RGBA8888, four bytes per pixel, row-major from
  the top-left corner, with no padding between rows, so
  `byte_size(data) == width * height * 4`. Un-premultiply it yourself if you need
  straight alpha.

  Unlike `PdfElixide.Document.Image`, this struct holds no native handle: the
  bytes are already encoded, so there is nothing to release and nothing to
  close.

  See the [Rendering](guides/rendering.md) guide for what the raster covers, how
  to size it, and how layer visibility differs from text extraction.
  """
  alias PdfElixide.Document.RenderedPage

  @enforce_keys [:data, :width, :height, :format]

  defstruct @enforce_keys

  @typedoc """
  The encoding of `:data` — the `:format` the render was asked for.
  """
  @type format :: :png | :jpeg | :rgba8

  @type t :: %__MODULE__{
          data: binary(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          format: format()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{data: data, width: width, height: height, format: format}) do
    %__MODULE__{data: data, width: width, height: height, format: format}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%RenderedPage{width: width, height: height, format: format}, _opts) do
      concat([
        "#PdfElixide.Document.RenderedPage<",
        to_string(width),
        "x",
        to_string(height),
        " ",
        to_string(format),
        ">"
      ])
    end
  end
end
