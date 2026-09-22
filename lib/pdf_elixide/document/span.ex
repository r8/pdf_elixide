defmodule PdfElixide.Document.Span do
  @moduledoc """
  A run of text sharing one text state — the same font, size, color, and
  text-state parameters — extracted from a PDF page, with its zero-based page
  index and bounding box.

  Float fields follow the "Unbounded values" rule in
  `PdfElixide.Geometry.Rect`.

  ## `:bbox` and `:page_bbox`

  In raw user space, `:bbox` measures the run along its writing axis: `width`
  is its advance and `height` its font size. A displayed frame may transpose
  those dimensions; see "Rotated pages and extracted geometry" in
  `PdfElixide.Document`.

  `:page_bbox` is the smallest axis-aligned rectangle covering the run, in the
  same frame as `:bbox`. It equals `:bbox` when `:rotation` is `0.0`. Use it for
  layout or hit-testing, and use `:bbox` to measure the text along its writing
  axis.
  """
  alias PdfElixide.Color.RGB
  alias PdfElixide.Geometry.Rect

  @enforce_keys [
    :text,
    :page,
    :bbox,
    :page_bbox,
    :font_size,
    :font,
    :font_weight,
    :bold?,
    :italic?,
    :monospace?,
    :color,
    :rotation,
    :char_spacing,
    :word_spacing,
    :horizontal_scaling,
    :text_rise,
    :heading_level,
    :mcid
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text: String.t(),
          page: non_neg_integer(),
          bbox: Rect.t(),
          page_bbox: Rect.t(),
          font_size: float(),
          font: String.t(),
          font_weight: non_neg_integer(),
          bold?: boolean(),
          italic?: boolean(),
          monospace?: boolean(),
          color: RGB.t(),
          rotation: float(),
          char_spacing: float(),
          word_spacing: float(),
          horizontal_scaling: float(),
          text_rise: float(),
          heading_level: pos_integer() | nil,
          mcid: non_neg_integer() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        text: text,
        page: page,
        bbox: bbox,
        page_bbox: page_bbox,
        font_size: font_size,
        font: font,
        font_weight: font_weight,
        bold: bold,
        italic: italic,
        monospace: monospace,
        color: color,
        rotation: rotation,
        char_spacing: char_spacing,
        word_spacing: word_spacing,
        horizontal_scaling: horizontal_scaling,
        text_rise: text_rise,
        heading_level: heading_level,
        mcid: mcid
      }) do
    %__MODULE__{
      text: text,
      page: page,
      bbox: bbox,
      page_bbox: page_bbox,
      font_size: font_size,
      font: font,
      font_weight: font_weight,
      bold?: bold,
      italic?: italic,
      monospace?: monospace,
      color: color,
      rotation: rotation,
      char_spacing: char_spacing,
      word_spacing: word_spacing,
      horizontal_scaling: horizontal_scaling,
      text_rise: text_rise,
      heading_level: heading_level,
      mcid: mcid
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Span{text: text, page: page, bbox: %{x: x, y: y}}, _opts) do
      concat([
        "#PdfElixide.Document.Span<",
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
