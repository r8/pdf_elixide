# Building documents

`PdfElixide.Builder` describes a new PDF as a pipeline of content. Content
operations return the builder; layout runs when you request the PDF:

```elixir
alias PdfElixide.Builder

Builder.new(title: "Quarterly report")
|> Builder.heading(1, "Quarterly report")
|> Builder.paragraph(["Revenue rose ", {"12%", bold: true}, " on the year."])
|> Builder.bullet_list(["Costs fell", "Margins widened"])
|> Builder.save!("report.pdf")
```

Use it for wrapped text, automatic page breaks and custom fonts. For Markdown,
HTML, plain-text or image input, see [Creating documents](creating-documents.md).

## Getting the PDF

A description is laid out in one of three ways:

- `Builder.to_binary/2` returns the PDF as a binary.
- `Builder.save/3` writes it to a file.
- `PdfElixide.Editor.from_builder/1` opens it as an editor, for work the
  builder does not do, such as merging, attachments, keywords or form fields.

`to_binary/2` and `save/3` take the save options of an editor, including
`:encryption`, and close the editor they use. An editor from
`from_builder/1` is yours to save and close:

```elixir
Builder.new(title: "Report")
|> Builder.paragraph("All good.")
|> PdfElixide.Editor.from_builder!()
|> PdfElixide.Editor.set_keywords!("quarterly")
|> PdfElixide.Editor.save!("report.pdf")
|> PdfElixide.Editor.close()
```

