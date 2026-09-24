# Office documents

`PdfElixide.Document.to_docx/2`, `PdfElixide.Document.to_pptx/2` and
`PdfElixide.Document.to_xlsx/2` convert a PDF to a Word, PowerPoint or Excel
file. `PdfElixide.Office.to_pdf/1` converts such a file to a PDF. Both
directions work on bytes: an export returns the Office file as a binary, and
an import takes one and returns the PDF as a binary.

```elixir
alias PdfElixide.Document
alias PdfElixide.Office

doc = Document.open!("path/to/report.pdf")
File.write!("report.docx", Document.to_docx!(doc, mode: :flow))
:ok = Document.close(doc)

pdf = Office.to_pdf!(File.read!("path/to/slides.pptx"))
File.write!("slides.pdf", pdf)
```

The mode passed to the export decides how the pages are laid out. It also
decides whether the file can be converted back to PDF with its pages intact —
see [Round trips](#round-trips).

## Choosing a mode

Every export takes a `:mode`:

  * `:layout` places each run of text where it sits on the PDF page, as its own
    positioned frame (DOCX), text box (PPTX) or shape (XLSX). The result looks
    like the source, but editing it means moving dozens of small boxes, and a
    long document produces a file that is slow to open.
  * `:flow` groups the text into paragraphs (DOCX), text on slides (PPTX) or
    cells (XLSX) that flow like an ordinary document. The result is easy to
    edit and to search, but positions on the page are not kept.
  * `:auto`, the default, uses `:layout` for short documents and `:flow` for
    long ones.

Give `:layout` or `:flow` explicitly when the output must not depend on how
many pages the source has — in a pipeline whose consumer expects one shape, or
in a test.

`:flow` is also the only mode that writes the document's title, author,
subject and keywords into the Office file's properties.

## What an export carries

  * **Text**, in its font and size, and in `:layout` at its position.
  * **Images**, in every format and mode.
  * **Embedded fonts**, copied into the Office file so that it shows the
    source's typefaces on a machine that does not have them installed.
  * **One section, slide or worksheet per page**, with one exception: a very
    long document exported to PPTX in `:flow` — which `:auto` chooses for long
    documents — may have several pages combined onto one slide. Pass
    `mode: :layout` to keep one slide per page.

What it does not carry:

  * **Tables arrive as text**, not as Word or PowerPoint tables. Use
    `PdfElixide.Document.tables/1` when the table structure is what you need.
  * **Vector drawings** — lines, boxes, charts drawn as paths — are
    approximated at best in `:layout` and dropped in `:flow`.

## Encrypted and damaged documents

An encrypted document must be authenticated before it can be exported. Until
then, every export returns an error rather than a file with empty pages:

```elixir
doc = Document.open!("path/to/protected.pdf")

Document.to_docx(doc)
#=> {:error, %PdfElixide.Error{reason: :encrypted,
#     message: "the document is encrypted; authenticate before exporting to DOCX"}}

{:ok, true} = Document.authenticate(doc, "secret")
{:ok, docx} = Document.to_docx(doc)
:ok = Document.close(doc)
```

Opening with `Document.open(path, password: "secret")` has the same effect.

A page whose object cannot be read at all fails the export, as it fails the
other whole-document converters — see the "When a page cannot be read" section
of `PdfElixide.Document`. Content that is damaged *inside* a readable page does
not: that page is exported with whatever could be read from it, possibly
nothing, and the call still succeeds.

## Converting Office files to PDF

`PdfElixide.Office.to_pdf/1` returns a new PDF's bytes, which can be opened
as a document or an editor, or written out as they are.

The format is detected from the contents rather than a filename. See
`PdfElixide.Office` for the accepted variants and
`PdfElixide.Office.to_pdf/1` for its error contract. That contract makes an
upload boundary straightforward:

```elixir
case Office.to_pdf(upload) do
  {:ok, pdf} -> {:ok, pdf}
  {:error, %PdfElixide.Error{reason: :unsupported}} -> {:error, :unsupported_file}
  {:error, %PdfElixide.Error{} = error} -> {:error, error}
end
```

A document that does not set its own page size is laid out on US Letter
pages.

## Round trips

A multi-page DOCX whose text sits in positioned frames converts to PDF on a
**single page**, with the text of every page drawn over it. That is exactly
what `:layout` writes, and what `:auto` writes for a short document, so a
PDF → DOCX → PDF round trip needs `:flow`:

```elixir
source = Document.open!("path/to/report.pdf")
docx = Document.to_docx!(source, mode: :flow)
:ok = Document.close(source)

back = Document.from_binary!(Office.to_pdf!(docx))
:ok = Document.close(back)
```

A `:flow` DOCX comes back with one page per source page, except that a last
page with no text on it can be lost; blank pages earlier in the document are
kept.

XLSX exports keep their pages through a round trip in either mode, and PPTX
exports do too unless a very long document had pages combined onto shared
slides. Nothing about the round trip is lossless: the second PDF is rebuilt
from what the Office file carried — see
[What an export carries](#what-an-export-carries).

## Fonts

When importing an Office file to PDF, text is set in its embedded fonts or in
a standard PDF font. For characters outside the Latin-1 range that those fonts
do not cover, the import looks for a fallback font file at fixed paths and uses
the first one that exists. It does not ask the operating system where fonts
are installed. For most scripts, the paths are:

  * `/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf`
  * `/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf`
  * `/usr/share/fonts/TTF/DejaVuSans.ttf`
  * `/Library/Fonts/DejaVuSans.ttf`
  * `/usr/share/fonts/truetype/freefont/FreeSans.ttf`
  * `/usr/share/fonts/gnu-free/FreeSans.ttf`
  * `/usr/share/fonts/chromeos/noto/NotoSans-Regular.ttf`
  * `/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf`
  * `/usr/share/fonts/chromeos/croscore/Arimo-Regular.ttf`
  * `/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf`

and for Chinese, Japanese and Korean:

  * `/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf`
  * `/usr/share/fonts/android/DroidSansFallbackFull.ttf`
  * `/usr/share/fonts/opentype/ipafont-gothic/ipag.ttf`
  * `/usr/share/fonts/chromeos/ko-nanum/NanumGothic.ttf`
  * `/usr/share/fonts/opentype/unifont/unifont.otf`

When none of these files exists, those characters come out as missing-glyph
boxes, so the same file can convert differently on two machines. On Linux,
install a font package that puts one of the files above in place, and check
the path with `ls`. On macOS, only DejaVu Sans copied to `/Library/Fonts` is
found; a font installed for one user goes to `~/Library/Fonts`, which is not
searched, and none of the Chinese, Japanese or Korean paths exists. On Windows
none of these paths exists. There, and for Chinese, Japanese or Korean text on
macOS, the only way to convert such text is for the Office file to embed its
fonts.

The search runs once, the first time a conversion needs a fallback font, and
its result is kept until the VM restarts. That includes finding nothing, so a
font installed while the node is running is not used until it is restarted.

## Memory and concurrency

An export converts the whole document in one call and returns the file as a
single binary, which briefly exists twice — see the "Whole-document extraction
and memory" section of `PdfElixide.Document`. An import briefly holds two
copies of the Office file while it reads it, and two copies of the PDF bytes as
it returns them.

An import's memory follows the size of the file's contents once unzipped, not
the size of the upload. Each part of the package may unpack to as much as
512 MiB, so a file of well under a megabyte can take hundreds of megabytes to
convert. Summing the sizes `:zip.list_dir/2` reports before calling `to_pdf/1`
lets a service reject a well-formed package whose declared uncompressed size
exceeds its limit. Those sizes are supplied by the file, and a crafted file can
declare less than it holds. For such a file, the 512 MiB limit per part is the
only bound. A service converting untrusted uploads should budget memory against
that limit and limit how many conversions run at once.

Exports read the document the way the other extractors do, so many processes
can export from one open document concurrently. They extract the document's
text, so the advice about tagged PDFs in [Concurrency](concurrency.md) applies
to them too. Imports take no document handle, so they run independently of
each other.
