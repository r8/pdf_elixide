defmodule PdfElixide.Document.Word do
  @moduledoc """
  A single word extracted from a PDF page, with its zero-based page index,
  bounding box, and font metadata.
  """
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:text, :page, :bbox, :font_size, :font, :bold?, :italic?]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text: String.t(),
          page: non_neg_integer(),
          bbox: Rect.t(),
          font_size: float(),
          font: String.t(),
          bold?: boolean(),
          italic?: boolean()
        }

  @doc false
  # Builds a `Word` from the raw map returned by the NIF, renaming the
  # `bold`/`italic` keys to the `?`-suffixed struct fields.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        text: text,
        page: page,
        bbox: bbox,
        font_size: font_size,
        font: font,
        bold: bold,
        italic: italic
      }) do
    %__MODULE__{
      text: text,
      page: page,
      bbox: bbox,
      font_size: font_size,
      font: font,
      bold?: bold,
      italic?: italic
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
