defmodule PdfElixide.Document.BookmarkSegment do
  @moduledoc """
  One part of a document split at its bookmarks.

  Returned by `PdfElixide.Document.bookmark_segments/2`,
  `PdfElixide.Editor.bookmark_segments/2` and
  `PdfElixide.Editor.split_by_bookmarks/2`:

    * `:title` — the title of the bookmark that starts the segment, or `nil`
      for the front matter: the pages before the first such bookmark.
    * `:pages` — the zero-based page indices the segment covers, as an inclusive
      range. Pass it in a list to `PdfElixide.Editor.extract_page_ranges/2`, as
      in `[segment.pages]`.
    * `:file_stem` — a portable file name derived from the title, without an
      extension. Empty titles become `"untitled"`, front matter becomes
      `"front-matter"`, and collisions get a ` (2)`, ` (3)` … suffix. Stems are
      safe on common platforms, distinct on case-insensitive file systems and at
      most 80 bytes.

  See [Splitting at bookmarks](guides/merging-and-splitting.md#splitting-at-bookmarks).
  """

  @enforce_keys [:title, :pages, :file_stem]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t() | nil,
          pages: Range.t(),
          file_stem: String.t()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{title: title, first: first, last: last, file_stem: file_stem}) do
    %__MODULE__{title: title, pages: first..last//1, file_stem: file_stem}
  end
end