Layout errors are reported by `to_binary/2`, `save/3` or `from_builder/1`
(the `from_builder!()` call in this example); see [Errors](#errors).

## Pages and margins

`Builder.new/1` sets the page size, the four margins, the font, the text size
and the line height for the whole document. Every option has a default:
Letter pages, one-inch margins, 12-point text and a line height of 1.5.
`t:PdfElixide.Builder.new_opts/0` lists them all.

The first content starts the first page. `Builder.page/2` starts another, of
the size it is given or else the size of the page before it, so a document can
mix sizes. Calling it before any content does not add a blank page:

```elixir
Builder.new(page_size: :a4)
|> Builder.paragraph("Portrait")
|> Builder.page({842, 595})
|> Builder.paragraph("Landscape")
```

The margins apply to every page.

## Flowing text

Paragraphs, headings and lists flow from the top margin down. Each line takes
a box `font_size × line_height` points tall, with the text centered in it, and
lines wrap at the right margin. A line that would cross the bottom margin
starts a new page of the same size; nothing is drawn over the margins. A word
wider than the whole line is split between characters, and `\n` starts a new
line within a paragraph. Runs of spaces are laid out as one space.

A paragraph is followed by space half its font size tall. `Builder.space/2`
adds more before the next block. Both are dropped when a page break comes
first, so a page's first line always sits at its top margin. A paragraph,
heading or list with no text adds nothing, neither space nor a page.

Accents and italic overhangs can reach a little past a line's box into the
margins. With narrow margins they could reach past the edge of the page, so
such a line is refused when the document is built.

`Builder.heading/4` takes a level from 1 to 4 and sets the text in the bold
face of its font; `t:PdfElixide.Builder.heading_opts/0` lists the text sizes.
A heading is never left alone at the bottom of a page: if it does not fit there
with the first line of what follows, it starts the next page. Consecutive
headings move together.

`Builder.bullet_list/3` and `Builder.numbered_list/3` take one text per item.
An item that wraps continues under its own text rather than under its marker,
and numbers are right-aligned so the items line up. Numbering carries on
across pages, and `:style` and `:start` choose the numerals.

`Builder.rule/1` draws a thin gray line between the margins.

## Text at a position

`Builder.text_at/4` draws one line on the current page with its baseline at
`{x, y}`, in points from the page's bottom-left corner:

```elixir
Builder.new()
|> Builder.text_at({72, 36}, "Confidential", font_size: 9)
|> Builder.paragraph("The body starts at the top margin as usual.")
```

Positioned text can sit in the margins; flowing text does not make room for
it. It does not wrap, and text containing `\n` raises. At build time, the
whole line must fit on the page, including accents and italic overhangs.

## Drawing shapes

The builder draws rectangles, lines, circles, ellipses, polygons, arcs, Bézier
curves and general paths. Points are `{x, y}` tuples and rectangles are
`PdfElixide.Geometry.Rect` structs, both in points from the page's
bottom-left corner:

```elixir
alias PdfElixide.Color.RGB
alias PdfElixide.Geometry.Rect

gray = %RGB{r: 0.9, g: 0.9, b: 0.9}

Builder.new()
|> Builder.rect(%Rect{x: 72.0, y: 640.0, width: 468.0, height: 80.0}, fill_color: gray, stroke_color: nil)
|> Builder.line({72, 620}, {540, 620}, dash_pattern: {[3, 2], 0})
|> Builder.circle({306, 400}, 50, stroke_width: 2)
|> Builder.arc({306, 250}, 50, 0, 180)
|> Builder.paragraph("The body starts at the top margin as usual.")
```

Shapes are positioned content, like `text_at/4`: they are drawn on the
current page, flowing text neither moves them nor makes room for them, and
each is painted over everything added before it. A shape may run past the
page edge; the part outside is not shown. `PdfElixide.Builder.arc/6` describes
arc angles and direction.

Closed shapes (`rect/3`, `circle/4`, `ellipse/4`, `polygon/3` and `path/3`)
take an outline and a fill; lines, arcs and curves take an outline only. To
fill without an outline, pass `stroke_color: nil` with a `:fill_color`.
`t:PdfElixide.Builder.shape_opts/0` lists paint options and defaults.
Where an outline crosses itself, the inside is filled by the nonzero winding
rule.

Line ends are cut square at the end point and corners are mitred; neither can
be changed.

The operations, and the `:stroke_color`, `:fill_color`, `:stroke_width` and
`:dash_pattern` options, are those of `PdfElixide.Document.Path`, so a path
extracted with `PdfElixide.Document.paths/1` can be drawn again:

```elixir
source
|> PdfElixide.Document.paths!(0)
|> Enum.filter(&(&1.stroke_color || &1.fill_color))
|> Enum.reduce(Builder.new(), fn path, builder ->
  Builder.path(builder, path.operations,
    stroke_color: path.stroke_color,
    fill_color: path.fill_color,
    stroke_width: path.stroke_width
  )
end)
```

Extraction does not report dash patterns, and line ends and corners are always
square and mitred here, so a redrawn outline is solid and square-ended whatever
the source drew.

An extracted path or `bbox` lands where it was on the source page only when
that page has no rotation and its media box starts at `{0.0, 0.0}`. Otherwise
convert it first; see
[Page boxes and the coordinate origin](page-geometry.md#page-boxes-and-the-coordinate-origin)
and [Rotated pages and extracted geometry](page-geometry.md#rotated-pages-and-extracted-geometry).

## Styled text

Wherever the builder takes text, it takes either a string or a list of runs.
A run is a string or a `{string, opts}` tuple:

```elixir
Builder.paragraph(builder, [
  "Status: ",
  {"approved", bold: true, color: %PdfElixide.Color.RGB{r: 0.0, g: 0.5, b: 0.0}},
  " by ",
  {"the board", italic: true}
])
```

`:bold` and `:italic` choose the face of the run's font family, and `:color`
takes RGB components from `0.0` to `1.0`. Runs are joined exactly as written,
so the space between two runs belongs inside one of them.

## Fonts

The document's `:font` applies to everything that does not set its own, and
each paragraph, heading, list and positioned line can set its own `:font` and
`:font_size`. A font is one of:

- `:helvetica`, `:times` or `:courier`, the built-in families. They are not
  embedded, so they add almost nothing to the file, but they draw only
  Windows-1252 characters: Western European letters and common punctuation.
- `:dejavu_sans`, bundled with the library and embedded when used. It covers
  Latin, Greek, Cyrillic and many symbols. It has regular and bold faces only.
- A `PdfElixide.Builder.FontFamily` built from font files you supply.
- `:auto`, the default. It uses Helvetica unless some `:auto` text needs a
  character outside Windows-1252; then all `:auto` text is set in DejaVu Sans,
  and italic text in it is set upright.

Build a custom family once and pass it wherever a `:font` goes:

```elixir
noto =
  Builder.FontFamily.new(
    regular: File.read!("NotoSans-Regular.ttf"),
    bold: File.read!("NotoSans-Bold.ttf"),
    italic: File.read!("NotoSans-Italic.ttf")
  )

Builder.new(font: noto)
|> Builder.heading(1, "Звіт")
|> Builder.paragraph(["Готово ", {"вчасно", italic: true}])
```

Only `:regular` is required; bold italic needs its own `:bold_italic` face.
Use single-face TrueType (`.ttf`) or OpenType (`.otf`) fonts; extract a face
from a collection (`.ttc`) before passing it. Each face is embedded once,
with only the characters used in the document.

## What the builder will not draw

The builder refuses content it cannot draw faithfully:

- **A character the font has no glyph for.** No substitution is made.
  Choose a font that covers it: `:auto` or
  `:dejavu_sans` for text beyond Windows-1252, or a `FontFamily` for scripts
  DejaVu Sans lacks, such as Chinese or Japanese. Spaces, tabs and other
  whitespace are drawn as a space, so the font needs a space glyph.
- **A style the family has no face for**, such as italic text in a family
  without `:italic`. Every heading needs a bold face. Add the face, or drop
  the style from the text.
- **Right-to-left text**, such as Hebrew or Arabic, and **scripts that need
  shaping**, whose letters join, reorder or combine, such as Devanagari,
  Tibetan and Khmer. These are unsupported in every font.
- **A character wider than the line**, which no amount of wrapping can fit.
  Reduce the text size or the side margins.
- **A glyph that would extend past the edge of the page**, such as an
  italic `j` with no left margin or an accented capital with no top margin.
  Widen the margins, or for flowing text increase the line height; move
  positioned text further onto the page.

A combining accent is drawn where the font places it, which in most fonts is
over the letter before it.

## Errors

Malformed arguments raise at the call that receives them. Unknown options,
invalid option values, margins that leave no room and line boxes taller than
the content area raise `ArgumentError`.

Unsupported content is reported when the description is built, as
`{:error, %PdfElixide.Error{reason: :unsupported}}` from `to_binary/2`,
`save/3` or `PdfElixide.Editor.from_builder/1`. The message names the
operation and page (both numbered from 0), what was refused and what to change:

```elixir
{:error, %PdfElixide.Error{reason: :unsupported, message: message}} =
  Builder.new()
  |> Builder.paragraph("Привіт", font: :helvetica)
  |> Builder.to_binary()
```

Bang variants raise instead. No partial document is produced.
