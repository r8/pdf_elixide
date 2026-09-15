defmodule PdfElixide.RedactionReport do
  @moduledoc """
  What a destructive redaction removed, returned by
  `PdfElixide.Editor.apply_redactions/1,2`.

  A redaction that matched nothing returns a report of zeros rather than an
  error, so this is the only evidence that the pass did work. Check
  `:glyphs_removed` before trusting that a document was redacted.

  Counts cover every page the pass touched, not one page — including a page
  that was marked or queued before `PdfElixide.Editor.delete_page/2` removed it,
  which the pass still processes and the written document does not carry.
  """
  @enforce_keys [:regions, :glyphs_removed, :bytes_removed]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          regions: non_neg_integer(),
          glyphs_removed: non_neg_integer(),
          bytes_removed: non_neg_integer()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        regions: regions,
        glyphs_removed: glyphs_removed,
        bytes_removed: bytes_removed
      }) do
    %__MODULE__{
      regions: regions,
      glyphs_removed: glyphs_removed,
      bytes_removed: bytes_removed
    }
  end
end
