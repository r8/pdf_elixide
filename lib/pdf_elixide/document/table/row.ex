defmodule PdfElixide.Document.Table.Row do
  @moduledoc """
  A single row of a detected table, holding its cells.

  A row is enumerable over the cells it stores:

      Enum.map(row, & &1.text)
      #=> ["Age", "0.042", "0.011", "0.001"]

  `cell/2` and `cell_text/2` reach the same cells by position, so they agree
  with `Enum.at/2`. A row whose detection merged cells stores fewer cells than
  the table's `:col_count` — see `PdfElixide.Document.Table` for what that means
  for indices.
  """
  alias PdfElixide.Document.Table.Cell

  @enforce_keys [:header?, :cells]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          header?: boolean(),
          cells: [Cell.t()]
        }

  @doc """
  The cell at the zero-based position `col`, or `nil` when the row does not
  reach that far.

      Row.cell(row, 0)
      #=> #PdfElixide.Document.Table.Cell<"Age">
  """
  @spec cell(t(), non_neg_integer()) :: Cell.t() | nil
  def cell(%__MODULE__{cells: cells}, col) when is_integer(col) and col >= 0 do
    Enum.at(cells, col)
  end

  @doc """
  The text of the cell at the zero-based position `col`, or `nil` when the row
  does not reach that far.

      Row.cell_text(row, 0)
      #=> "Age"
  """
  @spec cell_text(t(), non_neg_integer()) :: String.t() | nil
  def cell_text(%__MODULE__{} = row, col) do
    case cell(row, col) do
      %Cell{text: text} -> text
      nil -> nil
    end
  end

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{header: header, cells: cells}) do
    %__MODULE__{
      header?: header,
      cells: Enum.map(cells, &Cell.from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Table.Row{cells: cells}, _opts) do
      concat([
        "#PdfElixide.Document.Table.Row<",
        to_string(length(cells)),
        " cells>"
      ])
    end
  end

  defimpl Enumerable do
    alias PdfElixide.Document.Table.Row

    def count(%Row{cells: cells}), do: {:ok, length(cells)}

    def member?(%Row{cells: cells}, cell), do: {:ok, Enum.member?(cells, cell)}

    def slice(%Row{cells: cells}) do
      {:ok, length(cells),
       fn start, length, step ->
         Enum.slice(cells, start..(start + (length - 1) * step)//step)
       end}
    end

    def reduce(%Row{cells: cells}, acc, fun), do: Enumerable.List.reduce(cells, acc, fun)
  end
end
