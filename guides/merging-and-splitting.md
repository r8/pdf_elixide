# Merging and splitting

Merging combines several PDF files into one, such as a cover and the chapters that
follow it. Splitting cuts one document into parts, such as a report into one file per
section. Both work on an open `PdfElixide.Editor`: a merge brings pages into the editor
and changes it, and a split writes pages out of it as new binaries and leaves it alone.
Either way, the editor's pending edits travel with its pages.

## Choosing the right call

Three calls keep only some of a document's pages, and they differ in what they change
and what they leave behind:

| | `PdfElixide.Editor.keep_pages/2` | `PdfElixide.Editor.extract_pages/2` | `PdfElixide.Editor.delete_page/2` |
|---|---|---|---|
| Changes the editor | yes | no | yes |
| Result | the editor, written later | a new PDF binary | the editor, written later |
| Order of the kept pages | as listed | as listed | unchanged |
| Content of the pages left out | stays in the written file, unreferenced | left out, unless something still refers to it | stays in the written file, unreferenced |

`keep_pages/2` and `delete_page/2` rearrange the open document and are covered under
[Page structure](editing.md#page-structure). None of the three is a reliable way to
remove content; see [Extraction is not redaction](#extraction-is-not-redaction).

## Merging documents

`PdfElixide.Editor.merge/2` appends every page of a PDF file to the end of the
editor, and `PdfElixide.Editor.merge_binary/2` does the same for a PDF binary:

```elixir
"cover.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.merge!("chapter_1.pdf")
|> PdfElixide.Editor.merge!("chapter_2.pdf")
|> PdfElixide.Editor.save!("book.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

A merge incorporates the editor's pending edits into the combined document. Afterwards,
the editor behaves as if it had been opened on a file that already held every page:

  * Merged pages are ordinary pages: `PdfElixide.Editor.delete_page/2`,
    `PdfElixide.Editor.move_page/3`, rotation and page boxes work on them as on any other.
  * Pending edits become part of the document. Flatten marks and erased regions are
    drawn, and their warnings stay available from `PdfElixide.Editor.flatten_warnings/1`.
    Pending redactions are refused instead; see below.
  * Attachments become part of the document, so `PdfElixide.Editor.embed_file/4` is refused
    from then on; see [Attachments](editing.md#attachments).
  * `PdfElixide.Editor.modified?/1` reports `true` until the next full write, and an
    incremental save is refused.

Repeated merges become more expensive as the combined document grows.

### What a merge keeps

Merged pages keep their content, rotation, media box and crop box. A page that had no
crop box may report an explicit crop box equal to its media box after merging.
What belongs to the merged document as a whole is not carried, such as its form fields
and signatures, bookmarks, named destinations, page labels, structure tree, attachments
and document information. A resource
that several of its pages share, such as an embedded font, is written once for each page
that uses it, so the result can be larger than the two documents together.

The combined document keeps this editor's declared PDF version, even when the merged
document declares a later one. This library cannot change the declared version. If a
downstream tool requires it to match, merge into a document of the required version or
adjust the version with another tool.

### When a merge is refused

Some documents are refused with `{:error, %PdfElixide.Error{reason: :unsupported}}`, and
the editor is left as it was:

  * **A page with annotations.** Links, comments and form fields refer to other pages
    or to the document's form, and a merge would leave them pointing outside the result.
    Flattening them in that document first with `PdfElixide.Editor.flatten_annotations/1`
    and `PdfElixide.Form.flatten/1`, then merging the written result, usually removes
    them; a page where any remain is refused again.
  * **A page that refers to other pages in any other way**, such as an article thread
    that continues on another page, a page action that goes to one (by page or by a
    named destination) or to an article thread, a color separation group or presentation
    steps. The error names what the page holds.
  * **A page action that runs JavaScript or acts on form fields or attachments**, such
    as one that resets, submits or imports form data, hides a field by name, or opens an
    attachment of that document. Once merged it would act on this document's fields and
    attachments instead. `PdfElixide.Editor.sanitize/2` removes only document-level
    JavaScript, so it cannot prepare such a page for merging.
  * **A page that uses layers (optional content).** The merged document's layer settings
    are not carried, so a hidden layer would show and the list of layers would be lost.
  * **A page that takes its fonts, images or other resources from its page tree** rather
    than declaring them itself. The merged page would lose them.
  * **A page that declares no resources at all, when this document's page tree
    declares some.** The merged page would take this document's fonts and images as its
    own. Such a page merges into a document whose page tree declares none.
  * **A tagged page, when this document is tagged too.** The page's structure entries
    would attach its content to this document's structure elements, so assistive
    technology would read it in the wrong place. A tagged page merges into an untagged
    document, where its structure is not carried.
  * **A page with an excessively nested object graph.**
  * **An editor with a pending redaction**: a region queued with
    `PdfElixide.Editor.add_redaction/3`, or a page marked with
    `PdfElixide.Editor.mark_redactions/2` that has redaction annotations. The merge would
    lose it, and a later `PdfElixide.Editor.apply_redactions/1` would remove nothing.
    Apply it first, or withdraw a mark with `PdfElixide.Editor.unmark_redactions/2`.
    A region queued after `PdfElixide.Editor.apply_redactions/1` has run cannot be
    applied in that editor at all: write it with `PdfElixide.Editor.to_binary/2`,
    open the result, and redact it there before merging. An editor whose
    `PdfElixide.Editor.apply_redactions/1` failed is refused too: discard it and reopen
    the source.
  * **An editor with no pages.** Merge before deleting the last page.

Merging an unencrypted document with no pages changes nothing and succeeds.

An encrypted document returns `{:error, %PdfElixide.Error{reason: :encrypted}}`, even one
that opens without a password. Open it as an editor, with its password if it needs one,
write it with `PdfElixide.Editor.to_binary/2`, and merge the result with
`PdfElixide.Editor.merge_binary/2`.

### Taking only some pages from another document

A merge takes every page of the other document. To take only some, extract them from
that document first and merge the result:

```elixir
source = PdfElixide.Editor.open!("appendix.pdf")
second_page = PdfElixide.Editor.extract_pages!(source, [1])
PdfElixide.Editor.close(source)

"report.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.merge_binary!(second_page)
```

The extracted pages carry the other editor's pending edits, and the merge refuses them
for the same reasons it would refuse the whole document.

## Splitting a document

`PdfElixide.Editor.extract_pages/2` writes the listed pages, in the order given, to a new
PDF binary without changing the editor's pages or pending edits. `File.write!/2` saves
one:

```elixir
editor = PdfElixide.Editor.open!("report.pdf")

File.write!("summary.pdf", PdfElixide.Editor.extract_pages!(editor, [0, 1]))
```

Extracted documents include pending edits but are not encrypted. Open one with
`PdfElixide.Editor.from_binary/2` and write it with `:encryption` if it needs a password.
An empty list or a repeated index raises `ArgumentError`, and a page the document
cannot resolve returns `{:error, %PdfElixide.Error{reason: :invalid_pdf}}` rather than
being left out.

### Parts and chunks

`PdfElixide.Editor.extract_page_ranges/2` does the same for each of several inclusive
ranges, and returns the binaries in the order of the ranges. Ranges may overlap:

```elixir
[front, back] = PdfElixide.Editor.extract_page_ranges!(editor, [0..9, 10..19])
```

To cut a document into parts of a fixed size, build the ranges from the page count:

```elixir
chunks =
  0..(PdfElixide.Editor.page_count!(editor) - 1)//1
  |> Enum.chunk_every(10)
  |> Enum.map(fn pages -> List.first(pages)..List.last(pages) end)

editor
|> PdfElixide.Editor.extract_page_ranges!(chunks)
|> Enum.with_index(1)
|> Enum.each(fn {bytes, n} -> File.write!("part-#{n}.pdf", bytes) end)
```

All the binaries from one call are in memory together. To hold only one at a time, call
`PdfElixide.Editor.extract_pages/2` once per part.

### Extraction is not redaction

`PdfElixide.Editor.extract_pages/2` leaves out the pages you did not list, but only when
nothing else in the document still refers to them. Anything that does — a bookmark, link
or named destination targeting the page, or a form field whose widget sits on it, for
example — keeps that page and its content stream in the extracted file, where anyone
reading the bytes can recover it. Do not rely on extraction to keep content confidential;
see the [Redaction](redaction.md) guide for removing it.
