# PdfElixide

[![Elixir CI](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml/badge.svg)](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![Hex.pm](https://img.shields.io/hexpm/dt/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)

Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide), a high-performance PDF library written in Rust. Built on top of [Rustler](https://github.com/rusterlium/rustler).

> ⚠️ **Status:** This project is under active development and the public API is subject to change without notice until a `1.0` release. Expect breaking changes between minor versions.

## Features

- Open PDF documents from a file path or an in-memory binary
- Query the PDF specification version
- Get the page count
- Extract text from a specific page
- Extract AcroForm fields (name, kind, value)
- Fill AcroForm fields and save the result to a file or in-memory binary

## Requirements

- Elixir `~> 1.15`
- Erlang/OTP compatible with the above
- A working [Rust toolchain](https://www.rust-lang.org/tools/install) (stable) for compiling the NIF

## Installation

Add `pdf_elixide` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pdf_elixide, "~> 0.3.0"}
  ]
end
```

Then fetch and compile:

```sh
mix deps.get
mix compile
```

The Rust NIF is compiled automatically by Rustler on first build.

## Usage

### Opening a document

Document inspection lives on `PdfElixide.Document` (open, version,
page count, text extraction).

```elixir
# Open from a file path
{:ok, doc} = PdfElixide.Document.open("path/to/file.pdf")

# Or from an in-memory binary
{:ok, bytes} = File.read("path/to/file.pdf")
{:ok, doc}   = PdfElixide.Document.from_binary(bytes)
```

### Inspecting a document

```elixir
alias PdfElixide.Document

# Version is read directly from the struct — returned as a {major, minor} tuple.
{1, 4} = Document.version(doc)

# Page count is fetched from the underlying PDF and may fail.
{:ok, 3} = Document.page_count(doc)

# Extract text from a single page (zero-based index).
{:ok, text} = Document.extract_text(doc, 0)

# Source path is the file the document was opened from, or `nil` when it was loaded from a binary.
"path/to/file.pdf" = Document.source_path(doc)
```

Each fallible function ships with a bang variant that returns the value directly and raises on error:

```elixir
doc   = PdfElixide.Document.open!("path/to/file.pdf")
pages = PdfElixide.Document.page_count!(doc)
text  = PdfElixide.Document.extract_text!(doc, 0)
```

### Extracting form fields

`PdfElixide.Form.fields/1` returns the AcroForm fields of the document as a list of `%PdfElixide.Form.Field{}` structs:

```elixir
{:ok, fields} = PdfElixide.Form.fields(doc)

Enum.each(fields, fn %PdfElixide.Form.Field{name: name, kind: kind, value: value} ->
  IO.inspect({name, kind, value})
end)
```

Each field carries:

- `:name` — the field's PDF name (`String.t()`)
- `:kind` — one of `:button | :text | :choice | :signature | :unknown`
- `:value` — one of `{:text, String.t()} | {:boolean, boolean()} | {:name, String.t()} | {:array, [String.t()]} | nil`

A bang variant, `PdfElixide.Form.fields!/1`, returns the list directly and raises on error.

### Filling form fields

To modify a PDF, open it as a `PdfElixide.Editor` instead of a `PdfElixide.Document`,
set values with `PdfElixide.Form.set_value/3`, then persist the result with
`PdfElixide.Editor.save/3` (file) or `PdfElixide.Editor.to_binary/2` (in-memory).

```elixir
alias PdfElixide.Editor
alias PdfElixide.Form

{:ok, editor} = Editor.open("path/to/form.pdf")

# Values use the same tagged-tuple shape returned by Form.fields/1.
:ok = Form.set_value(editor, "full_name", {:text, "Jane Doe"})
:ok = Form.set_value(editor, "subscribe", {:boolean, true})

# Write the filled PDF to disk.
:ok = Editor.save(editor, "path/to/filled.pdf")

# Or get the bytes back for streaming / storage.
{:ok, bytes} = Editor.to_binary(editor)
```

Both `save/3` and `to_binary/2` accept a keyword list of options
(`:incremental`, `:compress`, `:linearize`, `:garbage_collect`). For
form filling against an existing PDF, an incremental save preserves the
original AcroForm structure and only appends the field-value updates:

```elixir
:ok = Editor.save(editor, "path/to/filled.pdf", incremental: true)
```

Bang variants `Editor.open!/1`, `Editor.save!/3`, `Editor.to_binary!/2`,
and `Form.set_value!/3` raise on error.

## Documentation

Full API documentation is published on [HexDocs](https://hexdocs.pm/pdf_elixide).

## License

Released under the [MIT License](https://github.com/r8/pdf_elixide/blob/main/LICENSE).
