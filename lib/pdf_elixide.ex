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

  Editing one is open, mutate, write — and every mutating call returns the
  editor, so it composes as a single pipeline:

      "form.pdf"
      |> PdfElixide.Editor.open!()
      |> PdfElixide.Form.put_value!("full_name", "Jane Doe")
      |> PdfElixide.Editor.save!("filled.pdf")
      |> PdfElixide.Editor.close()

  ## Concurrency

  Every handle this library returns may be passed to other processes. Documents,
  images, fonts and tables support concurrent reads. Editor mutations serialize;
  its read-only accessors do not all take the same kind of lock. The full account,
  including the exact exceptions, is the [Concurrency](guides/concurrency.md)
  guide.

  ## File paths

  A path is whatever the operating system calls one, handed to it unchanged. On
  Unix that means an opaque byte string, so a filename with no UTF-8 spelling
  works here just as it does with `File.read/1`, and a path that cannot be
  opened or written is an `:io` error like any other.

  **On Windows a path must be valid UTF-8**, and one that is not raises
  `ArgumentError` before the filesystem is touched — see the "Errors versus
  exceptions" section of `PdfElixide.Error`. Every well-formed Windows path has
  a UTF-8 spelling, so this costs nothing in practice — but it does make this
  library **stricter than `File` there**, which will translate a stray byte into
  some legal filename and write it rather than refuse.

  Only the binary form of `Path.t()` is accepted; a charlist raises
  `FunctionClauseError`.
  """
end
