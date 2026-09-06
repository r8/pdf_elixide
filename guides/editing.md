# Editing PDFs

`PdfElixide.Editor` changes page structure, rotates pages, covers regions and adds
attachments. Changes stay in memory until you write the document. The [Forms](forms.md)
guide covers filling fields and flattening annotations; the [Encryption](encryption.md)
guide covers password-protected output.

## Saving edits

Use `PdfElixide.Editor.save/3` with its default `incremental: false`, or
`PdfElixide.Editor.to_binary/2`, to write page edits and attachments. Writing leaves the
editor open for further changes; `PdfElixide.Editor.close/1` discards any unsaved edits.

**An incremental save omits page deletions, moves, rotations, erased regions,
attachments and flattening.** `PdfElixide.Editor.save(editor, path, incremental: true)`
appends field-value updates to the original file. The output keeps the original pages,
their order, rotation and content, and the original attachments and unflattened
annotations. The call reports no error for those omitted changes. See
[Saving](forms.md#saving) for the form-filling workflow.

`PdfElixide.Editor.to_binary/2` refuses `incremental: true` with
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}`; an incremental update must be
appended to the original file. Neither writing function accepts encryption with `incremental: true`; see
[Encryption](encryption.md).

## Page structure

`PdfElixide.Editor.delete_page/2` and `PdfElixide.Editor.move_page/3` change which pages
the document has and in what order. Indices are zero-based and count the pages as
currently edited, so `PdfElixide.Editor.page_count/1` is what they are bounded by, and
it moves as soon as a page is deleted rather than waiting for a save:

```elixir
"report.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.move_page!(0, 2)
|> PdfElixide.Editor.delete_page!(0)
|> PdfElixide.Editor.save!("reordered.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

There are two further limitations:

**Deleting a page is not redaction.** It removes the page from the document's page tree,
so the written file has one fewer page and nothing displays it — but the page's objects
and content stream are still in that file as unreferenced data, with
`garbage_collect: true` as much as without. Anyone reading the bytes can recover them. Do not use
`PdfElixide.Editor.delete_page/2` to remove confidential content; write the pages you
want to keep to a new document instead. If every page is deleted, reopening the written
file can discover those orphaned page objects again, so this is not a way to create a
safely page-less PDF either.

**Bookmarks and links are not remapped.** Nothing updates the outline, link annotations,
named destinations, page labels, the structure tree or a form field's widget references,
so entries pointing at a page that was deleted or moved are left pointing where they
were.

## Page rotation

`PdfElixide.Editor.set_rotation/3` turns a page to an absolute angle,
`PdfElixide.Editor.rotate_page_by/3` adds a relative rotation, and
`PdfElixide.Editor.rotate_all_by/2` does that to every page.
`PdfElixide.Editor.rotation/2` reads the angle back, pending changes included:

```elixir
"scan.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.rotate_all_by!(90)
|> PdfElixide.Editor.set_rotation!(0, 0)
|> PdfElixide.Editor.save!("upright.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

A rotation belongs to the page rather than to the position, so it follows the page
through `PdfElixide.Editor.move_page/3` and survives the deletion of another page.

Rotation only turns the page as a viewer displays it. Nothing re-lays out the content,
and the page's `/MediaBox` is not swapped, so a `90`-rotated portrait page still reports
portrait dimensions. See [Saving edits](#saving-edits) for the incremental-save
limitation.

## Erasing regions

`PdfElixide.Editor.erase_region/3` paints a white rectangle over part of a page as the
file is written, and `PdfElixide.Editor.erase_regions/3` does that for several
rectangles in one call. A `PdfElixide.Geometry.Rect` from an extractor can be handed
straight back:

```elixir
doc = PdfElixide.Document.open!("report.pdf")
[span | _] = PdfElixide.Document.spans!(doc, 0)
PdfElixide.Document.close(doc)

"report.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.erase_region!(0, span.bbox)
|> PdfElixide.Editor.save!("covered.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

**Erasing is not redaction.** Covered text and images remain in the written file;
`PdfElixide.Document.text/1` still returns the covered words. Do not use it to remove
confidential content.

The rectangle covers page content only. Annotations — form widgets, stamps, links —
remain above it, even when flattened on the same editor. To hide an annotation whose
rectangle is `rect`, flatten, write, reopen what was written, and erase there:

```elixir
flattened =
  "form.pdf"
  |> PdfElixide.Editor.open!()
  |> PdfElixide.Editor.flatten_annotations!()

bytes = PdfElixide.Editor.to_binary!(flattened)
PdfElixide.Editor.close(flattened)

bytes
|> PdfElixide.Editor.from_binary!()
|> PdfElixide.Editor.erase_region!(0, rect)
|> PdfElixide.Editor.save!("covered.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

A page with no content stream is left as it is. A page whose content streams are stored
as an indirect array — a `/Contents` entry that refers to an array object rather than
holding one — cannot take an overlay, and `PdfElixide.Editor.erase_region/3` returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` for it. Such a page can still be
rotated, moved, deleted and saved.

Coordinates usually use the page's raw, unrotated user space, as reported by
`PdfElixide.Document.chars/1`, `PdfElixide.Document.spans/1` and
`PdfElixide.Document.paths/1`. See "Rotated pages and extracted geometry" in
`PdfElixide.Document` for extractors that report displayed coordinates.

The whiteout inherits the graphics state left by the page content. An active
transformation can move it, a clipping path can hide part or all of it, and an
unfinished path can cause extra content to be covered. These cases still report success.
`PdfElixide.Document.rects/2` shows placement, not visibility, and may omit a fill
combined with an unfinished path; `PdfElixide.Document.paths/2` reports the combined
shapes. For a document you did not produce, render the written result to verify
coverage.

A region belongs to the page rather than to the position, so it follows the page through
`PdfElixide.Editor.move_page/3` and survives the deletion of another page.

`PdfElixide.Editor.clear_erase_regions/2` discards the regions pending on a page. It
does not reset `PdfElixide.Editor.modified?/1`. See [Saving edits](#saving-edits) for
the incremental-save limitation.

## Attachments

`PdfElixide.Editor.embed_file/4` attaches a file to the document — a spreadsheet behind
a report, the source data behind a chart — and `PdfElixide.Editor.embedded_files/1`
lists what the document will carry, pending attachments included:

```elixir
"report.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.embed_file!("figures.csv", csv, description: "Chart data")
|> PdfElixide.Editor.save!("report-with-data.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

**A document that already has a name tree is refused** with
`{:error, %PdfElixide.Error{reason: :unsupported}}`, because attaching a file cannot preserve that
tree's existing attachments, named destinations or document-level JavaScript. To attach
several files, add them in the same editing session.

See [Saving edits](#saving-edits) for the incremental-save limitation.

No media type is written for an attachment. `PdfElixide.Document.EmbeddedFile` reads one
when another producer declared it, but this editor cannot set one.

## Document information is not carried over

Every write emits a trailer with no `/Info` entry, so `PdfElixide.Document.metadata/1`
answers a struct with every field `nil` for the written file, however the source was
populated. A full rewrite drops the dictionary; an incremental save leaves it in the
original bytes but does not repeat the entry in the update's trailer, which is where a
reader looks first.

XMP metadata is unaffected — `PdfElixide.Document.xmp_metadata/1` reads back what the
source carried — unless the write was encrypted, which the [Encryption](encryption.md)
guide covers.

The trailer's `/ID` goes the same way, and a write emits one only when `:encryption` is
given.
