defmodule PdfElixide.Document.TextLine do
  @moduledoc """
  A single line of text extracted from a PDF page, with its zero-based page
  index, bounding box, and constituent words.
  """
  alias PdfElixide.Document.Word
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:text, :page, :bbox, :words]

  defstruct [
    :text,
    :page,
    :bbox,
    :words
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          page: non_neg_integer(),
          bbox: Rect.t(),
          words: [Word.t()]
        }

  @doc false
  # Builds a `TextLine` from the raw map returned by the NIF, converting the
  # nested word maps into `PdfElixide.Document.Word` structs.
  @spec from_nif(map()) :: t()
  def from_nif(%{text: text, page: page, bbox: bbox, words: words}) do
    %__MODULE__{
      text: text,
      page: page,
      bbox: bbox,
      words: Enum.map(words, &Word.from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.TextLine{text: text, page: page, words: words}, _opts) do
      concat([
        "#PdfElixide.Document.TextLine<",
        Kernel.inspect(text),
        " @ p",
        to_string(page),
        " (",
        to_string(length(words)),
        " words)>"
      ])
    end
  end
end
