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

  Reading a document is open, extract, close:

      doc = PdfElixide.Document.open!("report.pdf")
      text = PdfElixide.Document.text!(doc, 0)
      markdown = PdfElixide.Document.to_markdown!(doc)
      :ok = PdfElixide.Document.close(doc)

  ## Concurrency

  Every handle this library returns may be passed to other processes. A
  document, image, font or table reads through a *shared* lock, so one handle
  serves concurrent reads; an editor mutates, so its calls take the handle
  exclusively and serialize. The full account is the
  [Concurrency](guides/concurrency.md) guide.

  ## File paths

  Every path this library accepts — `PdfElixide.Document.open/2`,
  `PdfElixide.Editor.open/1`, `PdfElixide.Editor.save/3`,
  `PdfElixide.Document.Image.save/3`, and the `:image_output_dir` conversion
  option — is a binary that **must be valid UTF-8**. A path carrying any other
  byte raises `ArgumentError` before the filesystem is touched; it is never an
  `:io` error. See the "Errors versus exceptions" section of `PdfElixide.Error`.

  That is worth knowing on Linux, where the BEAM's default filename encoding
  treats names as raw bytes: a path handed back by `File.ls/1` or
  `Path.wildcard/1` can be a binary no UTF-8 spelling can express, and passing
  it here raises rather than reporting a filesystem error. Read such a file
  yourself and use `PdfElixide.Document.from_binary/2` or
  `PdfElixide.Editor.from_binary/1`, which take opaque bytes. macOS and Windows
  run the VM with UTF-8 filename encoding, so the question does not arise there.

  Only the binary form of `Path.t()` is accepted; a charlist raises
  `FunctionClauseError`. Contrast a *password*, which genuinely is a byte string
  and is decoded as one — see `t:PdfElixide.Document.open_opts/0`.
  """
end
