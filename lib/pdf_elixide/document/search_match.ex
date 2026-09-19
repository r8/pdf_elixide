defmodule PdfElixide.Document.SearchMatch do
  @moduledoc """
  One occurrence of a pattern found by `PdfElixide.Document.search/2`, with its
  zero-based page index, the matched text, and where it sits on the page.

  `:spans` are the runs of text the match touched, in reading order, each a
  whole `PdfElixide.Document.Span` rather than the extent of the matched
  characters: a match inside a longer run reports that whole run. `:bbox` is
  the union of their boxes. Draw from the spans' boxes, one per run.

  On a rotated page, use each span's `:rotation` to identify its coordinate
  frame; a match's spans may use different frames. See "Rotated pages and
  extracted geometry" in `PdfElixide.Document`.

  The [Search](guides/search.md) guide has the rest, including how far `:bbox`
  over-covers, why a match can cross what looks like a line break, and when the
  spans come back empty.
  """
  alias PdfElixide.Document.Span
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:page, :text, :bbox, :spans]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          text: String.t(),
          bbox: Rect.t(),
          spans: [Span.t()]
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{page: page, text: text, bbox: bbox, spans: spans}) do
    %__MODULE__{page: page, text: text, bbox: bbox, spans: Enum.map(spans, &Span.from_nif/1)}
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
