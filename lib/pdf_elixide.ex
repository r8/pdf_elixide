defmodule PdfElixide do
  @moduledoc """
  Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide),
  a high-performance PDF library written in Rust.

  The public API lives under the submodules:

    * `PdfElixide.Document` — read-only inspection (open, page count,
      version, text extraction).
    * `PdfElixide.Editor` — mutable, in-memory editor (open, mutate,
      save).
    * `PdfElixide.Form` — AcroForm field access for both documents
      and editors.
  """
end
