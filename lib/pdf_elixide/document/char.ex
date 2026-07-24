defmodule PdfElixide.Document.Char do
  @moduledoc """
  A single character extracted from a PDF page, with its zero-based page index,
  bounding box, font metadata, and typographic placement.
  """
  alias PdfElixide.Color.RGB
  alias PdfElixide.Geometry.Rect

  @enforce_keys [
    :text,
    :page,
    :bbox,
    :font_size,
    :font,
    :font_weight,
    :bold?,
    :italic?,
    :monospace?,
    :color,
    :origin,
    :rotation,
    :advance_width,
    :rendered_advance,
    :ascent,
    :descent,
    :mcid
  ]

  defstruct [
    :text,
    :page,
    :bbox,
    :font_size,
    :font,
    :font_weight,
    :bold?,
    :italic?,
    :monospace?,
    :color,
    :origin,
    :rotation,
    :advance_width,
    :rendered_advance,
    :ascent,
    :descent,
    :mcid
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          page: non_neg_integer(),
          bbox: Rect.t(),
          font_size: float(),
          font: String.t(),
          font_weight: non_neg_integer(),
          bold?: boolean(),
          italic?: boolean(),
          monospace?: boolean(),
          color: RGB.t(),
          origin: {float(), float()},
          rotation: float(),
          advance_width: float(),
          rendered_advance: float(),
          ascent: float(),
          descent: float(),
          mcid: non_neg_integer() | nil
        }

  @doc false
  # Builds a `Char` from the raw map returned by the NIF, renaming the
  # `bold`/`italic`/`monospace` keys to the `?`-suffixed struct fields.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        text: text,
        page: page,
        bbox: bbox,
        font_size: font_size,
        font: font,
        font_weight: font_weight,
        bold: bold,
        italic: italic,
        monospace: monospace,
        color: color,
        origin: origin,
        rotation: rotation,
        advance_width: advance_width,
        rendered_advance: rendered_advance,
        ascent: ascent,
        descent: descent,
        mcid: mcid
      }) do
    %__MODULE__{
      text: text,
      page: page,
      bbox: bbox,
      font_size: font_size,
      font: font,
      font_weight: font_weight,
      bold?: bold,
      italic?: italic,
      monospace?: monospace,
      color: color,
      origin: origin,
      rotation: rotation,
      advance_width: advance_width,
      rendered_advance: rendered_advance,
      ascent: ascent,
      descent: descent,
      mcid: mcid
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Char{text: text, page: page, origin: {x, y}}, _opts) do
      concat([
        "#PdfElixide.Document.Char<",
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
