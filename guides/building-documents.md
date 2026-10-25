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
link; see [Links](#links).

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
- Before flattening, read the [text limitations](forms.md#flattening).
  Flattening draws no selection for a list box with several options selected,
  and draws a push button without its caption. Leave such a form unflattened.

A signature field is an empty placeholder for another tool to sign; this
library does not sign documents. See [Signatures](signatures.md).

Text fields are single-line, combo boxes are not editable, and push buttons
have no actions. Radio groups, tab order and scripts are unsupported.

## Annotations after building

Links and watermarks are annotations, and an editor treats them as such:

- `PdfElixide.Editor.flatten_annotations/1` draws a watermark into the page's
  content and removes the page's annotations, **links included**, since a link
  has nothing to draw:

  ```elixir
  builder
  |> Editor.from_builder!()
  |> Editor.flatten_annotations!()
  |> Editor.save!("flattened.pdf")
  ```

- `PdfElixide.Editor.merge/2` refuses a page with annotations; see
  [When a merge is refused](merging-and-splitting.md#when-a-merge-is-refused).

The builder writes no comment annotations: highlights, underlines, sticky
notes, stamps and free text.

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
- **A character wider than the line, box or table cell**, which no amount of
  wrapping can fit. Reduce the text size or the side margins, or widen the box
  or the column.
- **Text taller than its box**; see [Text in a box](#text-in-a-box).
- **Table rows that cannot be split and do not fit on a page**, and **columns
  that do not fit the page**; see [Across pages](#across-pages) and
  [Column widths](#column-widths).
- **An image whose proportions take it past the content area**, such as a
  tall image given only a `:width`. Give a smaller `:width` or a `:height`.
- **A glyph that would extend past the edge of the page**, such as an
  italic `j` with no left margin or an accented capital with no top margin.
  Widen the margins, or for flowing text increase the line height; move
  positioned text further onto the page.
- **An invalid link target**, such as a missing page or anchor; see
  `t:PdfElixide.Builder.link/0`.

A combining accent is drawn where the font places it, which in most fonts is
over the letter before it.

## Errors

Malformed arguments raise at the call that receives them. Unknown options,
invalid option values, margins that leave no room, and line boxes or image
sizes larger than the content area raise `ArgumentError`.

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
