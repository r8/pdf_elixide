# PdfElixide

[![Elixir CI](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml/badge.svg)](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![Hex.pm](https://img.shields.io/hexpm/dt/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![pdf_oxide](https://img.shields.io/badge/dynamic/toml?url=https://raw.githubusercontent.com/r8/pdf_elixide/main/native/pdf_elixide_nif/Cargo.toml&query=$.dependencies.pdf_oxide&label=pdf_oxide&color=orange&style=flat-square)](https://crates.io/crates/pdf_oxide)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)

Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide), a high-performance PDF library written in Rust. Built on top of [Rustler](https://github.com/rusterlium/rustler).

> ⚠️ **Status:** This project is under active development and the public API is subject to change without notice until a `1.0` release. Expect breaking changes between minor versions.
>
> **Issues and Pull Requests are temporarily disabled.** Since the API is not yet stable, they would only add noise. They will be re-enabled once the API approaches a 1.0 release.

## Features

- Open PDF documents from a file path or an in-memory binary
- Query the PDF specification version
- Get the page count
- Extract text from a specific page
- Extract words with bounding boxes and font metadata
- Extract text lines (each with its bounding box and constituent words)
- Extract AcroForm fields (name, kind, value)
- Fill AcroForm fields and save the result to a file or in-memory binary

## Requirements

- Elixir `~> 1.15`
- Erlang/OTP compatible with the above

The NIF ships as a precompiled binary via
[`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled), so no Rust
toolchain is needed. A stable
[Rust toolchain](https://www.rust-lang.org/tools/install) is only required to
build from source.

## Installation

Add `pdf_elixide` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pdf_elixide, "~> 0.5.0"}
  ]
end
```

Then fetch and compile:

```sh
mix deps.get
mix compile
```

The precompiled NIF is downloaded automatically on first build; no compilation
step is needed.

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
{:ok, text} = Document.text(doc, 0)

# Extract text from the whole document (pages separated by a form-feed).
{:ok, all} = Document.text(doc)

# Source path is the file the document was opened from, or `nil` when it was loaded from a binary.
"path/to/file.pdf" = Document.source_path(doc)
```

Each fallible function ships with a bang variant that returns the value directly and raises on error:

```elixir
doc   = PdfElixide.Document.open!("path/to/file.pdf")
pages = PdfElixide.Document.page_count!(doc)
text  = PdfElixide.Document.text!(doc, 0)
```

### Extracting words

Word extraction keeps the positional and font information that plain text
discards. `PdfElixide.Document.words/2` returns the words of a single page (and
`words/1` returns every page's words as one flat list) as
`%PdfElixide.Document.Word{}` structs:

```elixir
{:ok, words} = PdfElixide.Document.words(doc, 0)

Enum.each(words, fn %PdfElixide.Document.Word{text: text, bbox: bbox} ->
  IO.inspect({text, bbox.x, bbox.y, bbox.width, bbox.height})
end)

# Words are also reachable from a page handle.
{:ok, words} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.words()
```

Each word carries:

- `:text` — the word's text content (`String.t()`)
- `:page` — the zero-based page index the word belongs to (`non_neg_integer()`), which keeps the flat `words/1` list usable since bounding boxes are page-relative
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` with `:x`, `:y`, `:width`, `:height` (points)
- `:font_size` — the average font size (`float()`)
- `:font` — the dominant font name (`String.t()`)
- `:bold?` / `:italic?` — booleans

### Extracting lines

`PdfElixide.Document.text_lines/2` returns the lines of a single page (and
`text_lines/1` returns every page's lines as one flat list) as
`%PdfElixide.Document.TextLine{}` structs. Each line nests its constituent
`%PdfElixide.Document.Word{}` structs:

```elixir
{:ok, lines} = PdfElixide.Document.text_lines(doc, 0)

Enum.each(lines, fn %PdfElixide.Document.TextLine{text: text, words: words} ->
  IO.inspect({text, length(words)})
end)

# Lines are also reachable from a page handle.
{:ok, lines} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.text_lines()
```

Each line carries:

- `:text` — the full line text, its words joined by spaces (`String.t()`)
- `:page` — the zero-based page index the line belongs to (`non_neg_integer()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` spanning the whole line (points)
- `:words` — the line's `%PdfElixide.Document.Word{}` structs (so the word count is `length(line.words)`)

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
