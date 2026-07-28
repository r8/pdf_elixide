defmodule PdfElixide.Document.Table.Cell do
  @moduledoc """
  A single cell of a detected table, with its text, geometry, spans, and
  grid placement.
  """
  alias PdfElixide.Document.Span
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:text, :bbox, :colspan, :rowspan, :header?, :mcids, :spans]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text: String.t(),
          bbox: Rect.t() | nil,
          colspan: pos_integer(),
          rowspan: pos_integer(),
          header?: boolean(),
          mcids: [non_neg_integer()],
          spans: [Span.t()]
        }

  @doc false
  # Builds a `Cell` from the raw map returned by the NIF, renaming the `header`
  # key to the `?`-suffixed struct field and converting the nested span maps
  # into `PdfElixide.Document.Span` structs.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        text: text,
        bbox: bbox,
        colspan: colspan,
        rowspan: rowspan,
        header: header,
        mcids: mcids,
        spans: spans
      }) do
    %__MODULE__{
      text: text,
      bbox: bbox,
      colspan: colspan,
      rowspan: rowspan,
      header?: header,
      mcids: mcids,
      spans: Enum.map(spans, &Span.from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Table.Cell{text: text}, _opts) do
      concat(["#PdfElixide.Document.Table.Cell<", Kernel.inspect(text), ">"])
    end
  end
end
