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
  builder does not do, such as merging, attachments, keywords or filling form
  fields.

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
headings move together. A heading that cannot fit on one page with the start
of what follows, and any footnotes they reference, is refused when the document
is built.

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
it. It does not wrap, and text containing `\n` raises; for text that wraps,
see [Text in a box](#text-in-a-box). At build time, the whole line must fit on
the page, including accents and italic overhangs.

## Text in a box

`Builder.text_in_rect/4` wraps text within a `PdfElixide.Geometry.Rect` on the
current page, outside the flow like `text_at/4`:

```elixir
alias PdfElixide.Geometry.Rect

box = %Rect{x: 340, y: 600, width: 200, height: 60}

Builder.new()
|> Builder.rect(box, stroke_width: 0.5)
|> Builder.text_in_rect(box, ["Total for the year\n", {"12%", bold: true}], align: :right)
```

The first line starts at the box's top edge, and each line takes a box
`font_size × line_height` points tall, as in a paragraph. Lines wrap at the
box's width, `\n` starts a new line, and `:align` places each line at the
box's left edge, its center or its right edge. The box is not drawn; draw it
with `Builder.rect/3` if it should show.

Text needing more lines than the box holds is refused when the document is
built, with a message giving the height it needs. Nothing is cut off. Enlarge
the box, reduce the text size or the document's `:line_height`, or shorten the
text. Accents and italic overhangs may reach past the box, as flowing text may
reach into the margins, but not past the edge of the page. The box itself may
extend off the page as long as its text does not.

## Code blocks

`Builder.code_block/3` adds source text to the flow, set as written on a
shaded background:

```elixir
source = """
defmodule Hello do
\tdef world, do: :ok
end
"""

Builder.new()
|> Builder.paragraph("The module:")
|> Builder.code_block(source, font_size: 9)
```

Unlike a paragraph, a code block keeps its spacing. Spaces are not collapsed,
blank lines keep their height, and each tab moves to the next stop, every
`:tab_width` characters from the start of its line. `\r\n` and `\r` end a
line as `\n` does, and whitespace at the end of a line is dropped. A line
wider than the block breaks at the character that would cross its edge, not
between words, and continues at the block's left edge.

The background fills the width between the margins. Line height and spacing
follow paragraphs; see [Flowing text](#flowing-text). A block holding only spaces and tabs adds
nothing. When a block continues onto another page, each page's part gets a
background of its own, padded on every side. See
`t:PdfElixide.Builder.code_block_opts/0` for padding, background controls and
option defaults.

The default font is `:courier`, whatever the document's `:font`. Courier draws
only Windows-1252 characters, so for code with other characters, pass a
monospaced `PdfElixide.Builder.FontFamily` that covers them as `:font`. Text
is a `t:PdfElixide.Builder.text/0`, so styled runs can highlight syntax:

```elixir
keyword = %PdfElixide.Color.RGB{r: 0.6, g: 0.1, b: 0.5}

Builder.code_block(builder, [{"def", color: keyword, bold: true}, " world, do: :ok"])
```

## Columns

`Builder.columns/3` sets paragraphs side by side in columns of equal width,
in the flow:

```elixir
Builder.new()
|> Builder.heading(1, "Newsletter")
|> Builder.columns(
  ["The first paragraph …", ["The second, with ", {"bold", bold: true}, " text."]],
  count: 3,
  rule: true
)
|> Builder.paragraph("Back to the full width.")
```

Each paragraph is a `t:PdfElixide.Builder.text/0` and follows the
[Flowing text](#flowing-text) rules, wrapped to the column's width.
The columns divide the width between the margins, less a `:gap` between each
pair.

The columns start below the preceding content and fill left to right to the
bottom margin, continuing at the top of new pages as needed. On the last page,
they are balanced to nearly equal heights, as whole lines allow. With
`balance: false`, columns on that page fill to the bottom margin in turn,
so those to the right may be short or empty. Following content starts below
the tallest column. Paragraph spacing is dropped at column tops.

`rule: true` draws a thin gray line down the middle of each gap with text on
both sides, as tall as the tallest column on that page. A heading before the
columns is kept with their first line. See
`t:PdfElixide.Builder.columns_opts/0` for the options.

`PdfElixide.Document.text/1` may interleave lines from neighboring columns.
To read columns in order, group `PdfElixide.Document.words/1` or
`PdfElixide.Document.chars/1` by their horizontal position.

## Tables

`Builder.table/3` takes a list of rows, each a list of cells, and flows like a
paragraph from the cursor down:

```elixir
alias PdfElixide.Color.RGB

Builder.new()
|> Builder.table(
  [
    ["Item", "Qty", "Notes"],
    ["Coffee", "2", "Single origin, roasted on the week of delivery"],
    [Builder.cell("Total", colspan: 2, align: :right), [{"2 items", bold: true}]]
  ],
  header_rows: 1,
  header_fill: %RGB{r: 0.9, g: 0.9, b: 0.9},
  column_widths: [:auto, 40, {:weight, 1}],
  align: [:left, :right, :left]
)
```

A cell is a text, like a paragraph's, or `Builder.cell/2` for a cell with its
own span, alignment or background. Each cell's text wraps within its column,
inside `:padding` points on every side, with lines as tall as a paragraph's.
A row is as tall as its tallest cell, and a row with no text is one line tall.
The grid is drawn around every cell unless `stroke_color: nil`.

### Column widths

`:column_widths` gives each column one of:

- a number of points;
- `:auto`, the width of the column's widest line, padding included. Cells
  spanning several columns do not count toward it;
- `{:weight, n}`, a share of the content width the other columns leave, in
  proportion to `n`.

Without `:column_widths`, the columns share the content width equally. A
table with no weighted column is as wide as its columns, from the left
margin. When `:auto` columns would make the table wider than the content
width, they shrink toward the width of their widest character so that it fits.
If they still do not fit, or the weighted columns are left no room for text,
the table is refused when the document is built.

### Spans

`colspan: n` makes a cell cover `n` columns, and `rowspan: n` makes it cover
`n` rows. A cell is placed in the first column of its row that no cell above
still covers, so the rows below a rowspan list one cell fewer:

```elixir
Builder.table(builder, [
  [Builder.cell("Fruit", rowspan: 2), "Apples"],
  ["Pears"]
])
```

With their spans, every row must cover the same columns; a ragged row, a span
past the last row or column, or one that overlaps another raises
`ArgumentError`. When a spanning cell is taller than the rows it covers, the
last of those rows grows to hold it.

### Across pages

A table continues onto as many pages as it needs. The `:header_rows` first
rows are set bold, so the font needs a bold face, and are repeated at the top
of every page the table reaches. A row too tall for the rest of a page is
split between lines and continues below the header on the next page; each
part is drawn as a complete row. A row is moved whole when not even one of its
lines fits. Rows joined by a rowspan stay together and move to the next page
as one.

The header rows with the first line of any row, or with rows joined by a
rowspan, must fit within the page's content area; a table needing more is
refused when the document is built.

A heading before a table stays on the page of the table's header and its
first line. As with a paragraph, the table is followed by space half its font
size tall, which is dropped when a page break comes first.

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

Line ends are cut square at the end point and corners are mitered; neither can
be changed.

The operations, and the `:stroke_color`, `:fill_color`, `:stroke_width` and
`:dash_pattern` options, are those of `PdfElixide.Document.Path`, so a path
extracted with `PdfElixide.Document.paths/1` can be drawn again:

```elixir
source
|> PdfElixide.Document.paths!(0)
|> Enum.filter(&(&1.stroke_color || &1.fill_color))
|> Enum.reduce(Builder.new(), fn path, builder ->
  outline =
    if path.stroke_color,
      do: [stroke_color: path.stroke_color, stroke_width: path.stroke_width],
      else: [stroke_color: nil]

  Builder.path(builder, path.operations, [fill_color: path.fill_color] ++ outline)
end)
```

A `:stroke_width` without an outline is refused, so a fill-only path is
given `stroke_color: nil` alone.

Extraction does not report dash patterns, and line ends and corners are always
square and mitered here, so a redrawn outline is solid and square-ended whatever
the source drew.

An extracted path or `bbox` lands where it was on the source page only when
that page has no rotation and its media box starts at `{0.0, 0.0}`. Otherwise
convert it first; see
[Page boxes and the coordinate origin](page-geometry.md#page-boxes-and-the-coordinate-origin)
and [Rotated pages and extracted geometry](page-geometry.md#rotated-pages-and-extracted-geometry).

## Images

The builder draws JPEG and PNG images, given as the file's bytes. `image/3`
adds one to the flow, between the margins and below the content before it;
`image_in_rect/4` places one within a `PdfElixide.Geometry.Rect` on the current
page, outside the flow like `text_in_rect/4`:

```elixir
alias PdfElixide.Geometry.Rect

logo = File.read!("logo.png")
chart = File.read!("chart.png")

Builder.new()
|> Builder.image_in_rect(%Rect{x: 72.0, y: 700.0, width: 120.0, height: 40.0}, logo)
|> Builder.heading(1, "Results")
|> Builder.image(chart, width: 400, align: :center)
|> Builder.save!("results.pdf")
```

See `t:PdfElixide.Builder.image_opts/0` for flow sizing and alignment, and
`t:PdfElixide.Builder.image_in_rect_opts/0` for fitting an image within a rect.

An image that does not fit below the content before it moves to the top of the
next page. As with a paragraph, it is followed by space half the document's
font size tall, which is dropped when a page break comes first, and a heading
before it stays on its page.

An image used more than once, such as a logo on every page, is stored once.
Images are embedded as `PdfElixide.Editor.from_images/2` embeds them, with the
same formats, size limits and caveats about photo orientation and CMYK colors;
see [Images](creating-documents.md#images).

## Barcodes

The builder draws linear barcodes and QR codes as vector shapes, so they stay
sharp at any size and print resolution. `barcode/4` and `qr_code/3` add one to
the flow, between the margins and below the content before it;
`barcode_in_rect/5` and `qr_code_in_rect/4` place one within a
`PdfElixide.Geometry.Rect` on the current page, outside the flow:

```elixir
alias PdfElixide.Geometry.Rect

ticket = %Rect{x: 72.0, y: 640.0, width: 220.0, height: 60.0}
link = %Rect{x: 468.0, y: 640.0, width: 72.0, height: 72.0}

Builder.new()
|> Builder.barcode_in_rect(ticket, :code128, "TKT-2026-0412", text: true)
|> Builder.qr_code_in_rect(link, "https://example.com/t/0412")
|> Builder.link_in_rect(link, "https://example.com/t/0412")
|> Builder.heading(1, "Your ticket")
|> Builder.barcode(:ean13, "590123412345", text: true, align: :center)
|> Builder.save!("ticket.pdf")
```

`t:PdfElixide.Builder.symbology/0` lists the linear symbologies and the data
each one takes. Data a symbology cannot encode raises `ArgumentError` at the
call. QR codes store `data` as UTF-8; data too long for the chosen error
correction level also raises at the call.

Positioned symbols use points from the page's bottom-left corner; reversed
rect corners are normalized. They start the first page if none exists yet.
A linear barcode fills its rect; a QR code is the largest centered square
that fits. Both include their quiet zones, so the same rect can be passed to
`link_in_rect/3`.

See `t:PdfElixide.Builder.barcode_opts/0` and `t:PdfElixide.Builder.qr_code_opts/0`
for flow sizing, and `t:PdfElixide.Builder.barcode_in_rect_opts/0` and
`t:PdfElixide.Builder.qr_code_in_rect_opts/0` for captions, colors and quiet zones.
A caption wider than the symbol is refused when the document is built.

Scanners need clear quiet zones, sufficient module size and good contrast.
Keep black symbols on a light page, or set `:background` when drawing over a
color. Reducing a symbol's size also shrinks its modules and quiet zones.

Flowing symbols paginate and use the same spacing as images; see
[Images](#images).

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
so the space between two runs belongs inside one of them. A run can also be a
link; see [Links](#links), or carry a footnote; see [Footnotes](#footnotes).

## Footnotes

Give a run a `:footnote` to set a note at the foot of the page:

```elixir
Builder.new(footnotes: [font_size: 9])
|> Builder.paragraph([
  "Revenue ",
  {"rose", footnote: ["Audited figures; see the ", {"annual report", italic: true}, "."]},
  " on the year."
])
```

The note is a `t:PdfElixide.Builder.text/0`, styled like any other text,
but it cannot carry a footnote of its own. Notes are numbered from 1 through
the whole document, in the order their runs are added. The number is drawn
smaller and raised right after the run's text, in the regular face of the
run's font, so the run must end in a character other than whitespace.

A note is set on the page its number lands on, below a short rule, with the
page's notes stacked in number order so the last line sits on the bottom
margin. Notes span the width between the margins and wrap within it, and
take the document's line height. `new/1`'s `:footnotes` sets their font and
size; see `t:PdfElixide.Builder.footnotes_opts/0` for the defaults.

The page's text stops above its notes. A note is never split across pages:
when a line and the notes it references do not fit on the rest of a page, the
line moves to the next page with its notes. A line whose notes do not fit even
on a page of their own is refused when the document is built. For headings,
see [Flowing text](#flowing-text).

Footnotes can be set in paragraphs, headings, list items, `columns/3` and
the body rows of a table; anywhere else, including table header rows, they
raise `ArgumentError`. In columns, the page's notes span every column below
the columns. In a table, a row split across pages takes each note to the page
of the line that references it.

Text extraction reads a number back as digits after its word, or on a line of
its own, and reads a page's notes after the rest of its text.

## Links

Give a run a `:link` to make its text clickable:

```elixir
Builder.new()
|> Builder.paragraph(["Read ", {"the documentation", link: "https://hexdocs.pm/pdf_elixide"}, "."])
|> Builder.paragraph([{"Skip to the appendix", link: {:anchor, "appendix"}}])
|> Builder.page()
|> Builder.anchor("appendix")
|> Builder.heading(1, "Appendix")
|> Builder.save!("report.pdf")
```

A link points to one of:

- **A URI**, given as a string; see `t:PdfElixide.Builder.link/0` for
  restrictions.
- **`{:page, index}`**, a page of this document numbered from 0. Following it
  shows the whole page.
- **`{:anchor, name}`**, a place in this document named by
  `PdfElixide.Builder.anchor/2`. Links may precede their anchors; see that
  function for how the destination is positioned.
- **`{:script, code}`**, JavaScript a viewer runs when the link is clicked;
  see [Scripts](#scripts).

The clickable area follows each line of text. A run that wraps is one link
per page. Separate runs stay separate links, even with the same target. A
linked run must contain text other than whitespace.

To make an image or a drawn shape clickable, give its rect to
`link_in_rect/3`:

```elixir
alias PdfElixide.Geometry.Rect

logo_box = %Rect{x: 72.0, y: 700.0, width: 120.0, height: 40.0}

builder
|> Builder.image_in_rect(logo_box, File.read!("logo.png"))
|> Builder.link_in_rect(logo_box, "https://example.com")
```

## Navigation

Bookmarks make up the outline a viewer shows beside the pages. Give a heading
`bookmark: true` to bookmark it under its own text, or add one with
`bookmark/3`:

```elixir
Builder.new(title: "Annual report")
|> Builder.heading(1, "Contents")
|> Builder.contents()
|> Builder.page()
|> Builder.heading(1, "Results", bookmark: true)
|> Builder.paragraph("Revenue rose on the year.")
|> Builder.heading(2, "By region", bookmark: true)
|> Builder.paragraph("Every region grew.")
|> Builder.bookmark("Regional table", level: 3)
|> Builder.table([["North", "12%"], ["South", "9%"]])
|> Builder.save!("report.pdf")
```

A bookmark points to the content after it, as an anchor does, or wherever
its `:to` says. A heading's bookmark takes the heading's level. See
`t:PdfElixide.Builder.bookmark_opts/0` for nesting and styling.

`contents/2` lists every bookmark with the label of its page, and links each
entry to it.

## Page labels

A viewer shows a label for each page, normally its number. `page_labels/3`
starts a range of labels in a numbering style, with an optional prefix and
starting number:

```elixir
Builder.new()
|> Builder.heading(1, "Annual report")
|> Builder.page()
|> Builder.page_labels(:roman_lower)
|> Builder.paragraph("Preface")
|> Builder.page()
|> Builder.page_labels(:decimal)
|> Builder.paragraph("Chapter one")
|> Builder.save!("report.pdf")
```

Here the title page is 1, the preface i, and the chapter starts again at 1.
A range starts on the page where the next content lands, whether it flows or
is placed, or on the last page if no content follows. It lasts until the
next range. Pages before the first range are numbered
from 1. `t:PdfElixide.Builder.label_style/0` lists the styles.

## Headers and footers

`header/2` and `footer/2` draw a line of text in the top or bottom margin of
every page:

```elixir
alias PdfElixide.Color.RGB

Builder.new()
|> Builder.header(left: "Annual report", right: "Draft", color: %RGB{r: 0.4, g: 0.4, b: 0.4})
|> Builder.footer(center: "Page {page} of {pages}", font_size: 9)
|> Builder.paragraph("Revenue rose on the year.")
|> Builder.save!("report.pdf")
```

A header has up to three parts: `:left` starts at the left margin, `:center`
is centered on the page and `:right` ends at the right margin. Each is a line
of text, with runs styled as in [Styled text](#styled-text).

In any part, `{page}` is replaced with the page's label, as set by
[Page labels](#page-labels), and `{pages}` with the number of pages. There
is no way to write the text `{page}` itself.

A header starts and ends as a label range does (see
[Page labels](#page-labels)); pass `nil` to stop it. To leave a title page
bare, add the header after the page break that ends it:

```elixir
Builder.new()
|> Builder.heading(1, "Annual report")
|> Builder.page()
|> Builder.footer(center: "{page}")
|> Builder.paragraph("Revenue rose on the year.")
```

Headers and footers are marked as page furniture, which screen readers skip.
Their text is still extracted with the rest of the page.

## Watermarks

`watermark/3` draws a line of translucent text across a page:

```elixir
alias PdfElixide.Color.RGB

Builder.new()
|> Builder.watermark("CONFIDENTIAL", pages: :all, color: %RGB{r: 0.8, g: 0.0, b: 0.0})
|> Builder.paragraph("Quarterly figures")
|> Builder.save!("figures.pdf")
```

With `pages: :current`, the default, the watermark marks the page it lands
on, like `text_at/4`. With `pages: :all` it marks every page of the document,
including pages the flow starts after the call, so where the call sits in the
pipeline does not matter. See `t:PdfElixide.Builder.watermark_opts/0` for
positioning, styling and defaults.

The text is one line of printable ASCII characters in one of the built-in
families. An apostrophe and a grave accent are drawn as curly quotes.

A watermark is an annotation drawn over the page's content, not part of it.
Viewers show and print it, but any PDF editor can delete it, so it labels a
document rather than protecting it. Do not rely on text extraction or search to
find its text. To draw it into the page's content instead, flatten it; see
[Annotations after building](#annotations-after-building).

## Form fields

The builder adds fillable form fields to the current page, each at a
`PdfElixide.Geometry.Rect` in points from the page's bottom-left corner:

```elixir
alias PdfElixide.Geometry.Rect

Builder.new()
|> Builder.text_at({72, 704}, "Name")
|> Builder.text_field("name", %Rect{x: 150, y: 700, width: 200, height: 20},
  required: true,
  tooltip: "Your full name"
)
|> Builder.text_at({72, 664}, "Country")
|> Builder.combo_box("country", %Rect{x: 150, y: 660, width: 200, height: 20},
  ["France", "Germany", "Italy"]
)
|> Builder.check_box("subscribe", %Rect{x: 150, y: 620, width: 14, height: 14})
|> Builder.signature_field("signature", %Rect{x: 150, y: 500, width: 200, height: 50})
|> Builder.save!("application.pdf")
```

The kinds are `text_field/4`, `check_box/4`, `combo_box/5`, `list_box/5`,
`push_button/5` and `signature_field/4`. See
`t:PdfElixide.Builder.text_field_opts/0` for common modifiers and each
function's option type for its settings.

Each field needs a unique name without a `.` and must lie on its page.
Fields sit outside the text flow; place labels with `text_at/4` and keep
flowing content clear of them.

A field draws its text in Helvetica, so a value, an option or a caption
holds only printable Windows-1252 characters, and anything else raises
`ArgumentError`. A name and a tooltip may hold other text, apart from the few
characters described in [Text a field cannot hold](forms.md#text-a-field-cannot-hold).

The fields read back through `PdfElixide.Form.fields/1`, and a signature
field through `PdfElixide.Signature.unsigned_fields/1`. To fill them, open the
description with `PdfElixide.Editor.from_builder/1` and use
`PdfElixide.Form.put_value/3`; see [Filling a form](forms.md#filling-a-form).

### How a built field is drawn

A built field has no appearance of its own: a viewer draws it from the
field's value each time it shows the page. As a result:

- `PdfElixide.Document.render/3` draws the fields as blank space. Flatten
  the form first, with `PdfElixide.Form.flatten/1`, to render it.
- A check box reports no `:on_states`; its on state is `"Yes"`, the one
  `PdfElixide.Form.put_value/3` writes for `true`.
- Before flattening, read the text limitations in
  [Flattening](forms.md#flattening).
  Flattening draws no selection for a list box with several options selected,
  and draws a push button without its caption. Leave such a form unflattened.

A signature field is an empty placeholder for another tool to sign; this
library does not sign documents. See [Signatures](signatures.md).

Text fields are single-line, combo boxes are not editable, and push buttons
have no actions. Radio groups and tab order are unsupported. For the scripts
a text field, combo box or list box can run, see [Scripts](#scripts).

## Annotations after building

Links and watermarks are annotations, and an editor treats them as such:

- `PdfElixide.Editor.flatten_annotations/1` draws a watermark into the page's
  content. On a page with a watermark it also removes the page's other
  annotations, **links and form fields included**, since neither has anything
  to draw. A page with no watermark keeps its links and fields:

  ```elixir
  builder
  |> PdfElixide.Editor.from_builder!()
  |> PdfElixide.Editor.flatten_annotations!()
  |> PdfElixide.Editor.save!("flattened.pdf")
  |> PdfElixide.Editor.close()
  ```

- `PdfElixide.Editor.merge/2` refuses a page with annotations; see
  [When a merge is refused](merging-and-splitting.md#when-a-merge-is-refused).

The builder writes no comment annotations: highlights, underlines, sticky
notes, stamps and free text.

## Scripts

The builder writes JavaScript for a viewer to run through explicit script
options and link targets:

```elixir
alias PdfElixide.Geometry.Rect

Builder.new(scripts: [open: "app.alert('Fill in the amount, then print.');"])
|> Builder.paragraph(["When you are done, ", {"print the form", link: {:script, "this.print();"}}, "."])
|> Builder.page_scripts(open: "this.getField('amount').setFocus();")
|> Builder.text_field("amount", %Rect{x: 150, y: 600, width: 100, height: 20},
  scripts: [validate: "if (event.value < 0) { app.alert('Enter a positive amount.'); event.rc = false; }"]
)
|> Builder.save!("order.pdf")
```

| Given as | Runs |
|---|---|
| `scripts: [open: code]` to `PdfElixide.Builder.new/1` | when the document is opened |
| `PdfElixide.Builder.page_scripts/2`, with `:open` and `:close` | when the viewer shows the page, and when it leaves it |
| `{:script, code}` as a `:link`, or to `link_in_rect/3` | when the link is clicked |
| `:keystroke` in a field's `:scripts` | as the user types into the field |
| `:format` in a field's `:scripts` | when the field's value is displayed |
| `:validate` in a field's `:scripts` | when the user commits a new value |

Each field kind's options list the scripts it takes, starting with
`t:PdfElixide.Builder.text_field_opts/0`, and
`PdfElixide.Builder.page_scripts/2` says which page receives its scripts.
Calculated fields and document-close scripts are unsupported.

A link given as a `javascript:` or `vbscript:` URI raises `ArgumentError`
rather than becoming a script, so a URL taken from user input never turns
into code.

### What a script holds

The code is written as given. This library does not run, parse or check it,
so a mistake in a script shows only when a viewer runs it. A script cannot be
empty or only whitespace, and it may hold any text except the characters
described in [Text a field cannot hold](forms.md#text-a-field-cannot-hold).

### How viewers treat scripts

Viewers differ: some run no scripts at all, some ask the user before running
any, and some support only part of the JavaScript a desktop viewer offers.
Keep the document usable when its scripts do not run.

### Scripts after building

Scripts stay in the document unless something removes them:

- `PdfElixide.Editor.sanitize/2` removes the open script given to `new/1`,
  but not page, link or field scripts.
- Leave scripts out of documents intended for PDF/A; see
  [What a report establishes](`m:PdfElixide.Compliance#module-what-a-report-establishes`)
  for validation and conversion limits.
- `PdfElixide.Editor.merge/2` refuses a page with page, link or field
  scripts; see
  [When a merge is refused](merging-and-splitting.md#when-a-merge-is-refused).
- `PdfElixide.Editor.flatten_annotations/1` removes script links along with
  every other link on a page with a watermark; see
  [Annotations after building](#annotations-after-building).

## Fonts

The document's `:font` applies to everything that does not set its own, and
each paragraph, heading, list and positioned line can set its own `:font` and
`:font_size`. A font is one of:

- `:helvetica`, `:times` or `:courier`, the built-in families. They are not
  embedded, so they add almost nothing to the file, but they draw only
  Windows-1252 characters: Western European letters and common punctuation.
  Rendered pages draw them with the host's installed fonts; see
  [Fonts](rendering.md#fonts) in the rendering guide.
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
  without `:italic`. Every heading and table header row needs a bold face.
  Add the face, or drop the style from the text.
- **Right-to-left text**, such as Hebrew or Arabic, and **scripts that need
  shaping**, whose letters join, reorder or combine, such as Devanagari,
  Tibetan and Khmer. These are unsupported in every font.
- **A character wider than the line, box, table cell or column**, which no
  amount of wrapping can fit. Reduce the text size or the side margins, widen
  the box or the table column, or use fewer or wider columns.
- **Text taller than its box**; see [Text in a box](#text-in-a-box).
- **Table rows that cannot be split and do not fit on a page**, and **table
  columns that do not fit the page**; see [Across pages](#across-pages) and
  [Column widths](#column-widths).
- **An image whose proportions take it past the content area**, such as a
  tall image given only a `:width`. Give a smaller `:width` or a `:height`.
- **A glyph that would extend past the edge of the page**, such as an
  italic `j` with no left margin or an accented capital with no top margin.
  Widen the margins, or for flowing text increase the line height; move
  positioned text further onto the page.
- **An invalid link or bookmark target**, such as a missing page or anchor;
  see `t:PdfElixide.Builder.link/0`.
- **Header and footer parts that do not fit between the margins or that
  overlap**, once `{page}` and `{pages}` are filled in. Shorten them or reduce
  the text size.
- **A page label range, header or footer replaced on the page it would start
  on**, which would apply to no page, and **a second `page_scripts/2` on the
  same page**. Remove one, or put content between them.
- **A Roman page label past 3999, or a lettered one past 26000.** Start
  another range before that page.
- **Contents in a document with no bookmarks.**
- **A line whose footnotes do not fit on a page with it**, even a page of
  their own; see [Footnotes](#footnotes).
- **A heading that cannot fit on one page with the start of what follows**,
  such as a heading before a full-page image, since it would be left alone;
  see [Flowing text](#flowing-text).
- **A barcode caption wider than its symbol**; see [Barcodes](#barcodes).

The barcode operations draw the symbologies `t:PdfElixide.Builder.symbology/0`
lists and QR codes. They do not draw GS1-128 function characters, Code 128
control characters, or two-dimensional symbologies other than QR, such as Data
Matrix and PDF417.

A combining accent is drawn where the font places it, which in most fonts is
over the letter before it.

## Errors

Malformed arguments raise at the call that receives them. Unknown options,
invalid option values, margins that leave no room, line boxes or image and
barcode sizes larger than the content area, and barcode data the symbology
cannot encode raise `ArgumentError`.

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

An image that cannot be read is refused when the document is built, naming the
operation, with the reasons `PdfElixide.Editor.from_images/2` lists.

Bang variants raise instead. No partial document is produced.
