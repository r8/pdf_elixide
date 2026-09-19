# Rendering

`PdfElixide.Document.render/3` turns a page into a raster image, and
`PdfElixide.Document.Page.render/2` does the same with the index already pinned.
Both answer with a `PdfElixide.Document.RenderedPage` carrying the encoded bytes
and their pixel size.

```elixir
alias PdfElixide.Document

doc = Document.open!("path/to/file.pdf")
page = Document.page!(doc, 0)

rendered = Document.Page.render!(page, dpi: 150)
#=> #PdfElixide.Document.RenderedPage<1275x1650 png>

File.write!("page0.png", rendered.data)
```

Render a page at a time to limit memory use: a Letter page at 150 DPI is about
two megapixels, with four bytes per pixel in `:rgba8` format.

```elixir
doc
|> Stream.with_index()
|> Stream.map(fn {page, i} -> File.write!("page#{i}.png", Document.Page.render!(page).data) end)
|> Stream.run()
```

## Sizing the output

`:dpi` is the direct control — 72 DPI makes one pixel per PDF point, so the
output matches the page's size in points, and every other value scales from
there. `:dpi` defaults to 150.

When you want the result to fit a box rather than to have a particular
resolution — a thumbnail, a preview pane — use `:fit` instead and let the DPI
fall out of it. The page is scaled to fit inside the box on both axes with its
aspect ratio preserved, so it fills the box on one axis and stops short on
the other:

```elixir
Document.Page.render!(page, fit: {240, 320})
#=> #PdfElixide.Document.RenderedPage<240x311 png>
```

A Letter page is proportionally wider than a 240 x 320 box is, so the width
binds and the result stops short of the box's height.

`:dpi` and `:fit` cannot be given together; passing both raises `ArgumentError`
rather than letting one of them silently win.

**There is a limit on how large a render may be.** Past roughly 256 million
pixels the call returns `{:error, %PdfElixide.Error{reason: :unsupported}}`,
naming the size it would have needed:

```elixir
Document.render(doc, 0, dpi: 20_000)
#=> {:error, %PdfElixide.Error{reason: :unsupported,
#     message: "rendering this page would need 170000x220000 pixels, over the ..."}}
```

Match on `:unsupported` and retry with a lower `:dpi` or smaller `:fit` box.
On 32-bit builds the limit is roughly 64 million pixels. The error message
reports the pixels the render would need and the applicable limit, and names
the buffer count when more than one full-page buffer is budgeted.

The budget includes all full-page buffers, so CMYK-profiled documents with
spot inks can reach the limit at a lower DPI than ordinary pages of the same size.

## What the raster covers

**The MediaBox, never the CropBox.** A page a viewer shows cropped — trimmed
proofs, imposed sheets, anything with printer's marks outside the visible
area — renders here at full bleed, including the parts the viewer hides. To
match what a reader sees, read the crop box and pass it back as a `:region`:

```elixir
case PdfElixide.Document.Page.crop_box!(page) do
  nil -> Document.Page.render!(page)
  crop -> Document.Page.render!(page, region: crop)
end
```

**A page whose `/MediaBox` cannot be read still renders, at US Letter.** Where
`PdfElixide.Document.Page.media_box/1` reports `{:error, %{reason: :invalid_pdf}}`
for a missing or malformed box, the renderer substitutes 612 × 792 points and
carries on. A successful render is therefore never evidence that the page's
geometry is sound — check the box directly if that matters. The one exception
is `:region`: a crop needs the real box, so on such a page it returns
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}` instead.

Which ancestor a page inherits its box and rotation from is not stable across a
long document; see the "Page boxes and the coordinate origin" section of
`PdfElixide.Document` for when that changes and why.

## Cropping with `:region`

`:region` takes a `PdfElixide.Geometry.Rect` in PDF points, with the origin at
the bottom-left of the page, so a `bbox` from an extractor that reports in that
space goes straight back in — render the table you just found, or the image,
without computing anything:

```elixir
[%{bbox: %PdfElixide.Geometry.Rect{} = bbox} | _] = Document.tables!(doc, 0)
Document.render!(doc, 0, region: bbox, dpi: 200)
```

There is no `:region_mode` here; the rectangle is a crop, not a filter. The
extractors that pair the two are `text`, `words`, `text_lines`, `chars`,
`spans` and `tables`.

That space is the page's raw, unrotated user space — what
`PdfElixide.Document.Page.media_box/1` and
`PdfElixide.Document.Page.crop_box/1` report. A page turned by `/Rotate` and a
page whose box does not start at the origin both crop where you asked, even
though the raster they are cut from is turned and shifted.

**On a rotated page, not every extractor reports in that space.** Some hand back
displayed coordinates, and a box taken from one of them crops the wrong part of
the page. The "Rotated pages and extracted geometry" section of
`PdfElixide.Document` explains which boxes need
`PdfElixide.Geometry.Rect.to_user_space/3`. Page boxes are never mapped, so the
crop-box recipe further up holds whatever the rotation.

A rectangle that pokes over an edge is clipped to the page, so what comes back
is the part of it that is actually there and is smaller than the rectangle —
worth checking `width` and `height` if the size matters to you. A rectangle with
no area on the page at all is an error rather than a sliver:

```elixir
region = %PdfElixide.Geometry.Rect{x: 5_000.0, y: 0.0, width: 100.0, height: 80.0}
Document.render(doc, 0, region: region)
#=> {:error, %PdfElixide.Error{reason: :out_of_range}}
```

**Cropping does not make a render cheaper.** The page is rasterized in full and
the result is then cut down, so both the time and the size limit are the whole
page's however small the region is. `:region` also cannot be combined with
`format: :rgba8`, and with `:fit`; both raise `ArgumentError`.

## Formats and transparency

`:format` is `:png` (the default), `:jpeg`, or `:rgba8`.

`:png` and `:jpeg` give a complete file, ready to write to disk or serve.
`:jpeg_quality` runs from 1 to 100 and defaults to 85; it is inert for the other
two formats. A value outside that range raises rather than being clamped.

Use `:rgba8` to feed an image pipeline without encoding and decoding an image.
See `PdfElixide.Document.RenderedPage` for the byte layout and alpha convention.

`:background` is the colour painted before the page's own content. It defaults
to opaque white; `nil` paints nothing at all, so everything the page does not
cover stays transparent:

```elixir
Document.Page.render!(page, background: nil)                              # transparent PNG
Document.Page.render!(page, background: %PdfElixide.Color.RGB{r: 0.9, g: 0.9, b: 1.0})
```

Components run from `0.0` to `1.0`, as everywhere else in this library. One
outside that range raises instead of being quietly replaced with white.

**`nil` is only transparency in a format that has alpha.** JPEG has none, so a
`format: :jpeg` render with `background: nil` comes back with every uncovered
area **black** — which on a page with margins is most of it. Name the colour you
want whenever the format cannot carry the absence of one.

## Annotations

`:render_annotations` defaults to `true`, so the appearance streams of form
fields, stamps, highlights and signatures are painted over the page content the
way a viewer shows them. Set it to `false` for the page as its author drew it,
without anything added afterwards.

This is painting the annotation's own appearance, not filling one in. Changing
what a field *says* is `PdfElixide.Form`'s job, and flattening it into the page
permanently is `PdfElixide.Editor`'s; see the [Forms](forms.md) guide.

## Layers, and how rendering differs from extraction

**A render honours the document's own layer configuration; text extraction does
not.** An optional-content group the document marks off by default is left
unpainted here, while `PdfElixide.Document.text/2` still reads the text inside
it. The same document can therefore render without a watermark whose words the
extractor returns.

Both surfaces take the same vocabulary — the names `PdfElixide.Document.layers/1`
reports — so passing the same list to both is how you make them agree:

```elixir
hidden = ["Draft watermark"]

