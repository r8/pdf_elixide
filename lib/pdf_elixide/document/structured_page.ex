defmodule PdfElixide.Document.StructuredPage do
  @moduledoc """
  A page read as typed regions, returned by
  `PdfElixide.Document.structured/2` and `PdfElixide.Document.Page.structured/2`.

  `regions` contains `PdfElixide.Document.StructuredPage.Region` structs; see
  that module for grouping and ordering, and
  `t:PdfElixide.Document.StructuredPage.Region.kind/0` for roles. It is `[]` for
  an encrypted document opened without its password or a page whose content
  could not be read.

  `width` and `height` are the coordinates of the page's `/MediaBox`
  upper-right corner, not the box's extent, and are not turned for a page's
  `/Rotate`. On the usual box starting at the origin they equal the page size;
  on a box such as `[10 20 622 812]` they read `622.0` and `812.0` where
  `PdfElixide.Document.Page.width/1` reads `612.0`. Use
  `PdfElixide.Document.Page.media_box/1` for the normalized rectangle.
  """
  alias PdfElixide.Document.StructuredPage.Region

  @enforce_keys [:page, :width, :height, :regions]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          width: float(),
          height: float(),
          regions: [Region.t()]
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{page: page, width: width, height: height, regions: regions}) do
    %__MODULE__{
      page: page,
      width: width,
      height: height,
      regions: Enum.map(regions, &Region.from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.StructuredPage{} = page, _opts) do
      concat([
        "#PdfElixide.Document.StructuredPage<p",
        to_string(page.page),
        " ",
        to_string(page.width),
        "x",
        to_string(page.height),
        " ",
        to_string(length(page.regions)),
        " regions>"
      ])
    end
  end
end
