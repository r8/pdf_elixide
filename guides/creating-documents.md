# Creating documents

`PdfElixide.Editor.from_markdown/2`, `from_html/2` and `from_plain_text/2`
lay text out in a new PDF, and `from_images/2` places images on new pages.
Each returns an editor. You can edit it further, write it to a file, or return
it as a binary:

```elixir
"# Report\n\nAll **good**."
|> PdfElixide.Editor.from_markdown!(title: "Report")
|> PdfElixide.Editor.save!("report.pdf")
|> PdfElixide.Editor.close()
```

The text functions are simple typesetters, not the reverse of the document
conversion functions. Lines are not wrapped, so break long lines in the
source. Editors created this way have no source file and cannot be saved
incrementally.

## Markdown

Markdown creation recognises `#` to `####` headings, paragraphs, `-` and `*`
bullets, `>` quotes, fenced code blocks, pipe tables, and `**bold**`,
`*italic*` and `` `code` `` spans. Block constructs must start at the beginning
of an unindented line. Numbered lists, links, deeper headings and indented
bullets appear as source text.

Long runs of blank lines can make a later line print over the first line of
the page instead of starting a new page, especially on a short custom page.
Collapse repeated blank lines in Markdown and HTML input.

## HTML

HTML creation accepts fragments rather than complete web pages. It recognises
lower-case, attribute-free `<h1>` to `<h4>`, `<p>`, `<br>`, `<b>`, `<strong>`,
`<i>`, `<em>`, `<code>`, `<pre>`, `<ul>`, `<ol>` and `<li>` tags. Ordered and
unordered list items both become bullets.

Pass body content with each block on its own unindented line. Source line
breaks and indentation are preserved, so pretty-printed or inline block tags
may appear as literal Markdown markers instead of receiving their intended
formatting. Tags with attributes or upper-case names are not recognised.

Other tags are removed but their contents remain. This includes `title`,
`style` and `script` content, so do not pass a complete HTML document. `<h5>`
and `<h6>` print with literal `#####` and `######` markers. Entities are not
decoded. A literal `<` starts a tag-like region and can discard text up to the
next `>` or the end of the input, and a lone `>` is removed; avoid angle
brackets in running text.
The remaining text is laid out as Markdown, so Markdown-looking source may be
formatted.

Use `<pre>x</pre>` rather than `<pre><code>x</code></pre>`: a `code` tag inside
`pre` is printed as backticks.

## Characters and fonts

Markdown and HTML embed a font when the input needs characters beyond
Windows-1252. It covers Latin, Greek, Cyrillic, Hebrew, Arabic and common
symbols, but not Chinese, Japanese, Korean, Indic or Thai text and many emoji.
Missing characters may print as an empty box and disappear from extracted
text even though creation succeeds.

Hebrew and Arabic are drawn left to right without Arabic letter joining.
Italic becomes upright when the embedded font is used. Code spans, code blocks
and tables use Courier and show `?` for characters outside Windows-1252.

Plain-text creation uses 12-point Helvetica and accepts Windows-1252
characters only; see `PdfElixide.Editor.from_plain_text/2` for the error other
characters return.

## Images

`from_images/2` takes a list of JPEG and PNG binaries and puts each on its own
page, in list order:

```elixir
["page1.jpg", "page2.png"]
|> Enum.map(&File.read!/1)
|> PdfElixide.Editor.from_images!(page_size: :a4)
|> PdfElixide.Editor.save!("scans.pdf")
|> PdfElixide.Editor.close()
```

Every page has the size given by `:page_size`. Each image is scaled, up or
down and keeping its proportions, until it fills the area inside the four
margins in one direction, and is centred in that area. With the defaults, a
landscape photo therefore lies across the middle of a Letter page with an
inch of white on either side and more above and below.

Pages are not sized to their images. To make a page that matches a single
image, give a page size in points computed from its pixel size and the
resolution you want it to have, with every margin set to zero. At 300 dots
per inch, a 2480 × 3508 pixel scan is 595.2 × 841.92 points:

```elixir
PdfElixide.Editor.from_images!([scan],
  page_size: {2480 * 72 / 300, 3508 * 72 / 300},
  margin_top: 0,
  margin_bottom: 0,
  margin_left: 0,
  margin_right: 0
)
```

Because one page size applies to the whole list, images of different shapes
in one call cannot each fill their page. Build one editor per image and
combine them with `PdfElixide.Editor.merge_binary/2` if they must.

A JPEG is embedded without re-encoding, so it keeps its quality and size. A
PNG is decoded and its pixels stored losslessly, so an 8-bit PNG keeps every
pixel exactly. Transparency is kept, 16-bit channels are reduced to 8 bits,
and colour profiles and gamma are ignored. GIF, WebP, TIFF, HEIC and other
formats are refused, and so are damaged and very large images;
`PdfElixide.Editor.from_images/2` lists the errors and size limits.

An EXIF orientation tag is not applied: each image is placed the way its
pixels are stored. Phones and cameras often store a photo sideways and record
its rotation in that tag, so such a photo comes out sideways, upside down or
mirrored, and is laid out by its stored shape. Rotate the pixels first with a
tool that applies the tag, such as `magick photo.jpg -auto-orient upright.jpg`.

CMYK JPEGs are embedded without colour correction, so most of them, including
those from Photoshop and ImageMagick, come out with inverted colours. Convert
them to RGB first.

## Page layout

The three text functions accept page size, top, bottom and left margins, and
line spacing. Markdown and HTML also accept a body font size. See
`t:PdfElixide.Editor.create_opts/0` and
`t:PdfElixide.Editor.plain_text_create_opts/0` for defaults and validation.
`from_images/2` accepts page size and all four margins; see
`t:PdfElixide.Editor.image_create_opts/0`.

The text functions have no right-margin option because lines are not
wrapped. A custom page must leave enough vertical room for at least two lines
and enough horizontal room after the left margin. Invalid layouts raise
`ArgumentError` before the document is created.
