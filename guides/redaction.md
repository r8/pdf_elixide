# Redaction

Two different operations share the word. One paints a box over content and
leaves it in the file; the other deletes it. `PdfElixide.Editor` offers both,
and choosing the wrong one is the mistake this guide exists to prevent.

| | `mark_redactions/1,2` | `apply_redactions/1,2` |
|---|---|---|
| when it happens | at the next full write | immediately, on the call |
| what it does | paints an opaque box | removes the covered text, then paints a box |
| the text afterwards | still extractable | gone from the file |
| images and graphics afterwards | still there | still there |
| reversible | yes, `unmark_redactions/2` | no |
| what it acts on | the page's `/Redact` annotations | those plus `add_redaction/3,4` regions |

**Only `PdfElixide.Editor.apply_redactions/1` removes anything.** If the point is
that nobody can recover the content, that is the call you need, and the check
that it worked is that the words are gone from the written document's text:

```elixir
editor = PdfElixide.Editor.open!("report.pdf")

report =
  editor
  |> PdfElixide.Editor.mark_redactions!(0)
  |> PdfElixide.Editor.apply_redactions!()

report.glyphs_removed
#=> 6

written =
  editor
  |> PdfElixide.Editor.to_binary!()
  |> PdfElixide.Document.from_binary!()

PdfElixide.Document.text!(written, 0) =~ "Secret"
#=> false

PdfElixide.Document.close(written)
PdfElixide.Editor.close(editor)
```

