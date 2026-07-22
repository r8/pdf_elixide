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
- Extract individual characters with glyph boxes, baseline origins, advances, and color
- Extract spans (runs of text sharing one text state, with the raw PDF text-state parameters)
- Detect tables and read their rows and cells
- Extract vector paths (lines, curves, rectangles) with their drawing operations and stroke/fill style
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
    {:pdf_elixide, "~> 0.6.0"}
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

### Extracting chars

`PdfElixide.Document.chars/2` returns the characters of a single page (and
`chars/1` returns every page's characters as one flat list) as
`%PdfElixide.Document.Char{}` structs. This is the most detailed extraction
level — it keeps the per-glyph typographic data that words and lines flatten
away:

```elixir
{:ok, chars} = PdfElixide.Document.chars(doc, 0)

Enum.map_join(chars, & &1.text)
#=> "Page One"

# Chars are also reachable from a page handle.
{:ok, chars} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.chars()
```

Each character carries:

- `:text` — the character itself, as a one-grapheme string (`String.t()`)
- `:page` — the zero-based page index the character belongs to (`non_neg_integer()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` around the glyph (points)
- `:font_size` — the font size in points (`float()`)
- `:font` — the font name (`String.t()`)
- `:font_weight` — the numeric PDF font weight, `100`–`900` (`non_neg_integer()`)
- `:bold?` / `:italic?` / `:monospace?` — booleans (`bold?` is `font_weight >= 600`)
- `:color` — a `%PdfElixide.Color{}` with `:r`, `:g`, `:b` channels in `0.0..1.0`
- `:origin` — the `{x, y}` baseline origin in points, the typographic reference point (unlike `:bbox`, which is the glyph's box)
- `:rotation` — the rotation in degrees, clockwise from horizontal (`float()`)
- `:advance_width` — the glyph's advance width from the font metrics (`float()`)
- `:rendered_advance` — the actual advance to the next character's origin, including character and word spacing (`float()`); use this, not `:advance_width`, to detect word boundaries
- `:ascent` / `:descent` — the distance from the baseline to the top / bottom of the typographic glyph box in points (`descent` is negative)
- `:mcid` — the marked-content ID for Tagged PDFs (`non_neg_integer()` or `nil`)

### Extracting spans

A *span* is a run of glyphs sharing one text state — the same font, size,
color, and text-state parameters — which is what the PDF content stream
actually emits. It sits between chars and words, and it is the only extraction
level that keeps the raw text-state parameters.
`PdfElixide.Document.spans/2` returns the spans of a single page (and `spans/1`
returns every page's spans as one flat list) as
`%PdfElixide.Document.Span{}` structs:

```elixir
{:ok, spans} = PdfElixide.Document.spans(doc, 0)

Enum.each(spans, fn %PdfElixide.Document.Span{text: text, font: font} ->
  IO.inspect({text, font})
end)

# Spans are also reachable from a page handle.
{:ok, spans} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.spans()
```

Each span carries:

- `:text` — the span's text content (`String.t()`)
- `:page` — the zero-based page index the span belongs to (`non_neg_integer()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` around the whole run (points)
- `:font_size` — the font size in points (`float()`)
- `:font` — the font name (`String.t()`)
- `:font_weight` — the numeric PDF font weight, `100`–`900` (`non_neg_integer()`)
- `:bold?` / `:italic?` / `:monospace?` — booleans (`bold?` is `font_weight >= 600`)
- `:color` — a `%PdfElixide.Color{}` with `:r`, `:g`, `:b` channels in `0.0..1.0`
- `:rotation` — the rotation in degrees, clockwise from horizontal (`float()`)
- `:char_spacing` — the `Tc` character spacing in points (`float()`)
- `:word_spacing` — the `Tw` word spacing in points (`float()`)
- `:horizontal_scaling` — the `Tz` horizontal scaling as a percentage, `100.0` being normal (`float()`)
- `:text_rise` — the `Ts` baseline shift as a ratio of the font size (`float()`); positive is superscript, negative subscript
- `:heading_level` — the heading level `1`–`6` when the span is part of a heading, otherwise `nil`
- `:mcid` — the marked-content ID for Tagged PDFs (`non_neg_integer()` or `nil`)

### Detecting tables

`PdfElixide.Document.tables/2` returns the tables of a single page (and
`tables/1` returns every page's tables as one flat list) as
`%PdfElixide.Document.Table{}` structs. A page with no table gives `{:ok, []}`:

```elixir
{:ok, tables} = PdfElixide.Document.tables(doc, 0)

for table <- tables, table.real_grid? do
  Enum.map(table.rows, fn row -> Enum.map(row.cells, & &1.text) end)
end
#=> [[["Age", "0.042", "0.011", "0.001"], ["Sex", "0.318", "0.142", "0.025"]]]

# Tables are also reachable from a page handle.
{:ok, tables} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.tables()
```

Unlike the text levels above, tables are **detected** — a spatial algorithm
combines text alignment with the page's vector lines, since most PDFs carry no
explicit table markup. Two consequences:

- Detections are a best guess and include occasional false positives (form
  layouts, label-colon-value lists). Each table carries `:real_grid?`, which is
  true when the detection looks like a genuine data grid — at least two rows and
  columns, consistently populated. Filter on it when that matters.
- `:bbox` is `nil` when the detector could not determine an extent, on both
  tables and cells. Every other bounding box in this library is always present.

Each table carries:

- `:page` — the zero-based page index (`non_neg_integer()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` around the table, or `nil`
- `:col_count` — the number of columns, inferred from the first row (`non_neg_integer()`)
- `:has_header?` — whether the table has an explicit header section (`boolean()`)
- `:real_grid?` — whether the detection looks like a genuine data grid (`boolean()`)
- `:rows` — the `%PdfElixide.Document.Table.Row{}` structs

Each row carries `:header?` and its `:cells`. Each cell carries:

- `:text` — the cell's text content (`String.t()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` around the cell, or `nil`
- `:colspan` / `:rowspan` — the number of columns and rows the cell spans (`pos_integer()`)
- `:header?` — whether this is a header cell (`boolean()`)
- `:mcids` — the marked-content IDs making up the cell, for Tagged PDFs (`[non_neg_integer()]`)
- `:spans` — the cell's `%PdfElixide.Document.Span{}` structs, so per-run font, size, and color survive into the table

### Extracting paths

`PdfElixide.Document.paths/2` returns the vector graphics of a single page — the
lines, curves, rectangles, and filled shapes drawn on it (table rulings,
underlines, boxes, diagrams) — as `%PdfElixide.Document.Path{}` structs (and
`paths/1` returns every page's paths as one flat list). A page with no vector
graphics gives `{:ok, []}`:

```elixir
{:ok, paths} = PdfElixide.Document.paths(doc, 0)

for path <- paths do
  IO.inspect(path.operations)
end
#=> [{:move_to, 100.0, 710.0}, {:line_to, 500.0, 710.0}]

# Paths are also reachable from a page handle.
{:ok, paths} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.paths()
```

Each path carries:

- `:page` — the zero-based page index (`non_neg_integer()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` around the path (points)
- `:operations` — the drawing commands in stream order, as flat tagged tuples:
  `{:move_to, x, y}`, `{:line_to, x, y}`,
  `{:curve_to, c1x, c1y, c2x, c2y, ex, ey}` (a cubic Bézier — two control points
  then the endpoint), `{:rectangle, x, y, width, height}`, and `:close_path`
- `:stroke_color` — a `%PdfElixide.Color{}` when the path is stroked, otherwise `nil`
- `:fill_color` — a `%PdfElixide.Color{}` when the path is filled, otherwise `nil`
- `:stroke_width` — the stroke width in points (`float()`)
- `:line_cap` — one of `:butt | :round | :square`
- `:line_join` — one of `:miter | :round | :bevel`
- `:dash_pattern` — `{dash_lengths, phase}` (`{[float()], float()}`) when the
  stroke is dashed, otherwise `nil`
- `:layer` — the Optional Content Group ("layer") name (`String.t()`) when the
  path belongs to one, otherwise `nil`

Colors are always resolved to DeviceRGB. A path can be both stroked and filled,
so `:stroke_color` and `:fill_color` are independent.

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
