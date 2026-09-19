defmodule PdfElixide.Document.Word do
  @moduledoc """
  A single word extracted from a PDF page, with its zero-based page index,
  bounding box, and font metadata.

  `:rotation` is the text-matrix rotation, in degrees, of the run the word was
  cut from — the same value as the `:rotation` of the `PdfElixide.Document.Span`
  it came from — `0.0` for upright text, and `0.0` when its characters disagree.
  On a page whose `PdfElixide.Document.Page.rotation/1` is `90` or `270` it also
  says whether `:bbox` was mapped into the displayed frame; see "Rotated pages
  and extracted geometry" in `PdfElixide.Document`.
  """
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:text, :page, :bbox, :font_size, :font, :bold?, :italic?, :rotation]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text: String.t(),
          page: non_neg_integer(),
          bbox: Rect.t(),
          font_size: float(),
          font: String.t(),
          bold?: boolean(),
          italic?: boolean(),
          rotation: float()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        text: text,
        page: page,
        bbox: bbox,
        font_size: font_size,
        font: font,
        bold: bold,
        italic: italic,
        rotation: rotation
      }) do
    %__MODULE__{
      text: text,
      page: page,
      bbox: bbox,
      font_size: font_size,
      font: font,
      bold?: bold,
      italic?: italic,
      rotation: rotation
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Word{text: text, page: page, bbox: %{x: x, y: y}}, _opts) do
      concat([
        "#PdfElixide.Document.Word<",
        Kernel.inspect(text),
        " @ p",
        to_string(page),
        " ",
        to_string(x),
        ",",
        to_string(y),
        ">"
      ])
    end
  end
end
