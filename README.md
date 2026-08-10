# PdfElixide

[![Elixir CI](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml/badge.svg)](https://github.com/r8/pdf_elixide/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![Hex.pm](https://img.shields.io/hexpm/dt/pdf_elixide.svg?style=flat-square)](https://hex.pm/packages/pdf_elixide)
[![pdf_oxide](https://img.shields.io/badge/dynamic/toml?url=https://raw.githubusercontent.com/r8/pdf_elixide/main/native/pdf_elixide_nif/Cargo.toml&query=$.dependencies.pdf_oxide&label=pdf_oxide&color=orange&style=flat-square)](https://crates.io/crates/pdf_oxide)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](https://github.com/r8/pdf_elixide/blob/main/LICENSE)

Elixir bindings for [pdf_oxide](https://crates.io/crates/pdf_oxide), a high-performance PDF library written in Rust. Built on top of [Rustler](https://github.com/rusterlium/rustler).

> ⚠️ **Status:** This project is under active development and the public API is subject to change without notice until a `1.0` release. Expect breaking changes between minor versions.
>
> **Issues and Pull Requests are temporarily disabled.** Since the API is not yet stable, they would only add noise. They will be re-enabled once the API approaches a 1.0 release.

## Features

- Open PDF documents from a file path or an in-memory binary
- Query the PDF specification version
- Get the page count
- Extract text from a specific page
- Convert a page or the whole document to Markdown, with headings, tables, images, and reading order under your control
- Convert a page or the whole document to HTML, either as semantic markup or as absolutely positioned spans carrying each fragment's PDF coordinates
- Extract words with bounding boxes and font metadata
- Extract text lines (each with its bounding box and constituent words)
- Extract individual characters with glyph boxes, baseline origins, advances, and color
- Extract spans (runs of text sharing one text state, with the raw PDF text-state parameters)
- Search the whole document or one page for literal text or a regular expression, with each match located on the page
- Detect tables, read their rows and cells, and render one as Markdown, HTML, or plain text
- Extract vector paths (lines, curves, rectangles) with their drawing operations and stroke/fill style, or just the rectangles or straight lines among them
- Read the document outline (bookmarks / table of contents) as a nested tree
- Extract raster images (photos, logos, scans) with their on-page geometry, encoding them to PNG or JPEG on demand
- Extract the fonts a page uses (type, encoding, weight) and pull out embedded font programs
- Read annotations (links, notes, highlights, form widgets) with their geometry, contents, colors, and flags
- Extract AcroForm fields — one struct per field type, with the field's name and value
- Fill AcroForm fields and save the result to a file or in-memory binary — every
  editing call returns the editor, so filling and saving composes as one pipeline
- Read document metadata — both the `/Info` dictionary and the XMP packet
- Read encryption permission flags (print, copy, modify, …)
- Read logical page labels (roman numerals, prefixes, etc.)
- Tune every text extractor: restrict to a region, drop optional-content layers,
  spot inks or `/Artifact` headers, and configure the table detector and the
  span merger
- List a document's optional-content (OCG) layer names and a page's
  Separation/DeviceN ink names — the vocabulary those filters accept
- Share one open document across processes: reads take the native handle's lock
  shared, so a worker pool extracts from a single document concurrently

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
    {:pdf_elixide, "~> 0.12.0"}
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

# Page count comes back with the handle from the call that opened the document
# and is served from the struct, like the version.
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

### Converting to Markdown

`to_markdown` turns a page — or the whole document — into structured Markdown,
detecting headings and tables rather than returning the flat text stream that
`text/1` gives you.

```elixir
alias PdfElixide.Document

# The whole document, pages joined by a `---` thematic break.
{:ok, markdown} = Document.to_markdown(doc)

# A single page (zero-based index).
{:ok, markdown} = Document.to_markdown(doc, 0)

# Either form takes options.
{:ok, markdown} = Document.to_markdown(doc, detect_headings: false)
{:ok, markdown} = Document.to_markdown(doc, 0, extract_tables: false)

# And from a page struct.
{:ok, markdown} = Document.Page.to_markdown(Document.page!(doc, 0))
```

The defaults mirror `pdf_oxide`'s own, so `to_markdown(doc)` and
`to_markdown(doc, [])` are equivalent. The full option list — heading detection,
table extraction, image embedding, form-field inlining, running header/footer
stripping, ligature expansion, reading order, and bold-marker behaviour — is
documented under `t:PdfElixide.Document.markdown_opts/0`.

### Converting to HTML

`to_html` mirrors `to_markdown`, emitting HTML instead: `<h1>`–`<h6>` for
detected headings, `<table>` for detected tables, and `<img>` for images.

```elixir
alias PdfElixide.Document

# The whole document, each page wrapped in <div class="page" data-page="N">.
{:ok, html} = Document.to_html(doc)

# A single page (zero-based index), with no page wrapper.
{:ok, html} = Document.to_html(doc, 0)

# Either form takes options.
{:ok, html} = Document.to_html(doc, detect_headings: false)
{:ok, html} = Document.to_html(doc, 0, extract_tables: false)

# One absolutely positioned div per text span instead of semantic markup.
{:ok, html} = Document.to_html(doc, preserve_layout: true)

# And from a page struct.
{:ok, html} = Document.Page.to_html(Document.page!(doc, 0))
```

The result is a *fragment*: no doctype, no `<html>`/`<body>`, and no stylesheet,
so you supply the surrounding page. Options are the subset of the Markdown ones
that `pdf_oxide` actually applies while converting to HTML, plus the HTML-only
`:preserve_layout` — see `t:PdfElixide.Document.html_opts/0`.

Text taken from the PDF is escaped before it reaches the fragment, and a `/Link`
annotation becomes an anchor only for a safe scheme — so the fragment is safe to
render as raw HTML. The single exception is `:image_output_dir`, which upstream
interpolates into `src` unescaped, so that path must be yours rather than
untrusted input. `PdfElixide.Document.to_html/2` documents both in full.

`:preserve_layout` output is positioned but not ready to render: the coordinates
are raw PDF user-space values, measured from the *bottom* of the page, so you
flip them yourself (`top = height - y`) and give each page wrapper
`position: relative` and a size. The typedoc covers both corrections.

### Releasing a document

A document keeps its PDF data in memory on the Rust side. That memory is freed
when the BEAM garbage-collects the handle, so for most programs there is nothing
to do. In a long-lived process that opens many documents, `close/1` frees it at a
point you choose instead:

```elixir
doc = PdfElixide.Document.open!("path/to/file.pdf")
text = PdfElixide.Document.text!(doc, 0)

:ok = PdfElixide.Document.close(doc)
true = PdfElixide.Document.closed?(doc)

# Reading a closed document is an ordinary error, not a crash.
{:error, %PdfElixide.Error{reason: :closed}} = PdfElixide.Document.text(doc, 0)

# `version/1`, `source_path/1` and `page_count/1` keep answering — they read the
# struct rather than the native handle.
{:ok, 3} = PdfElixide.Document.page_count(doc)
```

`close/1` is idempotent, and `PdfElixide.Editor`, `PdfElixide.Document.Image`,
`PdfElixide.Document.Font` and `PdfElixide.Document.Table` handles have the same
pair of functions. Closing an editor discards unsaved edits, so save first.
Images, fonts and tables already extracted from a document own their data
independently — closing the document leaves them usable, and vice versa.

`close/1` takes the handle exclusively, where reads take it shared, so it waits
for calls already in flight rather than interrupting them — see the
[Concurrency](guides/concurrency.md) guide.

### Reading the outline

`PdfElixide.Document.outline/1` reads the document's outline — its bookmarks or
table of contents — as a tree of `%PdfElixide.Document.OutlineItem{}` structs.
A document with no outline gives `{:ok, []}`:

```elixir
{:ok, items} = PdfElixide.Document.outline(doc)

# Walk the tree — each item may carry nested `:children`.
defmodule TOC do
  def print(items, depth \\ 0) do
    for %{title: title, dest: dest, children: children} <- items do
      IO.puts(String.duplicate("  ", depth) <> "#{title} (#{inspect(dest)})")
      print(children, depth + 1)
    end
  end
end

TOC.print(items)
# Chapter 1 ({:page, 0})
#   Section 1.1 ({:page, 1})
# Chapter 2 ({:page, 2})
```

Each outline item carries:

- `:title` — the bookmark label (`String.t()`)
- `:dest` — where it points, as one of:
  - `{:page, page_index}` — a zero-based page index
  - `{:named, name}` — a named destination that could not be resolved to a page
    (the raw name is preserved)
  - `nil` — no determinable destination
- `:children` — the nested `%PdfElixide.Document.OutlineItem{}` structs

### Reading metadata, permissions, and page labels

`PdfElixide.Document.metadata/1` reads the classic `/Info` dictionary into a
`%PdfElixide.Document.Metadata{}` struct. Every field is optional; a document
without an `/Info` dictionary yields a struct with all fields `nil`:

```elixir
{:ok, meta} = PdfElixide.Document.metadata(doc)
meta.title    # => "Test Title"
meta.author   # => "Jane Doe"
meta.producer # => "pdf_elixide"
# Dates are the raw PDF date strings, e.g. "D:20240115120000Z".
```

`PdfElixide.Document.xmp_metadata/1` reads the XML-based XMP packet many modern
PDFs carry instead of, or in addition to, the Info dictionary. It returns
`{:ok, nil}` when the document has no XMP packet:

```elixir
{:ok, xmp} = PdfElixide.Document.xmp_metadata(doc)
xmp.title    # => "Test Title"
xmp.creators # => ["Jane Doe"]   (XMP models authors/subjects as lists)
xmp.subjects # => ["alpha", "beta"]
xmp.raw_xml  # => the original XMP packet, as an escape hatch
```

`PdfElixide.Document.permissions/1` reads the `/P` permission flags of an
encrypted document, returning `{:ok, nil}` for an unencrypted one. Per the PDF
spec these flags are advisory:

```elixir
{:ok, perms} = PdfElixide.Document.permissions(doc)
perms.copy           # => false
perms.print_high_res # => true
```

`PdfElixide.Document.page_labels/1` returns the logical page labels — one per
page, in page order — falling back to decimal page numbers where none are
declared. `PdfElixide.Document.Page.label/1` reads a single page's label:

```elixir
{:ok, ["i", "ii", "1", "2"]} = PdfElixide.Document.page_labels(doc)
{:ok, "i"} = PdfElixide.Document.Page.label(PdfElixide.Document.page!(doc, 0))
```

### Tuning extraction

The six text-family extractors — `text`, `chars`, `words`, `text_lines`,
`spans` and `tables` — all take an optional keyword list, in the same shape as
`to_markdown/2,3`: a list means "the whole document", a zero-based integer
means "this page", and both can be followed by options.

```elixir
# Restrict extraction to a region — any extracted bbox works as one.
{:ok, [heading | _]} = PdfElixide.Document.text_lines(doc, 0)
{:ok, words} = PdfElixide.Document.words(doc, 0, region: heading.bbox)

# ...with a stricter containment rule than the default :intersects.
{:ok, words} =
  PdfElixide.Document.words(doc, 0, region: heading.bbox, region_mode: :fully_contained)

# Drop /Artifact-tagged running headers, footers and watermarks (ISO 32000-1
# §14.8.2.2.1), an optional-content layer, or a spot ink.
{:ok, words} = PdfElixide.Document.words(doc, 0, include_artifacts: false)
{:ok, text} = PdfElixide.Document.text(doc, 0, exclude_layers: ["Watermark"])
{:ok, text} = PdfElixide.Document.text(doc, 0, exclude_inks: ["PANTONE 185 C"])

# ...and ask the document which names those two filters will act on.
{:ok, ["Watermark"]} = PdfElixide.Document.layers(doc)
{:ok, inks} = PdfElixide.Document.inks(doc, 0)             # this page's own resources
{:ok, inks} = PdfElixide.Document.inks(doc, 0, deep: true) # plus its Form XObjects

# Tune the spatial table detector when a page yields no table, or too many.
{:ok, tables} =
  PdfElixide.Document.tables(doc, 0, preset: :strict, min_table_cells: 6)

# Every option is available from a page handle too.
{:ok, tables} =
  doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.tables(preset: :relaxed)
```

Each function documents its own list — `t:PdfElixide.Document.text_opts/0`,
`words_opts/0`, `text_lines_opts/0`, `chars_opts/0`, `spans_opts/0` and
`tables_opts/0` — including a few combinations `pdf_oxide` cannot serve at
once, where the typedoc names exactly which options get dropped. Options are
validated strictly: an unknown key, a wrong-typed value and an out-of-range
value all raise `ArgumentError` naming the offending key, so a typo is
reported rather than silently doing nothing. `%PdfElixide.Error{}` is reserved
for failures of the document, the filesystem or the handle.

### Whole-document forms and memory

Every extractor's whole-document arity walks all pages in a single native call
and returns one flat list, so its cost scales with the document rather than with
what you keep. At the moment the call returns, the results exist twice — as the
native vector and as the Elixir terms encoded from it — so peak usage is roughly
double the final list. `chars/1` is the extreme, one struct per glyph; `spans/1`
describes the same text in runs and is usually the cheaper way to ask.

Three of them hold native memory after the call as well, because each returned
struct carries a handle: `images/1` keeps every image's pixels (or its original
JPEG bytes) resident from extraction onward, `fonts/1` mints one handle per page
per font with no sharing across pages, and `tables/1` keeps each detected table
whole. Release them with `close/1` as you finish with each — see
[Releasing a document](#releasing-a-document).

`PdfElixide.Document` implements `Enumerable` over its pages and
`PdfElixide.Document.Page` offers every extractor, so bounding memory needs no
extra API:

```elixir
alias PdfElixide.Document.Page

# Constant memory — each page's chars become garbage when the function returns.
total = Enum.reduce(doc, 0, fn page, acc -> acc + length(Page.chars!(page)) end)

# Or as a lazy sequence.
doc |> Stream.flat_map(&Page.chars!/1) |> Enum.take(100)
```

One page is the floor: a page's own results are still built and encoded whole.
Concatenating pages this way matches the whole-document arity exactly for the
list-returning extractors, but not for `text/1`, `to_markdown/1` or `to_html/1`,
each of which joins its pages with a separator of its own.

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
- `:color` — a `%PdfElixide.Color.RGB{}` with `:r`, `:g`, `:b` channels in `0.0..1.0`
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
- `:color` — a `%PdfElixide.Color.RGB{}` with `:r`, `:g`, `:b` channels in `0.0..1.0`
- `:rotation` — the rotation in degrees, clockwise from horizontal (`float()`)
- `:char_spacing` — the `Tc` character spacing in points (`float()`)
- `:word_spacing` — the `Tw` word spacing in points (`float()`)
- `:horizontal_scaling` — the `Tz` horizontal scaling as a percentage, `100.0` being normal (`float()`)
- `:text_rise` — the `Ts` baseline shift as a ratio of the font size (`float()`); positive is superscript, negative subscript
- `:heading_level` — the heading level `1`–`6` when the span is part of a heading, otherwise `nil`
- `:mcid` — the marked-content ID for Tagged PDFs (`non_neg_integer()` or `nil`)

### Searching text

`PdfElixide.Document.search/2` finds every occurrence of a pattern in the
document, and `search/3` searches a single page.

```elixir
Document.search!(doc, "Figure 3")
#=> [%PdfElixide.Document.SearchMatch{page: 4, text: "Figure 3", bbox: %Rect{…}}]

Document.search!(doc, "figure 3", 4, case_insensitive: true)
Document.search!(doc, ~S"Figure \d+", literal: false)
```

The pattern is plain text unless `literal: false` is given — the opposite of
`pdf_oxide`'s own default. Both arities are also reachable from a page handle.
See the [Search](guides/search.md) guide for the pattern syntax, what a match's
boxes cover, and the per-page index searching builds.

### Detecting tables

`PdfElixide.Document.tables/2` returns the tables of a single page (and
`tables/1` returns every page's tables as one flat list) as
`%PdfElixide.Document.Table{}` structs. A page with no table gives `{:ok, []}`:

```elixir
alias PdfElixide.Document.Table

{:ok, [table | _]} = PdfElixide.Document.tables(doc, 0)

Table.cell_text(table, 0, 0)
#=> "Age"

Enum.map(table, fn row -> Enum.map(row, & &1.text) end)
#=> [["Age", "0.042", "0.011", "0.001"], ["Sex", "0.318", "0.142", "0.025"], ...]

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

### Rendering a single table

A detected table renders on its own, in any of the three formats the
whole-document converters use:

```elixir
Table.to_markdown(table)
#=> {:ok, "| Age | 0.042 | 0.011 | 0.001 |\n|---|---|---|---|\n| Sex | ..."}

Table.to_html(table)
#=> {:ok, "<table>\n<tbody>\n<tr><td>Age</td><td>0.042</td>..."}

Table.to_text(table)
#=> {:ok, "Age       0.042  0.011  0.001\nSex       0.318  0.142  0.025\n..."}

# Markdown takes one option: :conservative (the default) applies ** only to
# content-bearing text, :aggressive also wraps whitespace-only bold spans.
Table.to_markdown(table, bold_markers: :aggressive)
```

Each has a bang variant, and the output is the same block
`PdfElixide.Document.to_markdown/2` and `to_html/2` emit for that table within
its page — the same renderer produces both.

Rendering goes through the table's `:ref`, a handle to the detected table held on
the Rust side, so it works only on a table that came from extraction, and
`Table.close/1` releases it early when you are walking many tables and keeping
only their text. The struct's own rows and cells stay readable afterwards.

Two upstream quirks are worth knowing. Markdown requires a header row, so
`to_markdown/2` renders the first row as one even when `:has_header?` is false.
And while `:colspan` widens a cell into extra columns there, `:rowspan` is ignored
— `to_html/1` is the one that carries both as attributes.

Rather than walking those lists by hand, reach into a table with the accessors:

- `Table.cell/3` — the `%Table.Cell{}` at a zero-based row and column
- `Table.cell_text/3` — just that cell's text
- `Table.row/2` and `Table.row_count/1` — the `%Table.Row{}` at an index, and how many there are
- `Table.Row.cell/2` and `Table.Row.cell_text/2` — the same, within a single row

Indices are positions — the row within `:rows`, the column within that row's
`:cells` — so they reach exactly what `Enum.at/2` would. The detector drops the
cells a merge covers without leaving a placeholder, so a row containing a cell
whose `:colspan` or `:rowspan` is greater than one stores fewer cells than
`:col_count`, and positions after the merge no longer line up with the visual
column. Every accessor except `row_count/1` returns `nil` when the index falls
outside the table (a negative or non-integer index raises `FunctionClauseError`),
so none of them has a bang variant.

Tables and rows are also `Enumerable` — a table over its rows, a row over its
cells — which is where the nested `Enum.map/2` above comes from.

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
- `:stroke_color` — a `%PdfElixide.Color.RGB{}` when the path is stroked, otherwise `nil`
- `:fill_color` — a `%PdfElixide.Color.RGB{}` when the path is filled, otherwise `nil`
- `:stroke_width` — the stroke width in points (`float()`)
- `:line_cap` — one of `:butt | :round | :square`
- `:line_join` — one of `:miter | :round | :bevel`
- `:dash_pattern` — `{dash_lengths, phase}` (`{[float()], float()}`) when the
  stroke is dashed, otherwise `nil`
- `:layer` — the Optional Content Group ("layer") name (`String.t()`) when the
  path belongs to one, otherwise `nil`

Colors are always resolved to DeviceRGB during extraction, which is why these
are typed `%PdfElixide.Color.RGB{}` specifically rather than the wider
`PdfElixide.Color` union. A path can be both stroked and filled, so
`:stroke_color` and `:fill_color` are independent.

#### Just the rectangles, or just the lines

`rects/1,2` and `lines/1,2` return the same structs narrowed to the paths that
draw a rectangle or a single straight segment — table rulings, underlines, cell
borders — without your having to classify `operations` yourself:

```elixir
{:ok, rules} = PdfElixide.Document.lines(doc, 0)
{:ok, boxes} = PdfElixide.Document.rects(doc, 0)

# Both are also reachable from a page handle.
{:ok, rules} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.lines()
```

The classification reads the drawing commands rather than the geometry, and it
accepts a few shapes you might not expect while rejecting one you would — read
the "Rectangles and straight lines" section of `PdfElixide.Document.Path` before
relying on it. Note `lines/2` is vector graphics; `text_lines/2` above is the
unrelated text extractor.

### Extracting images

`PdfElixide.Document.images/2` returns the raster images of a single page — the
photos, logos, and scanned pictures drawn on it — as
`%PdfElixide.Document.Image{}` structs (and `images/1` returns every page's
images as one flat list). A page with no images gives `{:ok, []}`:

```elixir
{:ok, images} = PdfElixide.Document.images(doc, 0)

for image <- images do
  PdfElixide.Document.Image.save(image, "page0-#{image.width}x#{image.height}.png")
end

# Images are also reachable from a page handle.
{:ok, images} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.images()
```

Each image carries:

- `:page` — the zero-based page index (`non_neg_integer()`)
- `:bbox` — a `%PdfElixide.Geometry.Rect{}` giving where the image sits on the
  page (points), or `nil` when the placement is unknown
- `:width` / `:height` — the image's pixel dimensions (`non_neg_integer()`)
- `:format` — how the image was **stored** in the PDF: `:jpeg` (a JPEG blob) or
  `:raw` (decoded pixels)
- `:ref` — an opaque handle to the underlying image, used by the encode/save
  functions below
- `:color_space` — how the image was stored, as an atom: `:device_rgb`,
  `:device_gray`, `:device_cmyk`, `:indexed`, `:cal_gray`, `:cal_rgb`, `:lab`,
  `:icc_based`, `:separation`, `:device_n`, or `:pattern`
- `:bits_per_component` — the stored bit depth per component (`non_neg_integer()`)
- `:rotation_degrees` — the image's rotation on the page (`integer()`)

The pixel data is encoded on demand — mirroring `PdfElixide.Editor` — with
`PdfElixide.Document.Image.to_binary/2` (in-memory bytes) and
`PdfElixide.Document.Image.save/3` (to a file), each taking a `format: :png |
:jpeg` option (`:png` is the default for `to_binary/2`):

```elixir
image = hd(images)

{:ok, png} = PdfElixide.Document.Image.to_binary(image)               # PNG bytes
{:ok, jpg} = PdfElixide.Document.Image.to_binary(image, format: :jpeg)

# save/3 infers the format from the extension; :format overrides it.
:ok = PdfElixide.Document.Image.save(image, "out.png")
:ok = PdfElixide.Document.Image.save(image, "thumb.bin", format: :jpeg)
```

Encoding always produces a valid file, whatever the stored codec (JPEG, CCITT
bilevel, CMYK, indexed palette, ...). JPEG output is lossless pass-through for a
`:jpeg`-stored image (the original bytes are returned untouched) except CMYK
JPEGs, which are re-encoded to RGB. Bang variants (`to_binary!/2`, `save!/3`)
raise instead of returning `{:error, _}`.

For the **raw stored bytes** (rather than a re-encoded image), use
`PdfElixide.Document.Image.data/1`:

```elixir
case PdfElixide.Document.Image.data(image) do
  {:ok, {:jpeg, bytes}} -> bytes             # the original JPEG blob (zero loss)
  {:ok, {:raw, pixels, format}} -> pixels    # bare pixels; format is :rgb | :grayscale | :cmyk
end
```

`{:raw, ...}` bytes are uncompressed pixels, not a standalone file — interpret
them with `:width`, `:height`, and `:color_space`, or use `to_binary/2` when you
want an encoded PNG/JPEG.

### Extracting fonts

`PdfElixide.Document.fonts/2` returns the fonts referenced by a single page as
`%PdfElixide.Document.Font{}` structs (and `fonts/1` returns every page's fonts
as one flat list, so a font used on several pages appears once per page). A page
that references no fonts gives `{:ok, []}`:

```elixir
{:ok, fonts} = PdfElixide.Document.fonts(doc, 0)

# Fonts are also reachable from a page handle.
{:ok, fonts} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.fonts()
```

Each font carries:

- `:page` — the zero-based page index (`non_neg_integer()`)
- `:resource_name` — the page's font resource id, e.g. `"F1"` (`String.t()`)
- `:base_font` — the face name, with any six-letter subset prefix (`ABCDEF+`)
  stripped (`String.t()`)
- `:subtype` — the PDF font type: `"Type1"`, `"TrueType"`, or `"Type0"`
- `:encoding` — `{:standard, name}` for a named base encoding (e.g.
  `"WinAnsiEncoding"`), or `:custom` / `:identity`
- `:embedded?` — whether the font program is embedded in the document
- `:subset?` — whether the font is subsetted (carried a subset prefix)
- `:weight` — the FontDescriptor weight (400 normal, 700 bold), or `nil`
- `:bold?` / `:italic?` — booleans derived from the font's descriptor and name
- `:ref` — an opaque handle to the font, used by `data/1` below

For an **embedded** font, `PdfElixide.Document.Font.data/1` pulls out the raw font
program — the TrueType / OpenType bytes, suitable for re-embedding elsewhere. A
non-embedded font (e.g. one of the standard 14) gives `{:ok, nil}`:

```elixir
font = Enum.find(fonts, & &1.embedded?)

case PdfElixide.Document.Font.data(font) do
  {:ok, nil} -> :not_embedded
  {:ok, bytes} -> File.write!("#{font.base_font}.otf", bytes)
end
```

`data!/1` returns the bytes (or `nil`) directly, raising on error.

### Reading annotations

`PdfElixide.Document.annotations/2` returns the annotations on a single page as
`%PdfElixide.Document.Annotation{}` structs (and `annotations/1` returns every
page's annotations as one flat list). A page with no annotations gives
`{:ok, []}`:

```elixir
{:ok, annotations} = PdfElixide.Document.annotations(doc, 0)

# Annotations are also reachable from a page handle.
{:ok, annotations} = doc |> PdfElixide.Document.page!(0) |> PdfElixide.Document.Page.annotations()
```

Each annotation carries its `:page` index, a parsed `:subtype` atom (`:link`,
`:text`, `:highlight`, `:widget`, …), its `:rect` (a `%PdfElixide.Geometry.Rect{}`),
`:contents`, `:author`, dates, `:opacity`, and more. Unlike text and path
colors, annotation colors carry the raw `/C` (or `/IC`) components, so any of
the `PdfElixide.Color` structs can appear — decoded by component count, since
the array itself names no colorspace:

```elixir
%PdfElixide.Color.RGB{r: 1.0, g: 0.0, b: 0.0}              # 3 components
%PdfElixide.Color.Gray{gray: 0.5}                          # 1 component
%PdfElixide.Color.CMYK{c: 0.0, m: 0.0, y: 0.0, k: 1.0}     # 4 components
%PdfElixide.Color.Unknown{components: [0.25, 0.75]}        # any other count
```

A count-based guess can be wrong — a one-component `/C` in a Separation space
reads as `%PdfElixide.Color.Gray{}` even though the value is a tint. `:color`
and `:interior_color` are `nil` when no color is decoded.

Link annotations expose where they point via `:destination` and `:action`:

```elixir
%PdfElixide.Document.Annotation{action: {:uri, "https://example.com"}}
```

The `/F` flags decode into a `%PdfElixide.Document.Annotation.Flags{}` sub-struct
(one boolean per bit, plus `:raw` for the undecoded integer):

```elixir
annotation.flags.print         # => true
annotation.flags.hidden        # => false
annotation.flags.raw           # => 4
```

Widget (form field) annotations additionally populate `:field_type`,
`:field_name`, `:field_value`, and related keys; for richer form-field access see
`PdfElixide.Form`. `annotations!/1` and `annotations!/2` return the list directly,
raising on error.

### Form fields

`PdfElixide.Form.fields/1` returns the AcroForm fields of a document, one struct
per field type, each carrying a fully qualified `:name` and a `:value` that is a
plain term — a string, `true`/`false`, a list of strings, or `nil`:

```elixir
{:ok, fields} = PdfElixide.Form.fields(doc)
#=> [%PdfElixide.Form.Field.Text{name: "full_name", value: "John Doe"},
#    %PdfElixide.Form.Field.Button{name: "subscribe", value: true},
#    %PdfElixide.Form.Field.Choice{name: "country", value: nil}]

{:ok, "John Doe"} = PdfElixide.Form.value(doc, "full_name")
```

To fill one, open the file as a `PdfElixide.Editor` instead of a
`PdfElixide.Document`. Every editing call returns the editor, so writing and
saving is one pipeline:

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

`Editor.to_binary/2` returns the bytes instead of writing a file, and the
non-bang functions compose the same way as one `with/1`. An editor is a
**mutable handle, not a value**: the editor a write returns is the one that went
in, so rebinding does not fork it.

See the [Forms](guides/forms.md) guide for the field structs, both pipeline
shapes, writing several fields at once, the save options, and the signature and
check-box caveats.

## Documentation

Full API documentation is published on [HexDocs](https://hexdocs.pm/pdf_elixide).

## License

Released under the [MIT License](https://github.com/r8/pdf_elixide/blob/main/LICENSE).
