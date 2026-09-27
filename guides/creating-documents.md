# Creating documents

`PdfElixide.Editor.from_markdown/2`, `from_html/2` and `from_plain_text/2`
lay text out in a new PDF and return an editor. You can edit it further, write
it to a file, or return it as a binary:

```elixir
"# Report\n\nAll **good**."
|> PdfElixide.Editor.from_markdown!(title: "Report")
|> PdfElixide.Editor.save!("report.pdf")
|> PdfElixide.Editor.close()
```

These functions are simple typesetters, not the reverse of the document
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

## Page layout

All three functions accept page size, top, bottom and left margins, and line
spacing. Markdown and HTML also accept a body font size. See
`t:PdfElixide.Editor.create_opts/0` and
`t:PdfElixide.Editor.plain_text_create_opts/0` for defaults and validation.

There is no right-margin option because lines are not wrapped. A custom page
must leave enough vertical room for at least two lines and enough horizontal
room after the left margin. Invalid layouts raise `ArgumentError` before the
document is created.
