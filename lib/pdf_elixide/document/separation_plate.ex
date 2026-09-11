defmodule PdfElixide.Document.SeparationPlate do
  @moduledoc """
  One ink's coverage across a page, as a grayscale raster — the prepress view of
  what a single printing plate would lay down.

      plates = PdfElixide.Document.Page.separations!(page, dpi: 150)
      Enum.map(plates, & &1.ink)
      #=> ["Cyan", "Magenta", "Yellow", "Black", "PANTONE 185 C"]

  `:data` is one byte per pixel, row-major from the top-left corner, so
  `byte_size(data) == width * height`. **The value is ink coverage, not
  lightness**: `0` is bare paper and `255` is full tint. To show a plate the way
  a prepress viewer does — black ink on white paper — invert it first.

  See the [Rendering](guides/rendering.md) guide for which inks a page yields and
  how they relate to `PdfElixide.Document.inks/3`.
  """
  alias PdfElixide.Document.SeparationPlate

  @enforce_keys [:ink, :data, :width, :height]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ink: String.t(),
          data: binary(),
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{ink_name: ink, data: data, width: width, height: height}) do
    %__MODULE__{ink: ink, data: data, width: width, height: height}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%SeparationPlate{ink: ink, width: width, height: height}, _opts) do
      concat([
        "#PdfElixide.Document.SeparationPlate<",
        inspect(ink),
        " ",
        to_string(width),
        "x",
        to_string(height),
        ">"
      ])
    end
  end
end
