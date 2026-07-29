defmodule PdfElixide.Document.Table do
  @moduledoc """
  A table detected on a PDF page, with its zero-based page index, bounding box,
  and rows.

  ## Detection is a guess

  Tables are *detected* by a spatial algorithm rather than read from explicit
  markup, so a detection is a best guess. The `:real_grid?` flag reports
  whether the detection looks like a genuine data grid (at least two rows and
  columns, consistently populated) as opposed to a form layout or a
  label-colon-value list; filter on it when false positives matter:

      Enum.filter(tables, & &1.real_grid?)

  The detector itself is tunable — the strategies, tolerances and size floors
  it uses are `t:PdfElixide.Document.table_detection_opts/0`, passed to
  `PdfElixide.Document.tables/3`. Reach for those when a page yields no table,
  or too many.

  `:bbox` is `nil` when the detector could not determine the table's extent.

  ## Reading cells

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

  ## Enumerating

  A table is enumerable over its rows, and each row over its cells, so the whole
  grid of text is one nested `Enum.map/2`:

      Enum.map(table, fn row -> Enum.map(row, & &1.text) end)
      #=> [["Age", "0.042", "0.011", "0.001"], ...]

  ## Rendering

  A single table renders on its own with `to_markdown/2`, `to_html/1`, or
  `to_text/1` — the same output `PdfElixide.Document.to_markdown/2` and
  `to_html/2` produce for that table within its page:

      Table.to_markdown(table)
      #=> {:ok, "| Age | 0.042 | 0.011 | 0.001 |\\n|---|---|---|---|\\n..."}

  ## The native handle

  Rendering goes through `:ref`, a handle to the detected table held on the Rust
  side, so it works only on a table that came from extraction — not on a
  hand-built struct — and stops working once `close/1` releases it.

  That handle means a `%Table{}` holds the same table twice: the decoded `:rows`
  you read here, and behind `:ref` the detected table as `pdf_oxide` built it,
  kept because only it carries the glyph metrics the renderers need. Both live
  until `close/1` or garbage collection, so on a table-dense page — and more so
  with `PdfElixide.Document.tables/1`, which returns every page's tables at once —
  close the tables you are done rendering.

  The handle is shareable, and rendering through it runs concurrently:
  `to_markdown/2`, `to_html/1` and `to_text/1` all take it shared, over a table
  the handle already owns, so rendering one table from several processes runs in
  parallel. `close/1` is exclusive and waits for a render already in flight.
  Same model as the [Concurrency](guides/concurrency.md) guide describes for a
  document.
  """
  alias PdfElixide.Document.Table.Cell
  alias PdfElixide.Document.Table.Row
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:page, :bbox, :col_count, :has_header?, :real_grid?, :rows, :ref]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          bbox: Rect.t() | nil,
          col_count: non_neg_integer(),
          has_header?: boolean(),
          real_grid?: boolean(),
          rows: [Row.t()],
          ref: reference()
        }

  @typedoc """
  Options for `to_markdown/2`.

  * `:bold_markers` — how `**bold**` markers are placed around spans whose font
    is bold: `:conservative` (the default) skips whitespace-only spans,
    `:aggressive` wraps them too. This is the only conversion option upstream's
    table renderer reads, which is why `to_html/1` takes none.

  An unknown key, or a `:bold_markers` value other than those two, raises
  `ArgumentError` naming the offending key; see the "Errors versus exceptions"
  section of `PdfElixide.Error`.

  Bold markers are suppressed in the header row of a multi-row table either way,
  since a Markdown header is already rendered bold by readers.
  """
  @type markdown_opts :: [bold_markers: :conservative | :aggressive]

  @markdown_opts_keys [:bold_markers]

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

  @doc """
  Renders the table as a Markdown table.

      Table.to_markdown(table)
      #=> {:ok, "| Age | 0.042 | 0.011 | 0.001 |\\n|---|---|---|---|\\n..."}

  Two upstream quirks are worth knowing. Markdown requires a header row, so the
  first row is rendered as one even when `:has_header?` is false. And while
  `:colspan` widens a cell into extra pipe-delimited columns, `:rowspan` is
  ignored entirely — a row whose cells were absorbed by a merge above it is
  simply padded with empty cells on the right.

  An empty table renders as `""`. See `t:markdown_opts/0` for the options.
  """
  @spec to_markdown(t(), markdown_opts()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_markdown(%__MODULE__{ref: ref}, opts \\ []) when is_reference(ref) and is_list(opts) do
    options = build_markdown_options(opts)
    Wrap.call(fn -> Native.table_to_markdown(ref, options) end)
  end

  @doc """
  Same as `to_markdown/2`, but returns the Markdown directly and raises
  `PdfElixide.Error` on failure.
  """
  @spec to_markdown!(t(), markdown_opts()) :: String.t()
  def to_markdown!(%__MODULE__{} = table, opts \\ []) do
    to_markdown(table, opts) |> Wrap.unwrap!()
  end

  # The default below is pinned by `option_defaults_test.exs`, through
  # `__option_defaults__(:markdown)` — changing it has to fail there first.
  defp build_markdown_options(opts) do
    opts = Keyword.validate!(opts, @markdown_opts_keys)
    %{bold_markers: Keyword.get(opts, :bold_markers, :conservative)}
  end

  @doc false
  # See `PdfElixide.Document.__option_defaults__/1` for why this exists.
  @spec __option_defaults__(:markdown) :: map()
  def __option_defaults__(:markdown), do: build_markdown_options([])

  @doc """
  Renders the table as an HTML `<table>` fragment.

      Table.to_html(table)
      #=> {:ok, "<table>\\n<thead>\\n<tr><th>Age</th>...</table>\\n"}

  The fragment carries no styling and is not wrapped in a document: header rows
  become `<thead>`/`<th>`, the rest `<tbody>`/`<td>`, and merged cells keep their
  `colspan`/`rowspan` as attributes. An empty table renders as `""`.

  Cell text is escaped like every other string `pdf_oxide` puts in HTML — see
  the "Escaping" section of `PdfElixide.Document.to_html/2`. This renderer has
  no image path, so nothing in its output is unescaped.
  """
  @spec to_html(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_html(%__MODULE__{ref: ref}) when is_reference(ref) do
    Wrap.call(fn -> Native.table_to_html(ref) end)
  end

  @doc """
  Same as `to_html/1`, but returns the HTML directly and raises
  `PdfElixide.Error` on failure.
  """
  @spec to_html!(t()) :: String.t()
  def to_html!(%__MODULE__{} = table) do
    to_html(table) |> Wrap.unwrap!()
  end

  @doc """
  Renders the table as plain text, padding each column to a fixed width so the
  grid lines up in a monospaced font.

      Table.to_text(table)
      #=> {:ok, "Age       0.042  0.011  0.001\\n..."}

  Cells that span columns are excluded from the width calculation, and an empty
  table renders as `""`.
  """
  @spec to_text(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_text(%__MODULE__{ref: ref}) when is_reference(ref) do
    Wrap.call(fn -> Native.table_to_text(ref) end)
  end

  @doc """
  Same as `to_text/1`, but returns the text directly and raises
  `PdfElixide.Error` on failure.
  """
  @spec to_text!(t()) :: String.t()
  def to_text!(%__MODULE__{} = table) do
    to_text(table) |> Wrap.unwrap!()
  end

  @doc """
  Releases the detected table held behind `:ref`.

  The table is normally freed when the BEAM garbage-collects the handle;
  `close/1` frees it now, which is worth doing when walking many tables and
  keeping only their text — what it frees is upstream's own copy of the table,
  glyph metrics and all, which is the larger of the two representations a
  `%Table{}` holds. The struct's own fields — rows, cells, spans — are
  plain data and stay readable afterwards; only `to_markdown/2`, `to_html/1`, and
  `to_text/1` stop working, returning `{:error, %PdfElixide.Error{reason:
  :closed}}` (bang variants raise it).

  Infallible and idempotent, so there is no `close!/1`. It does take the handle's
  lock exclusively, so it waits for an in-flight render on the same table rather
  than interrupting it — it frees the table as soon as the handle is idle, not
  preemptively.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{ref: ref}), do: Native.table_close(ref)

  @doc """
  Returns whether the table has been released with `close/1`.
  """
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{ref: ref}), do: Native.table_closed(ref)

  @doc false
  # Builds a `Table` from the raw map returned by the NIF, renaming the
  # `has_header`/`real_grid` keys to the `?`-suffixed struct fields and the
  # `resource` handle to `:ref`, and converting the nested row maps into
  # `PdfElixide.Document.Table.Row` structs.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        bbox: bbox,
        col_count: col_count,
        has_header: has_header,
        real_grid: real_grid,
        rows: rows,
        resource: ref
      }) do
    %__MODULE__{
      page: page,
      bbox: bbox,
      col_count: col_count,
      has_header?: has_header,
      real_grid?: real_grid,
      rows: Enum.map(rows, &Row.from_nif/1),
      ref: ref
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