Document.Page.render!(page, exclude_layers: hidden)
Document.text!(doc, 0, exclude_layers: hidden)
```

Pass a name back exactly as `layers/1` gave it; the match is on the whole string.
A name that matches no group is ignored rather than reported, so a typo shows up
as a layer that failed to disappear.

## Fonts

Text is drawn with the fonts the PDF embeds. Where a page names a font it does
not embed, the renderer resolves it against the fonts installed on the host —
which means **the same document can render differently on two machines**, and on
a minimal container with no fonts installed at all, text in non-embedded fonts
can come out substituted or missing while the rest of the page is unaffected. If
byte-identical output across machines matters, install a known font set, or
check that your documents embed their fonts.

The first render in an OS process scans the system font directories once and
caches the result for the life of the node, so that call is measurably slower
than the ones after it. Renders do not each pay it.

## Separation plates

For prepress work, `PdfElixide.Document.separations/3` renders one grayscale
plate per ink rather than one composite image:

```elixir
plates = Document.Page.separations!(page, dpi: 300)
Enum.map(plates, & &1.ink)
#=> ["Cyan", "Magenta", "Yellow", "Black", "PANTONE 185 C"]
```

The four process inks are always present, followed by every spot ink reachable
from the page — the list `PdfElixide.Document.inks/3` reports with
`deep: true`, less any spot ink that shares a process ink's name. An ink the
page declares but never actually paints comes back as
an all-zero plate rather than being left out, so the list is stable for a page
and a returned plate is not evidence the ink is used.

See `PdfElixide.Document.SeparationPlate` for the byte layout, ink-coverage
values and how to display a plate.

Use `PdfElixide.Document.separation/4` for one ink and
`PdfElixide.Document.separations/3` for several. The full ink set counts toward
the size limit even when requesting one plate. Pages with many spot inks can
reach the limit at a lower DPI and return
`{:error, %PdfElixide.Error{reason: :unsupported}}`; retry with a lower `:dpi`.

## Rasterizing a whole document

`PdfElixide.Document.rasterize/2` renders every page and returns a new PDF built
from those images:

```elixir
File.write!("flat.pdf", Document.rasterize!(doc, dpi: 200))
```

Everything underneath the pixels is gone — the text layer, form fields,
annotations, links, outline and tagging — replaced by one picture per page.

Note what this is *not*: it is not redaction. Content that was visible is still
visible, just as pixels; it is the structure underneath that is destroyed, not
anything the page showed.

**It does not preserve the original's page geometry.** Look at one before you
adopt it:

  * every page comes back **US Letter**, 612 x 792 points, whatever the source
    page measured — a 200 x 200 pt page and an A4 page both become Letter;
  * the rendered page is scaled into a **one-inch margin** on all four sides and
    centred, so a full-bleed original ends up as a smaller picture with a white
    border around it;
  * page rotation is baked into the pixels and `/Rotate` resets to `0` — the one
    part of this that is faithful, since the raster is already turned.

To preserve page sizes, render the pages with `PdfElixide.Document.render/3`
and assemble them with a tool that lets you set the page box.

Memory grows with page count and compressed image size. Scanned or photographic
pages typically cost more memory than text pages at the same DPI. The size limit
applies per page, not to the document as a whole. Calls are serialized; see
Concurrency below.

## Concurrency

See the [Concurrency](concurrency.md) guide for parallel page rendering and
node-wide serialization of `PdfElixide.Document.rasterize/2` calls.
