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

  Read a value out with `cell/3` or `cell_text/3`, both zero-based and both
  `nil` when the index falls outside the table:

      Table.cell_text(table, 0, 0)
      #=> "Age"

      Table.cell(table, 0, 0)
      #=> #PdfElixide.Document.Table.Cell<"Age">

  Both indices are positions — the row within `:rows`, the column within that
  row's `:cells` — so they reach exactly what `Enum.at/2` would. Note that the
  detector drops the cells a merge covers without leaving a placeholder, so a row
  containing a cell whose `:colspan` or `:rowspan` is greater than one stores
  fewer cells than `:col_count`, and the positions after the merge no longer line
  up with the visual column.

  A table is enumerable over its rows, and each row over its cells, so the whole
  grid of text is one nested `Enum.map/2`:

      Enum.map(table, fn row -> Enum.map(row, & &1.text) end)
      #=> [["Age", "0.042", "0.011", "0.001"], ...]
  """
  alias PdfElixide.Document.Table.Cell
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

  @doc """
  The cell at the zero-based row `row_index` and column `col`, or `nil` when
  either index falls outside the table.

      Table.cell(table, 0, 0)
      #=> #PdfElixide.Document.Table.Cell<"Age">
  """
  @spec cell(t(), non_neg_integer(), non_neg_integer()) :: Cell.t() | nil
  def cell(%__MODULE__{} = table, row_index, col)
      when is_integer(row_index) and row_index >= 0 and is_integer(col) and col >= 0 do
    case row(table, row_index) do
      %Row{} = row -> Row.cell(row, col)
      nil -> nil
    end
  end

  @doc """
  The text of the cell at the zero-based row `row_index` and column `col`, or
  `nil` when either index falls outside the table.

      Table.cell_text(table, 0, 0)
      #=> "Age"
  """
  @spec cell_text(t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  def cell_text(%__MODULE__{} = table, row_index, col) do
    case cell(table, row_index, col) do
      %Cell{text: text} -> text
      nil -> nil
    end
  end

  @doc """
  The row at the zero-based `index`, or `nil` when the table has no such row.

      Table.row(table, 0)
      #=> #PdfElixide.Document.Table.Row<4 cells>
  """
  @spec row(t(), non_neg_integer()) :: Row.t() | nil
  def row(%__MODULE__{rows: rows}, index) when is_integer(index) and index >= 0 do
    Enum.at(rows, index)
  end

  @doc """
  The number of rows in the table.

      Table.row_count(table)
      #=> 5
  """
  @spec row_count(t()) :: non_neg_integer()
  def row_count(%__MODULE__{rows: rows}), do: length(rows)

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

  defimpl Enumerable do
    alias PdfElixide.Document.Table

    def count(%Table{rows: rows}), do: {:ok, length(rows)}

    def member?(%Table{rows: rows}, row), do: {:ok, Enum.member?(rows, row)}

    def slice(%Table{rows: rows}) do
      {:ok, length(rows),
       fn start, length, step ->
         Enum.slice(rows, start..(start + (length - 1) * step)//step)
       end}
    end

    def reduce(%Table{rows: rows}, acc, fun), do: Enumerable.List.reduce(rows, acc, fun)
  end
end
