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

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP compatible with the above
- A working [Rust toolchain](https://www.rust-lang.org/tools/install) (stable) for compiling the NIF

## Installation

Add `pdf_elixide` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pdf_elixide, "~> 0.2.0"}
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

## Documentation

Full API documentation is published on [HexDocs](https://hexdocs.pm/pdf_elixide).

## License

Released under the [MIT License](https://github.com/r8/pdf_elixide/blob/main/LICENSE).
