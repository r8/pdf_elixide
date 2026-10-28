# Page geometry

Every box this library reports or accepts is a `PdfElixide.Geometry.Rect` in
PDF points. This guide covers which page box those coordinates are measured
on, what the crop box hides from text extraction, and which frame each
extractor reports in on a rotated page.

## Page boxes and the coordinate origin

Raw PDF user space has a bottom-left origin, y increasing upward, and units
measured in points. Extracted boxes may instead use the displayed frame on a
rotated page; see [Rotated pages and extracted geometry](#rotated-pages-and-extracted-geometry).

The sheet those coordinates fall on is the page's `/MediaBox`, read with
`PdfElixide.Document.Page.media_box/1` as a `PdfElixide.Geometry.Rect`. Its
origin is usually `{0.0, 0.0}`, but nothing requires that, and **content
coordinates are not rebased on it**: a glyph at the very left edge of a page
whose box starts at `{10.0, 20.0}` reports an `x` near `10.0`. Subtract the
origin yourself when you want offsets from the page corner:

```elixir
box = PdfElixide.Document.Page.media_box!(page)
{word.bbox.x - box.x, word.bbox.y - box.y}
```

`PdfElixide.Document.Page.width/1` and `PdfElixide.Document.Page.height/1` are
that rect's `:width` and `:height`. All three are normalized to non-negative
dimensions, none is turned to match a rotated page (see below), and a page with
no `/MediaBox` anywhere above it is an `%PdfElixide.Error{reason: :invalid_pdf}`
rather than an assumed page size. `PdfElixide.Document.Page.crop_box/1` reads
the `/CropBox` — the part of that sheet a viewer shows — on the same terms,
answering `nil` when there is none and reporting it as declared, which may be
larger than the sheet. `PdfElixide.Document.Page.visible_box/1` is the two
intersected, and always answers a box. There is no reader for `/BleedBox`,
`/TrimBox` or `/ArtBox`.

### What the crop box hides from extraction

Text extraction reads a page as a viewer shows it, so text lying **entirely**
outside the crop box — a print master's slug line, a proof's marginal numbering
— is not returned. `PdfElixide.Document.text/2`, `PdfElixide.Document.spans/2`,
`PdfElixide.Document.words/2`, `PdfElixide.Document.text_lines/2`,
`PdfElixide.Document.structured/2`, `PdfElixide.Document.search/2`,
`PdfElixide.Document.to_markdown/2`, `PdfElixide.Document.to_html/2` and
`PdfElixide.Document.to_plain_text/2` all omit it, at every arity. A run that
straddles the crop edge is returned whole rather than cut.

`PdfElixide.Document.chars/2` is the exception: it reports every glyph on the
sheet, cropped away or not. A page can therefore yield characters that its own
words and lines do not contain, so do not assemble text from
`PdfElixide.Document.chars/2` and expect it to match
`PdfElixide.Document.text/2`.

The frame all of this is measured against is the crop box reduced to the media
box, which `PdfElixide.Document.Page.visible_box/1` returns; a page with no
usable crop box is read to its whole media box.

To reach cropped-away text, widen the crop box to the media box with
`PdfElixide.Editor.set_crop_box/3` and extract from the saved result.

### Which ancestor an inherited box comes from

`/MediaBox`, `/CropBox` and `/Rotate` are inheritable: a page declaring none of
them takes them from an ancestor `/Pages` node. Where **two** nested ancestors
declare the same entry, the **nearest** one wins, per ISO 32000-1 §7.7.3.4.
`PdfElixide.Editor` resolves them the same way, so
`PdfElixide.Editor.media_box/2`, `PdfElixide.Editor.crop_box/2` and
`PdfElixide.Editor.rotation/2` agree with the page readers on such a document.

## Rotated pages and extracted geometry

A page may carry a `/Rotate` telling a viewer to display it turned — read it
with `PdfElixide.Document.Page.rotation/1`. It does **not** mean every
coordinate handed back is turned with it, and on a rotated page **the extractors
do not all report in the same frame**:

  * `PdfElixide.Document.chars/1`, `PdfElixide.Document.spans/1`,
    `PdfElixide.Document.structured/1`, `PdfElixide.Document.paths/1` — with
    `PdfElixide.Document.rects/1` and `PdfElixide.Document.lines/1`, which are
    the same values narrowed — and `PdfElixide.Document.images/1` stay in raw,
    unrotated user space, whatever the rotation.
  * `PdfElixide.Document.words/1`, `PdfElixide.Document.text_lines/1`, every box
    `PdfElixide.Document.tables/1` reports — each table's own and its cells' —
    the boxes on a `PdfElixide.Document.search/2` match and the spans
    `PdfElixide.Document.running_regions/2` returns are mapped into the
    **displayed** frame. The mapping is selective: a `180`-degree page maps
    everything, while a `90`- or `270`-degree page maps only text whose own text
    matrix is rotated, leaving a horizontal run raw.

Passing the deprecated `:profile` option to
[`PdfElixide.Document.words/2,3`](`PdfElixide.Document.words/2`) or
[`PdfElixide.Document.text_lines/2,3`](`PdfElixide.Document.text_lines/2`)
opts out of the mapping and returns raw user space on every page. See the
"Legacy extraction controls" section of `t:PdfElixide.Document.words_opts/0`.

For a span's physical extent, use its `:page_bbox`; it is in the same frame as
that span's `:bbox`. See the "`:bbox` and `:page_bbox`" section of
`PdfElixide.Document.Span`.

So on a `180`-degree page, `PdfElixide.Document.spans/1` and
`PdfElixide.Document.words/1` describing the very same line report mirrored
boxes. Compare or lay out boxes from **one** extractor, and use
`PdfElixide.Document.chars/1` or `PdfElixide.Document.spans/1` when raw page
space is what you want. Page boxes are likewise never swapped, so computing the
displayed page size is the caller's job. A caller that only wants text is
unaffected — the distinction matters when bounding boxes do.

### Telling which frame a box is in

On a `180`-degree page every box in the second group is mapped. On a `90`- or
`270`-degree page the key is the run's own text-matrix rotation: a
`PdfElixide.Document.Word` or `PdfElixide.Document.Span` whose `:rotation` is
other than `0.0` was mapped, and one whose `:rotation` is `0.0` is raw. A
`PdfElixide.Document.TextLine` carries its `:words` and a
`PdfElixide.Document.SearchMatch` its `:spans`, so both can be read the same
way. A `PdfElixide.Document.Table.Cell`'s `:spans` are **not** a key: they
report `0.0` whatever the run was drawn with. Each is cut from one word, so the
entry of `PdfElixide.Document.words/2` with the same `:bbox` carries the real
value.

### Bringing boxes into one frame

`PdfElixide.Geometry.Rect.to_user_space/3` maps a displayed box back into raw
user space and `PdfElixide.Geometry.Rect.to_display_frame/3` does the opposite,
each given the page's `PdfElixide.Document.Page.rotation/1` and raw
`PdfElixide.Document.Page.media_box/1`. Map back before handing a box to a call
that takes raw user space — `PdfElixide.Editor.add_redaction/3`,
`PdfElixide.Editor.erase_region/3`, `PdfElixide.Editor.erase_regions/3`,
`PdfElixide.Editor.set_crop_box/3` or `PdfElixide.Document.render/3`'s
`:region` — and only a box that was mapped, since at `90` or `270` the inverse moves a raw
box. Decide per run: a search match's `:bbox` is the union of its spans' boxes,
and on a `90`- or `270`-degree page a match can cross from a horizontal run into
a rotated one, leaving that union in neither frame. Given a document and an
editor open on the same file:

```elixir
alias PdfElixide.Document
alias PdfElixide.Editor
alias PdfElixide.Geometry.Rect

page = Document.page!(doc, 0)
rotation = Document.Page.rotation!(page)
box = Document.Page.media_box!(page)

[match | _] = Document.search!(doc, "Confidential", 0)

for span <- match.spans do
  rect =
    if rotation == 180 or span.rotation != 0.0,
      do: Rect.to_user_space(span.bbox, rotation, box),
      else: span.bbox

  Editor.add_redaction!(editor, 0, rect)
end
```
