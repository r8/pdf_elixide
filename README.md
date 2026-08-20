# PdfElixide

[![Elixir CI](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml/badge.svg)](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![Hex.pm](https://img.shields.io/hexpm/dt/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![pdf_oxide](https://img.shields.io/badge/dynamic/toml?url=https://raw.githubusercontent.com/r8/pdf_elixide/main/native/pdf_elixide_nif/Cargo.toml&query=$.dependencies.pdf_oxide.version&label=pdf_oxide&color=orange&style=flat-square)](https://crates.io/crates/pdf_oxide)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](https://github.com/r8/pdf_elixide/blob/main/LICENSE)

Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide), a
high-performance PDF library written in Rust. Built with
[Rustler](https://github.com/rusterlium/rustler).

> ⚠️ **Status:** This project is under active development. The public API may
> change between minor versions until the `1.0` release. The issue tracker is
> currently disabled.

## Features

- Open PDFs from file paths or in-memory binaries
- Read page count, PDF version, metadata, permissions, page labels, outlines,
  optional-content layers, and spot inks
- Extract text, words, lines, characters, and spans with page geometry and
  typographic metadata
- Convert individual pages or whole documents to Markdown or HTML
- Search literal text or regular expressions and locate matches on the page
- Detect tables and render them as Markdown, HTML, or plain text
- Extract vector paths, rectangles, straight lines, raster images, and embedded
  fonts
- Read annotations and AcroForm fields, with check boxes, radio groups, combo
  boxes and the rest classified from their field flags
- Fill AcroForm fields, flatten forms and annotations, and save edited PDFs to a file or binary
- Read what a document's digital signatures claim — signer, time, reason and the
  byte range each covers
- Restrict extraction by region and configure artifacts, layers, inks, reading
  order, table detection, and span merging
- Share one open document across processes for concurrent native reads
- Release document, editor, image, font, and table resources explicitly when
  desired

## Requirements

- Elixir `~> 1.15`
- A compatible Erlang/OTP release

The NIF ships as a precompiled binary through
[`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled), so normal
installation does not require Rust. A stable
[Rust toolchain](https://www.rust-lang.org/tools/install) is needed only when
building the NIF from source.

## Installation

Add `pdf_elixide` to `mix.exs`:

```elixir
def deps do
  [
    {:pdf_elixide, "~> 0.14.0"}
  ]
end
```

Then fetch and compile the dependency:

```sh
mix deps.get
mix compile
```

The precompiled NIF is downloaded automatically on the first build.

## Quick start

### Open and inspect a document

Document inspection lives on `PdfElixide.Document`:

```elixir
alias PdfElixide.Document

doc = Document.open!("path/to/file.pdf")

{1, 7} = Document.version(doc)
{:ok, page_count} = Document.page_count(doc)
{:ok, first_page} = Document.text(doc, 0)
{:ok, all_text} = Document.text(doc)
```

Page indices are zero-based. The version and source path are stored on the
Elixir struct. The page count is also cached when it can be determined while
opening; if not, `page_count/1` asks the open native document.

Most fallible functions have a bang variant that returns the value directly and
raises `PdfElixide.Error` on failure:

```elixir
page_count = Document.page_count!(doc)
text = Document.text!(doc, 0)
```

Documents loaded from memory use the same API:

```elixir
bytes = File.read!("path/to/file.pdf")
doc = Document.from_binary!(bytes)
```

### Extract structured content

Use the extractor that matches the level of detail you need:

```elixir
{:ok, words} = Document.words(doc, 0)
{:ok, lines} = Document.text_lines(doc, 0)
{:ok, spans} = Document.spans(doc, 0)
{:ok, chars} = Document.chars(doc, 0)
```

Each returned struct includes its page and geometry. Words and lines provide a
convenient reading-level view; spans retain PDF text-state runs; characters
retain per-glyph details.

Every extractor is also available from a page value, and a document is
enumerable over its pages:

```elixir
alias PdfElixide.Document.Page

doc
|> Enum.at(0)
|> Page.words!()
```

The same pattern applies to tables, paths, images, fonts, and annotations. See
the [`PdfElixide.Document`](https://hexdocs.pm/pdf_elixide/PdfElixide.Document.html)
documentation for their return types and extraction options.

### Convert to Markdown or HTML

Convert one page or the whole document:

```elixir
{:ok, markdown} = Document.to_markdown(doc)
{:ok, first_page_markdown} = Document.to_markdown(doc, 0)

{:ok, html} = Document.to_html(doc)
{:ok, positioned_html} = Document.to_html(doc, preserve_layout: true)
```

Options control heading and table detection, images, form fields, reading
order, and related conversion behavior. The result of `to_html/1,2,3` is an HTML
fragment rather than a complete document; consult its API documentation before
rendering untrusted paths through `:image_output_dir`.

### Search

Searches return matches with page numbers and bounding boxes:

```elixir
Document.search!(doc, "Figure 3")
Document.search!(doc, "figure 3", 4, case_insensitive: true)
Document.search!(doc, ~S"Figure \d+", literal: false)
```

Patterns are literal by default. Regular expressions use Rust `regex` syntax.
The [Search](guides/search.md) guide covers pattern options, match geometry, and
the per-page search index.

### Fill a form

Open a mutable editor, change existing fields, and save the result:

```elixir
alias PdfElixide.Editor
alias PdfElixide.Form

"path/to/form.pdf"
|> Editor.open!()
|> Form.put_value!("full_name", "Jane Doe")
|> Form.put_value!("subscribe", true)
|> Editor.save!("path/to/filled.pdf")
|> Editor.close()
```

Editing functions return the same mutable editor handle, so rebinding does not
fork its state. `Editor.to_binary/2` returns a PDF binary instead of writing a
file. See the [Forms](guides/forms.md) guide for field kinds and flags, bulk
updates, save behavior, signature fields, and button-field limitations.

### Release native resources

Native memory is released automatically when the BEAM garbage-collects a
handle. Long-lived processes can release it at a chosen point:

```elixir
:ok = Document.close(doc)
true = Document.closed?(doc)

{:error, %PdfElixide.Error{reason: :closed}} = Document.text(doc, 0)
```

`close/1` is idempotent and waits for calls already using the same handle.
Editors, extracted images, fonts, and tables provide the same `close/1` and
`closed?/1` pair. Closing an editor discards unsaved edits; closing a document
does not invalidate images, fonts, or tables already extracted from it. See the
[Concurrency](guides/concurrency.md) guide before sharing handles with workers
that may also close them.

## Documentation

Full API documentation is published on
[HexDocs](https://hexdocs.pm/pdf_elixide).

## License

Released under the [MIT License](https://github.com/r8/pdf_elixide/blob/main/LICENSE).
