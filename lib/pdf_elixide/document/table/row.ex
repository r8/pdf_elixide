defmodule PdfElixide.Document.Table.Row do
  @moduledoc """
  A single row of a detected table, holding its cells.
  """
  alias PdfElixide.Document.Table.Cell

  @enforce_keys [:header?, :cells]

  defstruct [
    :header?,
    :cells
  ]

  @type t :: %__MODULE__{
          header?: boolean(),
          cells: [Cell.t()]
        }

  @doc false
  # Builds a `Row` from the raw map returned by the NIF, renaming the `header`
  # key to the `?`-suffixed struct field and converting the nested cell maps
  # into `PdfElixide.Document.Table.Cell` structs.
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
end
