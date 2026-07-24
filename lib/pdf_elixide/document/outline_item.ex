defmodule PdfElixide.Document.OutlineItem do
  @moduledoc """
  A single item (bookmark) in a PDF document's outline — its table of contents.

  Outline items form a tree: each item carries a `:title`, an optional
  destination, and a list of nested `:children` (sub-bookmarks). The document's
  outline is the list of top-level items returned by `PdfElixide.Document.outline/1`.

  The `:dest` field is where the item points, as one of:

    * `{:page, page_index}` — a zero-based page index within the document
    * `{:named, name}` — a named destination that could not be resolved to a
      page index (the raw name string is preserved)
    * `nil` — the item has no determinable destination

  Named destinations are only surfaced when `pdf_oxide` could not resolve them;
  resolvable ones already arrive as `{:page, page_index}`.
  """

  @typedoc "Where an outline item points."
  @type dest ::
          {:page, non_neg_integer()}
          | {:named, String.t()}
          | nil

  @enforce_keys [:title, :dest, :children]

  defstruct [
    :title,
    :dest,
    :children
  ]

  @type t :: %__MODULE__{
          title: String.t(),
          dest: dest(),
          children: [t()]
        }

  @doc false
  # Builds an `OutlineItem` from the raw map returned by the NIF. `:title` and
  # `:dest` already arrive in their final shapes (a string and a tagged tuple or
  # `nil`); only the nested child maps need to be converted recursively.
  @spec from_nif(map()) :: t()
  def from_nif(%{title: title, dest: dest, children: children}) do
    %__MODULE__{
      title: title,
      dest: dest,
      children: Enum.map(children, &from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.OutlineItem{title: title, children: children}, _opts) do
      count = length(children)

      concat([
        "#PdfElixide.Document.OutlineItem<",
        inspect(title),
        " ",
        to_string(count),
        if(count == 1, do: " child>", else: " children>")
      ])
    end
  end
end