Extracting the text rather than scanning the written bytes is deliberate: a
content stream is usually compressed, so a `:binary.match/2` on the output can
answer `:nomatch` for text that is still in the file. See
[Verifying](#verifying).

## Marking, and what a mark is for

`PdfElixide.Editor.mark_redactions/2` schedules one page, and
`PdfElixide.Editor.mark_redactions/1` every page. Neither draws anything by
itself: the boxes come from the `/Redact` annotations the document already
carries — placed by whatever tool prepared it — using each annotation's `/IC`
colour, or black where it declares none.

Nothing happens until the next full write, `PdfElixide.Editor.save/3` without
`:incremental` or `PdfElixide.Editor.to_binary/2`. An incremental save is refused
while the mark is pending, since it could only write the original back unmarked;
see [Saving edits](editing.md#saving-edits).
`PdfElixide.Editor.unmark_redactions/2` takes the mark back — and with it the
refusal — and `PdfElixide.Editor.marked_for_redaction?/2` reports it.

**A mark is not redaction.** The box is drawn over the existing page content,
which stays exactly where it was: `PdfElixide.Document.text/1` on the written
file still returns the covered words, and anything that reads the content stream
still finds them. Use a mark to make a document *look* redacted — to reproduce
what an authoring tool intended — and never to keep a secret.

## Removing content

`PdfElixide.Editor.apply_redactions/1` rewrites the content streams of the
pages it processes: glyphs inside a region are deleted, not covered, and an
opaque block is drawn over the cleared area. It happens as the call returns
rather than at the next write, and the editor cannot be returned to its earlier
state — reopen the source for that.

### Where the block lands

The block inherits the graphics state the page content leaves active. A
transformation still in effect at the end of the stream moves it, a clipping
path can hide part or all of it, and a path left unfinished can extend what it
covers. All of these still report success.

**The removal itself is unaffected.** Glyph boxes and the region you queue are
compared in the same frame, so the text inside the region goes whatever the page
leaves active; it is the block marking the cleared area that moves. On a page
ending with `1 0 0 1 100 50 cm`, a region over a word deletes that word and
paints the block 100 points right and 50 up of it. For a document you did not
produce, render the written result and look at it; see [Verifying](#verifying).

### It removes text, and only the text the page draws itself

This is the limit to plan around. A region deletes the glyphs the page's own
content stream draws. It does not touch:

  * **images** — a photograph of a signature, a scan of a letter, a screenshot
    of a spreadsheet. The pixels stay in the file, at full resolution, and any
    tool that lists a page's images finds them.
  * **vector graphics** — lines, filled shapes, a chart drawn as paths.
  * **text drawn from a form XObject** rather than from the page, which is how
    some producers emit headers, stamps and repeated blocks. Such text survives
    and `PdfElixide.Document.text/1` still returns it.
  * **the `/ActualText` a tagged page declares** for the glyphs a region covers.
    The glyphs go and the replacement string is written back unchanged, so the
    region extracts as empty while the words are still in the content stream for
    anyone reading it directly. Accessible and archival documents carry these
    routinely.

For all of that, the block drawn on top is the same cosmetic overlay
`PdfElixide.Editor.mark_redactions/2` paints, with the same worthlessness as a
secret-keeping measure. A scanned document is the case to watch: its page text is
usually an invisible OCR layer, so a region over a name deletes the OCR text and
leaves the name legible in the image underneath.

There is no option that widens this and no count that reveals it —
`:glyphs_removed` reports the text that went and nothing about an image. When a
region covers anything but page text, redact the document at the source that
produced it.

### Which pages the pass processes

A page is processed when `PdfElixide.Editor.mark_redactions/2` has marked it, or
when it carries a region from `PdfElixide.Editor.add_redaction/3`. **A `/Redact`
annotation is not enough on its own.** Without one of the two the pass has
nothing to work on, removes nothing, and returns a `PdfElixide.RedactionReport`
of zeros rather than an error — which is why the report, and `:glyphs_removed` in
particular, is worth checking.

**Deleting a page does not take its mark or its regions back.**
`PdfElixide.Editor.delete_page/2` removes the page from the output and leaves
everything queued against it in place, so the pass still processes it. Its text
is counted in the report although the written document does not carry the page —
a `:glyphs_removed` above zero can come entirely from a deleted page — and a font
it uses can refuse the whole call, naming an index the document no longer has.
Mark and queue after the deletions, or reopen the source.

### Queuing your own regions

`PdfElixide.Editor.add_redaction/3` is how to redact an area the document does
not already annotate, and `PdfElixide.Editor.add_redaction/4` takes the colour of
the block drawn over it. A `PdfElixide.Geometry.Rect` from an extractor reporting
raw page space can be handed straight back:

```elixir
doc = PdfElixide.Document.open!("report.pdf")
[span | _] = PdfElixide.Document.spans!(doc, 0)
PdfElixide.Document.close(doc)

editor = PdfElixide.Editor.open!("report.pdf")
PdfElixide.Editor.add_redaction!(editor, 0, span.bbox)
PdfElixide.Editor.apply_redactions!(editor)
PdfElixide.Editor.save!(editor, "redacted.pdf")
PdfElixide.Editor.close(editor)
```

**Rectangles are in the page's raw, unrotated user space.** That is what
`PdfElixide.Document.chars/1`, `PdfElixide.Document.spans/1` and
`PdfElixide.Document.paths/1` report. On a rotated page it is *not* what
`PdfElixide.Document.words/1`, `PdfElixide.Document.text_lines/1`,
`PdfElixide.Document.tables/1` or `PdfElixide.Document.search/2` report — those
are mapped into the displayed frame, and a box taken from one of them has to be
mapped back before it is queued. See "Rotated pages and extracted geometry" in
`PdfElixide.Document`. Nothing detects the mismatch: the region is queued,
applied over whatever it lands on, and reported as a success, which is the one
way this feature can quietly redact the wrong area.

The queued rectangle reaches no writer but
`PdfElixide.Editor.apply_redactions/1`, and **cannot be withdrawn** once added:
`PdfElixide.Editor.unmark_redactions/2` does not remove it and nothing else does.
Reopen the source if you change your mind. One consequence is that the first
queued region ends incremental saving for that editor — the refusal it causes is
one of the ones nothing lifts; see [Saving edits](editing.md#saving-edits).

Queuing a region does, however, **mark the page** exactly as
`PdfElixide.Editor.mark_redactions/2` would. On a page that carries `/Redact`
annotations of its own, a write between the `PdfElixide.Editor.add_redaction!/3`
and the `PdfElixide.Editor.apply_redactions!/1` therefore paints *their*
rectangles and drops every
annotation on the page. On a page with none — the usual case for a region taken
from an extractor, as above — a write changes nothing.

Regions are cleared with a margin — `:edge_padding` points past each edge, or
2% of the region's height, whichever is larger — so that an anti-aliased sliver
of a glyph cannot survive at the boundary. Expect slightly more to go than the
rectangle strictly covers.

`PdfElixide.Editor.redaction_count/2` reports the page's `/Redact` annotations
plus its queued regions. **An annotation counts once however many
quadrilaterals it declares**, and a multi-quad annotation is treated as its
bounding rectangle — so the area covered is the box around the quads rather
than the quads themselves. That errs toward covering more, never less. An
annotation with no `/Rect` marks no area and is not counted.

### It discards other pending overlays on the page

A destructive pass **replaces** the content of every page it rewrites, rather
than appending to it. Anything else this editor had queued to be painted onto
such a page is dropped, silently and without an error:

  * a region from `PdfElixide.Editor.erase_region/3` or
    `PdfElixide.Editor.erase_regions/3` — the whiteout never appears, so
    whatever it was covering is visible in the output;
  * the appearances of `PdfElixide.Editor.flatten_annotations/1` — the
    annotations are removed from the page either way, so a flattened field's
    value is lost rather than baked in.

Only the pages the pass actually rewrote are affected, so on a document where
some pages redact and others do not, an erase can survive on one page and vanish
on the next.

This matters most for the images and vector graphics above: covering them with
an erase region is the obvious response to the limit, and it is exactly the
combination that does not survive. Do the two in separate editors — apply the
redactions, write, reopen what was written, and erase there, reusing the `span`
from the example above:

```elixir
editor = PdfElixide.Editor.open!("report.pdf")
PdfElixide.Editor.add_redaction!(editor, 0, span.bbox)
PdfElixide.Editor.apply_redactions!(editor)
bytes = PdfElixide.Editor.to_binary!(editor)
PdfElixide.Editor.close(editor)

written = PdfElixide.Document.from_binary!(bytes)
[photo | _] = PdfElixide.Document.images!(written, 0)
PdfElixide.Document.close(written)

covered = PdfElixide.Editor.from_binary!(bytes)
PdfElixide.Editor.erase_region!(covered, 0, photo.bbox)
PdfElixide.Editor.save!(covered, "clean.pdf")
PdfElixide.Editor.close(covered)
```

A `PdfElixide.Form.flatten/1` is the exception that does survive: it is
painted after the replacement rather than before it. So is the redaction block
itself, which the pass draws as part of the new content.

## Redacting a page removes every annotation on it

A page that is **actually redacted** is written **without any annotations at
all** — not only the `/Redact` ones. Links stop working, stamps and notes
disappear, and form-field widgets go with them, which for a filled form means
the values stop being visible and stop being editable.

Marking alone is not enough to trigger this, and the distinction matters when
annotations are what you are trying to remove. A page loses them when the write
has something to redact it with: a `/Redact` annotation of its own, or a region
from `PdfElixide.Editor.add_redaction/3` that the pass could apply — see
[Which pages the pass processes](#which-pages-the-pass-processes). A page that
was only marked, with neither, keeps every annotation. To drop a page's
annotations whatever it carries, reach for
`PdfElixide.Editor.flatten_annotations/2` instead.

**This unlinks them; it does not erase them.** The `/Annots` entry goes, so a
viewer stops showing the annotation and
`PdfElixide.Document.annotations/2` stops reporting it — but the annotation
object itself is still written, and a link's URI or a `/FileAttachment`'s bytes
stay readable to anything that walks the file. Redaction erases *page text*; for
anything carried by an annotation, rebuild the document from the pages you want.

### Keeping the annotations: flatten first

There is no way to keep some and drop others; the choice is per page. If the
annotations matter, flatten them first so their appearances survive as page
content. Which call to use, and whether it can share the editor, differ.

`PdfElixide.Editor.flatten_annotations/1` can share the editor. Its
appearances are painted *under* the redaction box, which is where they belong:

```elixir
"annotated.pdf"
|> PdfElixide.Editor.open!()
|> PdfElixide.Editor.flatten_annotations!()
|> PdfElixide.Editor.mark_redactions!(0)
|> PdfElixide.Editor.save!("marked.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

`PdfElixide.Form.flatten/1` cannot. A form flatten is painted *over* the
redaction box, so the field appearances cover the very area the box was meant to
hide, and it needs a write and a reopen in between:

```elixir
flattened = PdfElixide.Editor.open!("form.pdf")
PdfElixide.Form.flatten!(flattened)
bytes = PdfElixide.Editor.to_binary!(flattened)
PdfElixide.Editor.close(flattened)

bytes
|> PdfElixide.Editor.from_binary!()
|> PdfElixide.Editor.mark_redactions!(0)
|> PdfElixide.Editor.save!("marked.pdf")
|> PdfElixide.Editor.close()
#=> :ok
```

**Only a form flatten can take that detour.** `PdfElixide.Form.flatten/1`
removes the widgets it flattened and leaves every other annotation in place, so
the `/Redact` annotations are still there when the written file is reopened.
`PdfElixide.Editor.flatten_annotations/1` removes the page's annotations
outright — the `/Redact` ones included — so a document written by it has nothing
left for `PdfElixide.Editor.mark_redactions/2` to paint, and the second pass
would produce a file with no box at all.

Both recipes above only *mark* the page. **A destructive pass needs one more
step**, because `PdfElixide.Editor.flatten_annotations/1` does not survive
`PdfElixide.Editor.apply_redactions/1` on the same editor, where it does survive
a mark. The pass replaces the content of every page it rewrites, so the
flattened appearances are dropped from those pages along with every other
pending overlay: the annotations are still unlinked, but what they drew is gone
rather than baked in. Flatten in one editor, write it, and redact the reopened
result — see
[It discards other pending overlays on the page](#it-discards-other-pending-overlays-on-the-page).

`PdfElixide.Form.flatten/1` is the one spliced *after* the replacement, so its
appearances do survive a destructive pass — and land on top of the redaction
block, which is the same reason it needs the write-and-reopen detour above
whichever call draws the box.

## What is refused, and why

### Refused by apply_redactions/1,2

**A page whose glyph boundaries cannot be computed.** Simple single-byte fonts
are redacted, and so are horizontal Identity-H composite (Type 0) fonts, whose
two-byte codes are their own CIDs. What is refused is the rest: a font the
page's resources do not define, a vertical Identity-V font, and any composite
font using a predefined or custom CMap, whose code lengths cannot be
reconstructed. The call returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` and removes nothing from
that page. The alternative would be to guess where the glyphs are and clear what
it could, producing a page that looks redacted and is not. Nothing here can
widen that; it is the format's limit, not a setting. The error message says
"composite/Type0" for every one of these routes, an unresolvable font included,
so take it as "this page could not be measured" rather than as a diagnosis.

**A page whose text state a `q`/`Q` restores.** If a page selects a font, size,
text spacing or line leading inside a `q` … `Q` block and then draws text, or
moves to a new line, after the restore, the call returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` and removes nothing from any
page. Such text is measured with the state the restore discarded, so its glyph
boxes come out the wrong size and a region over it can match nothing — the pass
would report success having left the text in place, which is the one outcome
worth refusing a whole call for. A page that re-sets what the block changed
before drawing is measured correctly and is not refused, so this does not reject
the ordinary `q … BT /F1 10 Tf … ET Q` shape. Unlike the font refusal above this
one is checked **before any page is rewritten**, so the editor is left untouched
and can still be saved or marked.

**The font refusal is the one that is per page, and it does not undo the pages
before it.** Pages are processed in order, so a document whose page 4 is refused
for its fonts may reach the error with pages 0 to 3 already rewritten in the
editor. Writing it then produces a partly redacted file — which is worse than
either outcome, because it looks like the pass succeeded. Treat the error as
fatal to that editor: close it, reopen the source, and redact again once the
offending page is dealt with. An incremental save is refused after a failed pass
too, for the same reason.

**A second destructive pass on the same editor.** The call returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` the second time and
changes nothing. Each pass rebuilds every processed page from the *unredacted*
source rather than from the previous result, so a later pass with a smaller
`:edge_padding` would hand back text an earlier one removed — and report
success. Queue every region before applying, or reopen the source and start
again.

### Refused by sanitize/1,2

An `/Info` value stored as an indirect object, when sanitizing with
`:scrub_metadata`. `PdfElixide.Editor.sanitize/1` returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` and changes nothing.
Clearing `/Info` replaces the dictionary, but a value held in its own object
stays there and stays readable, so the call would report a scrub it did not
perform. Sanitize with `scrub_metadata: false` to strip JavaScript and
attachments anyway, or rewrite the document's metadata before sanitizing. Most
producers write `/Info` values inline, where this does not arise.

### Refused on the write afterwards

**An incremental save after a destructive pass.**
`PdfElixide.Editor.save/3` with `incremental: true` returns
`{:error, %PdfElixide.Error{reason: :unsupported}}`. An incremental update is
appended to a verbatim copy of the original file, so it would carry none of the
removal and leave the content readable while reporting success. Write a full
rewrite. A *mark* and a queued region are refused too, but the message names
them rather than the removal, and `PdfElixide.Editor.unmark_redactions/2` lifts
the mark's refusal where nothing lifts this one.

**A write with `garbage_collect: false` after a sanitization.**
`PdfElixide.Editor.save/3` and `PdfElixide.Editor.to_binary/2` both return
`{:error, %PdfElixide.Error{reason: :unsupported}}`. What
`PdfElixide.Editor.sanitize/1` removes, it removes by unlinking the object and
leaving the write to drop it; with collection off, every object the source holds
is copied out instead, and a document that stored its `/Info`, JavaScript or
file specifications in a compressed object stream gets that stream copied out
whole — scrubbed values and all — while the call reports success and
`PdfElixide.Editor.metadata/1` answers `nil`. Write with garbage collection, the
default. This refusal is specific to sanitizing: `garbage_collect: false` after
`PdfElixide.Editor.apply_redactions/1` is allowed, because the cleared page
content is dropped by object id whatever the setting.

### Refused by both, on different terms

A page storing its content streams in an indirect object that is not itself a
stream — an array, most often. Both calls return
`{:error, %PdfElixide.Error{reason: :unsupported}}`.

`PdfElixide.Editor.add_redaction/3` refuses such a page whether or not it
carries annotations, because a queued region reaches only
`PdfElixide.Editor.apply_redactions/1`, which rebuilds the page from its
content streams and cannot read any indirect `/Contents` that is not a stream.
The refusal is at the queue because a region cannot be withdrawn once added —
accepting one that could never be applied would leave reopening the source as the
only way forward.

`PdfElixide.Editor.mark_redactions/2` refuses the same shape, but only when the
page **also** carries redaction annotations. With none there is no overlay to
splice and nothing for a later pass to apply, so marking is harmless; with them
the page reaches both — the overlay cannot be appended without losing the page's
content, and the pass cannot read the content in the first place.
`PdfElixide.Editor.mark_redactions/1` refuses the whole document rather than
mark part of it.

Such a page can still be rotated, moved, deleted and saved.

## Sanitizing

`PdfElixide.Editor.sanitize/1` is the document-level half: it clears `/Info`
and XMP metadata, document JavaScript, and the embedded-file name tree, and
returns a `PdfElixide.SanitizeReport`. It touches **no page content** — text,
images and annotations are left exactly as they are. Like a destructive
redaction it is immediate, cannot be undone, and refuses an incremental save
afterwards.

It is a separate call, not a part of the other one:
`PdfElixide.Editor.apply_redactions/1` scrubs **no** document metadata,
JavaScript or embedded files, and a document that must give up both needs both.

```elixir
editor = PdfElixide.Editor.open!("report.pdf")
region = %PdfElixide.Geometry.Rect{x: 72.0, y: 700.0, width: 228.0, height: 20.0}

editor
|> PdfElixide.Editor.add_redaction!(0, region)
|> PdfElixide.Editor.apply_redactions!()

PdfElixide.Editor.sanitize!(editor)
PdfElixide.Editor.save!(editor, "clean.pdf")
PdfElixide.Editor.close(editor)
```

`:remove_embedded_files` also discards any file queued with
`PdfElixide.Editor.embed_file/4` that has not been written yet, so sanitizing
after attaching one drops it rather than writing it into the "clean" output, and
`PdfElixide.Editor.embedded_files/1` reports the empty list afterwards. The other
order works: attaching *after* a sanitize that emptied the name tree writes the
new file and none of what was removed. See
[Attachments](editing.md#attachments).

It removes the name tree and **not** a `/FileAttachment` annotation, which keeps
its own file specification and so keeps its bytes reachable. Nothing here
removes them: redacting the page and
`PdfElixide.Editor.flatten_annotations/1` both only unlink the annotation from
the page — see
[Redacting a page removes every annotation on it](#redacting-a-page-removes-every-annotation-on-it)
— so the attachment stops being offered by a viewer and stays in the file. A
document that must not carry it has to be rebuilt from the pages you want.

Use it on its own when a document's visible content is fine and only what is
attached to it is not, and alongside `PdfElixide.Editor.apply_redactions/1`
whenever both halves matter — neither call does the other's work.

## Verifying

`PdfElixide.Document.text/1` on the reopened output is the check to reach for
first, as in the example at the top. It decodes the content streams, so it reads
the text whatever filter the stream carries.

**A byte scan of the written file is not a substitute for it.** A page the pass
rewrote is written with its new stream uncompressed, so a scan does find text
there — but every page the pass did not reach keeps the filter it arrived with,
and most PDFs store content `/FlateDecode`-compressed. A `:nomatch` therefore
cannot tell a redaction that worked from a page that was never marked — the
failure a report of zeros exists to signal. Run it only on output whose streams
are uncompressed, and only as a second check:

```elixir
bytes = PdfElixide.Editor.to_binary!(editor, compress: false)
:binary.match(bytes, "Secret")
#=> :nomatch
```

Neither check settles a document you did not produce: text can be present as an
image — which a destructive pass does not remove at all — and
`PdfElixide.Document.rects/2` reports where a box was placed rather than what it
covers. `PdfElixide.Document.images/1` on the reopened output is the check that
matches that limit: an image still listed there is an image still in the file,
whatever is painted over it. Render the written result and look at it — see the
[Rendering](rendering.md) guide — and treat a report whose `:glyphs_removed` is
zero as a redaction that did not happen. The converse does not hold: a count
above zero says the pass removed text from *some* processed page, which on an
editor that has deleted pages need not be a page the output carries.
