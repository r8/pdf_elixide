defmodule PdfElixide.Document.SearchMatch do
  @moduledoc """
  One occurrence of a pattern found by `PdfElixide.Document.search/2`, with its
  zero-based page index, the matched text, and where it sits on the page.

  Both `:bbox` and every entry of `:span_boxes` are **whole-span** boxes rather
  than the extents of the matched text itself: a match inside a longer run of
  text reports the box of that whole run. Draw from `:span_boxes`, which has one
  entry per run the match touched.

  The [Search](guides/search.md) guide has the rest, including how far `:bbox`
  over-covers, why a match can cross what looks like a line break, and when the
  boxes come back empty.
  """
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:page, :text, :bbox, :span_boxes]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          text: String.t(),
          bbox: Rect.t(),
          span_boxes: [Rect.t()]
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{page: page, text: text, bbox: bbox, span_boxes: span_boxes}) do
    %__MODULE__{page: page, text: text, bbox: bbox, span_boxes: span_boxes}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.SearchMatch{text: text, page: page}, _opts) do
      concat([
        "#PdfElixide.Document.SearchMatch<",
        Kernel.inspect(text),
        " @ p",
        to_string(page),
        ">"
      ])
    end
  end
end
