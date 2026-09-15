defmodule PdfElixide.SanitizeReport do
  @moduledoc """
  What a sanitization removed, returned by `PdfElixide.Editor.sanitize/1,2`.

  `:roots_removed` counts the catalog entries that were stripped — the XMP
  metadata stream, document JavaScript and the embedded-file name tree — not
  annotations, and not individual values within them. Treat it as evidence that
  the pass did work rather than as an inventory.

  **Clearing `/Info` is not among them.** A document whose only secret is its
  `/Info` dictionary sanitizes to `:roots_removed` of zero while `/Info` is
  scrubbed, so a zero here is not evidence that nothing happened.
  `:bytes_removed` does account for it, and
  `PdfElixide.Editor.metadata/1` is the direct check.

  Sanitizing removes no page content. Use `PdfElixide.Editor.apply_redactions/1,2`
  for that.
  """
  @enforce_keys [:roots_removed, :bytes_removed]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          roots_removed: non_neg_integer(),
          bytes_removed: non_neg_integer()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{roots_removed: roots_removed, bytes_removed: bytes_removed}) do
    %__MODULE__{roots_removed: roots_removed, bytes_removed: bytes_removed}
  end
end
