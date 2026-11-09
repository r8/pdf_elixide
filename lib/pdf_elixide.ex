defmodule PdfElixide do
  @moduledoc """
  Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide),
  a high-performance PDF library written in Rust.

  The entry points are:

    * `PdfElixide.Document` — read-only access: text and structure
      extraction, search, conversion to Markdown, HTML and Office formats,
      and rendering.
    * `PdfElixide.Editor` — mutable, in-memory editor (open, or create
      from Markdown, HTML, plain text or images; mutate; save).
    * `PdfElixide.Builder` — creates new PDFs with wrapped text, automatic
      page breaks and custom fonts through a content pipeline.
    * `PdfElixide.Form` — AcroForm field access for both documents
      and editors.
    * `PdfElixide.Signature` — read-only: what a document's digital
      signatures claim, whether one verifies against the bytes it covers,
      the certificate and timestamp in one, which fields are still
      unsigned, and the security store. Producing signatures is not
      offered.
    * `PdfElixide.Office` — converts DOCX, PPTX and XLSX files to PDF; the
      exports to those formats are `PdfElixide.Document` functions.
    * `PdfElixide.Compliance` — checks a document against PDF/A, PDF/UA and
      PDF/X, and converts an editor's document to PDF/A.

  `PdfElixide.Error` is what every one of them reports a failure as,
  `PdfElixide.Warning` what they record for a condition they read past, and
  `PdfElixide.Logging` the switch that captures those diagnostics.

  Reading a document is open, extract, close:

      doc = PdfElixide.Document.open!("report.pdf")
      text = PdfElixide.Document.text!(doc, 0)
      markdown = PdfElixide.Document.to_markdown!(doc)
      :ok = PdfElixide.Document.close(doc)

  Editing one is open, mutate, write — and mutating calls return the editor,
  so they compose as a single pipeline:

      "form.pdf"
      |> PdfElixide.Editor.open!()
      |> PdfElixide.Form.put_value!("full_name", "Jane Doe")
      |> PdfElixide.Editor.save!("filled.pdf")
      |> PdfElixide.Editor.close()

  Paired functions return `{:ok, value}` or `{:error, %PdfElixide.Error{}}`;
  their `!` variants return the value or raise. The value is the result, such
  as text or PDF bytes, or the editor for mutations and `PdfElixide.Editor.save/3`.
  `PdfElixide.Editor` lists the mutations that return a report instead.
  Calls without a result, such as `PdfElixide.Builder.save/3` and search-index
  preparation or clearing, return bare `:ok` on success from both variants.

  Builder operations, constructors and accessors such as
  `PdfElixide.Document.source_path/1` return values directly, without tuples.
  Predicates ending in `?` return booleans and generally raise when they cannot
  answer; see `PdfElixide.Error` for exceptions. Closing a handle returns `:ok`
  and cannot fail, so it has no `!` variant.

  ## Concurrency

  Every handle this library returns may be passed to other processes. Documents,
  images, fonts and tables support concurrent reads. Editor mutations serialize;
  its read-only accessors do not all take the same kind of lock. The full account,
  including the exact exceptions, is the [Concurrency](guides/concurrency.md)
  guide.

  ## Untrusted documents

  Excessively nested documents can terminate the operating-system process
  running the VM instead of returning an error, even from a small compressed
  file. Process untrusted documents in a separate operating-system process,
  such as a node started with `:peer`, to protect your application.

  Memory use is unbounded per call and across the node; allocation failure can
  also terminate the OS process. Limit concurrent calls, for example with a pool.
  See [Rendering](guides/rendering.md#sizing-the-output),
  [Office conversion](guides/office.md#memory-and-concurrency) and
  "Whole-document extraction and memory" in `PdfElixide.Document` for ways to
  manage memory use.

  ## File paths

  A path is whatever the operating system calls one, handed to it unchanged. On
  Unix that means an opaque byte string, so a filename with no UTF-8 spelling
  works here just as it does with `File.read/1`, and a path that cannot be
  opened or written is an `:io` error like any other. An editor opened from
  such a path cannot save incrementally; see
  [Saving edits](guides/editing.md#saving-edits).

  **On Windows a path must be valid UTF-8**, and one that is not raises
  `ArgumentError` before the filesystem is touched — see the "Errors versus
  exceptions" section of `PdfElixide.Error`. Every well-formed Windows path has
  a UTF-8 spelling, so this costs nothing in practice. It does mean this
  library is **stricter than `File` there**: a byte sequence `File` would accept
  is refused here rather than written under some other name.

  Only the binary form of `Path.t()` is accepted; a charlist raises
  `FunctionClauseError`.

  ### Writing a file

  A failed save leaves an existing regular file unchanged. Successful saves
  replace it and require a writable directory.

    * Other hard links keep the old contents.
    * Symbolic links are followed and kept in place.
    * On Unix, permission bits are preserved; ownership goes to the user
      running the VM.

  Pipes, devices and descriptor paths such as `/dev/stdout` are written to
  directly. Images can be saved to pipes; PDFs return an `:io` error and leave
  the pipe in place.
  """
end
