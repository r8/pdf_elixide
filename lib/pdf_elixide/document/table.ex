defmodule PdfElixide.Document.Table do
  @moduledoc """
  A table detected on a PDF page, with its zero-based page index, bounding box,
  and rows.

  Tables are *detected* by a spatial algorithm rather than read from explicit
  markup, so a detection is a best guess. The `:real_grid?` flag reports
  whether the detection looks like a genuine data grid (at least two rows and
  columns, consistently populated) as opposed to a form layout or a
  label-colon-value list; filter on it when false positives matter:

      Enum.filter(tables, & &1.real_grid?)

  `:bbox` is `nil` when the detector could not determine the table's extent.
  """
  alias PdfElixide.Document.Table.Row
  alias PdfElixide.Geometry.Rect

  @enforce_keys [:page, :bbox, :col_count, :has_header?, :real_grid?, :rows]

  defstruct [
    :page,
    :bbox,
    :col_count,
    :has_header?,
    :real_grid?,
    :rows
  ]

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          bbox: Rect.t() | nil,
          col_count: non_neg_integer(),
          has_header?: boolean(),
          real_grid?: boolean(),
          rows: [Row.t()]
        }

  @doc false
  # Builds a `Table` from the raw map returned by the NIF, renaming the
  # `has_header`/`real_grid` keys to the `?`-suffixed struct fields and
  # converting the nested row maps into `PdfElixide.Document.Table.Row` structs.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        bbox: bbox,
        col_count: col_count,
        has_header: has_header,
        real_grid: real_grid,
        rows: rows
      }) do
    %__MODULE__{
      page: page,
      bbox: bbox,
      col_count: col_count,
      has_header?: has_header,
      real_grid?: real_grid,
      rows: Enum.map(rows, &Row.from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Table{} = table, _opts) do
      concat([
        "#PdfElixide.Document.Table<p",
        to_string(table.page),
        " ",
        to_string(length(table.rows)),
        "x",
        to_string(table.col_count),
        if(table.has_header?, do: " (header)", else: ""),
        ">"
      ])
    end
  end
end
