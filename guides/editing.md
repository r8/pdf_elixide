# Editing PDFs

`PdfElixide.Editor` changes page structure, rotates and crops pages, covers regions
and adds attachments. Changes stay in memory until you write the document. The [Forms](forms.md)
guide covers filling fields and flattening annotations; the [Encryption](encryption.md)
guide covers password-protected output.

## Saving edits

Use `PdfElixide.Editor.save/3` with its default `incremental: false`, or
`PdfElixide.Editor.to_binary/2`, to write page edits and attachments. Writing leaves the
editor open for further changes; `PdfElixide.Editor.close/1` discards any unsaved edits.

**An incremental save carries field values and document information, and refuses
everything else.** `PdfElixide.Editor.save(editor, path, incremental: true)` appends an
update to a verbatim copy of the original file. Only two kinds of change reach that
update: form field values written with `PdfElixide.Form.put_value/3` — see
[Saving](forms.md#saving) for that workflow — and the `/Info` entries the
`PdfElixide.Editor.set_title/2` family sets. Everything else counts as pending:

  * page deletions and moves
  * page rotations
  * page media and crop boxes
  * erased regions and queued redaction regions
  * redaction marks
  * annotation and form flatten marks
  * attachments

If the editor holds any of those, the save returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` naming them, and writes no
file.

To withdraw pending changes, use `PdfElixide.Editor.clear_erase_regions/2` for
a page's erased regions, `PdfElixide.Editor.unmark_redactions/2` for its redaction
mark, or move pages back into their original order. Incremental saving becomes
available once no unsupported changes remain. Deletions and the other changes
listed above cannot be withdrawn; reopen the source or write a full rewrite.

**Setting rotation or boxes counts as pending even if the value is unchanged.**
Restoring the original value or calling `PdfElixide.Editor.rotate_page_by/3` with
`0` still prevents incremental saving. Only page order is compared with the source.

Marks also count when there is nothing to draw: `PdfElixide.Form.flatten/1` on
a document with no AcroForm and `PdfElixide.Editor.mark_redactions/2` on a page
without `/Redact` annotations both prevent incremental saving.

**A full rewrite in between does not lift the refusal.** An incremental update is
appended to the *original* file whatever was written since, so the pending change
would still be missing from it.

**An editor built with `PdfElixide.Editor.from_binary/2` cannot save incrementally.**
It has no source file to copy, so `incremental: true` returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` even with no edits or only field
values. Use `PdfElixide.Editor.open/2` for incremental saving, or write a full rewrite.

**An encrypted source cannot be saved incrementally.** The call returns
`{:error, %PdfElixide.Error{reason: :unsupported}}`; see
[Incremental saves](encryption.md#incremental-saves).

**Destructive redaction requires a full rewrite.** Once
`PdfElixide.Editor.apply_redactions/1` or `PdfElixide.Editor.sanitize/1` has run,
`incremental: true` is refused because it would leave removed content readable.
A write with `garbage_collect: false` after a sanitize is also refused. See
[What is refused, and why](redaction.md#what-is-refused-and-why).

`PdfElixide.Editor.to_binary/2` refuses `incremental: true` with
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}` regardless of pending edits.
After `PdfElixide.Editor.sanitize/1,2`, requesting `garbage_collect: false` takes
precedence and returns `:unsupported` instead.
Neither writing function accepts encryption with `incremental: true`; see
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

**Angles are quadrants.** `PdfElixide.Editor.set_rotation/3` takes `0`, `90`, `180` or
`270`, and the two relative calls take any multiple of `90` — negative to turn
anticlockwise, past `360` to wrap. Anything else raises `FunctionClauseError` rather
than being rounded to the nearest quadrant. An invalid stored `/Rotate` reads as `0`
before the delta is added, so turning a `45` page by `90` lands on `90`, not `135`.

A rotation belongs to the page rather than to the position, so it follows the page
through `PdfElixide.Editor.move_page/3` and survives the deletion of another page.

Rotation only turns the page as a viewer displays it. Nothing re-lays out the content,
and the page's `/MediaBox` is not swapped, so a `90`-rotated portrait page still reports
portrait dimensions. See [Saving edits](#saving-edits) for the incremental-save
refusal.

## Page boxes

A page has two boxes that matter to a viewer: the `/MediaBox` is the sheet the page
is imposed on, and the optional `/CropBox` is the part of that sheet a viewer displays
and prints. `PdfElixide.Editor.media_box/2` and `PdfElixide.Editor.crop_box/2` read
them, pending changes included; `PdfElixide.Editor.set_media_box/3` and
`PdfElixide.Editor.set_crop_box/3` set one page's, and
`PdfElixide.Editor.crop_margins/2` sets every page's crop box by insetting its media
box:

```elixir
"scan.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.crop_margins!(left: 36, right: 36, top: 24, bottom: 24)
|> PdfElixide.Editor.save!("trimmed.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

Every box is a `PdfElixide.Geometry.Rect` in the page's raw, unrotated user space, so
a box read from `PdfElixide.Document.Page.media_box/1`, or a `bbox` from an extractor
that reports in that space, can be handed straight back. For rotated extractor boxes,
see "Rotated pages and extracted geometry" in `PdfElixide.Document`; only boxes
reported in the displayed frame should pass through
`PdfElixide.Geometry.Rect.to_user_space/3`. A reversed rectangle is normalized before
it is written, and the getters report the box as it will land in the file.

**Cropping hides content; it does not remove it.** Whatever lies outside the crop box
is still in the written file, and anything that reads the content stream still finds
it. Text extraction is not such a reader: a run lying entirely outside the crop box
is dropped from `PdfElixide.Document.text/1` and its siblings, so cropping is a way to
hide text from extraction but not a way to delete it — use
[Redaction](redaction.md) for that. A viewer clips the crop box to the media box, so a
crop box larger than the media box shows the whole page, and nothing here checks one
against the other.

**Setting the media box leaves an existing crop box alone.** A page whose crop box was
declared by the document keeps it after `PdfElixide.Editor.set_media_box/3`, wherever
the new media box lands; call `PdfElixide.Editor.set_crop_box/3` as well when both
should change. Once a page has a crop box it cannot be removed — set it equal to the
media box to show the whole page. The page's content is neither moved nor scaled by
either setter.

`PdfElixide.Editor.crop_margins/2` measures from each page's media box as
`PdfElixide.Editor.media_box/2` reports it, so a media box set earlier in the same
session counts, and it replaces any crop box a page already has. It reads every page
before changing any: if one page has no readable `/MediaBox` the call returns
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}`, and if the margins would leave a
page with no area it returns `{:error, %PdfElixide.Error{reason: :other}}` naming the
page — in both cases with nothing changed. Give such a page a media box with
`PdfElixide.Editor.set_media_box/3` first.

A box belongs to the page rather than to the position, so it follows the page through
`PdfElixide.Editor.move_page/3` and survives the deletion of another page. Where a
box is inherited from the page tree, see "Page boxes and the coordinate origin" in
`PdfElixide.Document` for which ancestor it comes from. See
[Saving edits](#saving-edits) for the incremental-save refusal.

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
confidential content — `PdfElixide.Editor.apply_redactions/1,2` is the call that
removes any, and it removes covered *text* only, leaving images and vector
graphics where they were. The [Redaction](redaction.md) guide covers what each
one does and does not take.

**An erase on a page that `PdfElixide.Editor.apply_redactions/1,2` then rewrites
is silently dropped** — the whiteout never reaches the output and whatever it
covered stays visible. Erase in a separate editor, after the redactions have
been written; see
[It discards other pending overlays on the page](redaction.md#it-discards-other-pending-overlays-on-the-page).

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
`PdfElixide.Document.paths/1`. Rotated extractor boxes follow the same conversion
rules as crop boxes above.

The whiteout inherits the graphics state left by the page content. An active
transformation can move it, a clipping path can hide part or all of it, and an
unfinished path can cause extra content to be covered. These cases still report success.
A redaction block does not behave this way; see
[Where the block lands](redaction.md#where-the-block-lands).
`PdfElixide.Document.rects/2` shows placement, not visibility, and may omit a fill
combined with an unfinished path; `PdfElixide.Document.paths/2` reports the combined
shapes. For a document you did not produce, render the written result to verify
coverage.

A region belongs to the page rather than to the position, so it follows the page through
`PdfElixide.Editor.move_page/3` and survives the deletion of another page.

`PdfElixide.Editor.clear_erase_regions/2` discards the regions pending on a page. It
does not reset `PdfElixide.Editor.modified?/1`, but it does lift the incremental-save
refusal for that page. See [Saving edits](#saving-edits).

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
several files, add them in the same editing session. The error message names the
entries that would be lost.

A `PdfElixide.Editor.sanitize/1,2` that emptied the name tree lifts the refusal, so a
document's attachments can be replaced rather than only removed:

```elixir
editor = PdfElixide.Editor.open!("received.pdf")
PdfElixide.Editor.sanitize!(editor)
PdfElixide.Editor.embed_file!(editor, "figures.csv", csv)
```

This works only when nothing is left in the tree. A sanitize that kept an entry — one
run with `remove_javascript: false`, say — still refuses, and names the entry it is
protecting. A name tree that cannot be read is refused either way.

See [Saving edits](#saving-edits) for the incremental-save refusal.

No media type is written for an attachment. `PdfElixide.Document.EmbeddedFile` reads one
when another producer declared it, but this editor cannot set one.

## Document information

`PdfElixide.Editor.set_title/2`, `PdfElixide.Editor.set_author/2`,
`PdfElixide.Editor.set_subject/2`, `PdfElixide.Editor.set_keywords/2`,
`PdfElixide.Editor.set_creator/2`, `PdfElixide.Editor.set_producer/2`,
`PdfElixide.Editor.set_creation_date/2` and `PdfElixide.Editor.set_mod_date/2`
change the `/Info` dictionary, and `PdfElixide.Editor.metadata/1` reads it with
pending changes applied:

    "report.pdf"
    |> PdfElixide.Editor.open!()
    |> PdfElixide.Editor.set_title!("Quarterly report")
    |> PdfElixide.Editor.set_author!("Ada Lovelace")
    |> PdfElixide.Editor.set_mod_date!(DateTime.utc_now())
    |> PdfElixide.Editor.save!("titled.pdf")

Passing `nil` removes an entry. Each setter takes one string; keywords are stored
as a single comma-separated string, which is how `PdfElixide.Document.Metadata`
reads them back.

### What a write carries

Every write, full rewrite or incremental, carries the source's title, author,
subject, keywords, creator, producer and both dates whether or not you set any
of them, re-encoded as described below — `/Info` is one of the two things an
incremental update carries, per [Saving edits](#saving-edits). Two things do not
survive: `/Trapped`, which cannot be set — `PdfElixide.Editor.metadata/1` reports
the source's value until something clears it — and any non-standard `/Info` key.

`PdfElixide.Editor.sanitize/1` is what clears it. With its default
`scrub_metadata: true` none of those values are carried, `/Trapped` included,
and `PdfElixide.Editor.metadata/1` answers `nil` for every field afterwards;
see [Sanitizing](redaction.md#sanitizing). Nothing is stamped for you: the
producer stays whatever the source named, and `/ModDate` is only what you set,
so set it yourself when a reader will look at it. A whitespace-only value is
written but reads back as `nil`.

### Text encoding

ASCII is written as it stands. Anything else is written as UTF-8 behind a
byte-order mark, the PDF 2.0 spelling (ISO 32000-2 §7.9.2.2), which
`PdfElixide.Document.metadata/1` decodes and PDF 2.0-aware readers such as
Poppler decode too. The file's declared version is not raised, so a reader that
predates PDF 2.0 may show the mark and the raw bytes instead. UTF-16 cannot be
produced.

### Dates

`PdfElixide.Editor.set_creation_date/2` and `PdfElixide.Editor.set_mod_date/2`
take a `DateTime` or a PDF date string.

A `DateTime` is written as `D:YYYYMMDDHHMMSS` followed by `Z` for UTC or by the
offset as `+HH'mm'` / `-HH'mm'`. Fractional seconds are dropped. An offset that
is not a whole number of minutes cannot be spelled, so such a value is written
in UTC and the instant is preserved rather than the wall clock.

A string must be a well-formed PDF date in full; a value read from
`PdfElixide.Editor.metadata/1` qualifies. A malformed string, or one with
anything after the date, raises `ArgumentError`.

### XMP and document identifiers

The XMP packet is not updated: `PdfElixide.Document.xmp_metadata/1` reads back
what the source carried, and a viewer that prefers XMP over `/Info` shows those
values rather than the ones you set. The exception is an encrypted write, which
the [Encryption](encryption.md) guide covers.

The trailer's `/ID` is dropped by a full rewrite, and a write emits one only when
`:encryption` is given.
