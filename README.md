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
- Read the document outline (bookmarks / table of contents) as a nested tree
- Extract raster images (photos, logos, scans) as PNG bytes with their on-page geometry
- Extract the fonts a page uses (type, encoding, weight) and pull out embedded font programs
- Read annotations (links, notes, highlights, form widgets) with their geometry, contents, colors, and flags
- Extract AcroForm fields (name, kind, value)
- Fill AcroForm fields and save the result to a file or in-memory binary
- Read document metadata — both the `/Info` dictionary and the XMP packet
- Read encryption permission flags (print, copy, modify, …)
- Read logical page labels (roman numerals, prefixes, etc.)

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
    {:pdf_elixide, "~> 0.7.0"}
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
