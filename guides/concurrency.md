# Concurrency

A `%PdfElixide.Document{}` is safe to pass to another process. Native document
reads use shared access, so workers extracting from one open document do not
queue behind each other at the handle boundary. Values already cached on the
Elixir struct — the version, source path, and usually the page count — need no
native access. You normally do not need to open the same file once per worker or
keep a document inside the process that opened it. Use separate handles only to
isolate repeated extraction of the same page from the `/ActualText` behavior
below. Each handle loads and caches its own document.

```elixir
alias PdfElixide.Document

doc = Document.open!("path/to/file.pdf")

# One handle, one page per worker. This avoids the /ActualText hazard below.
pages =
  doc
  |> Task.async_stream(&PdfElixide.Document.Page.text!/1, ordered: true)
  |> Enum.map(fn {:ok, text} -> text end)

# Close once the workers are done. `close/1` waits for calls already in flight,
# but a read that starts afterwards gets an ordinary :closed error.
:ok = Document.close(doc)
```

## The exclusive calls

These document operations take the native handle *exclusively*. They wait for
in-flight native calls on that handle and block new ones for their duration.

  * `PdfElixide.Document.authenticate/2` waits for current readers and blocks new
    ones while it authenticates. Call it *before* fanning the document out to
    workers, not after.
  * `PdfElixide.Document.clear_search_index/1` waits for current searches before
    releasing the index, so the memory is gone when it returns. Its sibling
    `PdfElixide.Document.prepare_search/1` is an ordinary shared read.
  * `PdfElixide.Document.close/1` waits for every in-flight call to return rather
    than interrupting it — *immediately* means as soon as the handle is idle, not
    preemptively, and an extraction can hold its share of the lock for seconds.
    Afterwards every call that reaches the handle gets
    `{:error, %PdfElixide.Error{reason: :closed}}`, an ordinary error rather than
    a crash. The values cached on the struct keep answering, as above. A worker racing a close may therefore return this error. Close only
    once the workers are done.

`PdfElixide.Document.rasterize/2` runs one at a time **across the whole node**,
whatever document each caller uses. Other *reads* on the same handle are
unaffected; it holds that handle's shared guard for the whole render, so the
three exclusive calls above wait for it.
Queued callers wait in their own processes without occupying scheduler threads;
under contention, the wait can add a few seconds beyond the rendering time.
Calling `rasterize/2` from one process avoids this contention. The other
[Rendering](rendering.md) operations take ordinary shared reads and can run
concurrently by page.

## The `/ActualText` hazard

Some tagged PDFs declare competing `/ActualText` replacements for the same
marked content. Repeated extractions of the same page on one handle can then
return inconsistent replacement text without an accompanying error, whether
the calls overlap or run one after another.

Fanning work out **by page** avoids cross-contamination between workers that
never share a page. Avoid running two whole-document text-family extractions on
one handle at once when these PDFs are in scope.

## Throughput is not linear

Concurrency does *not* guarantee linear scaling. First-time extraction can
still contend while the document is being loaded and decoded, while repeated
work may benefit more from cached data. Benchmark representative PDFs rather
than expecting speedup proportional to the worker count.

A whole-document call such as `PdfElixide.Document.chars/1` runs on one
scheduler thread for the whole document, however many cores the node has.
Fanning out by page, as in the example above, is the only way to use more than
one. It pays off for the text-family extractors; for result-heavy ones such as
`PdfElixide.Document.paths/1`, copying each page's results between processes
can cost more than the parallel extraction saves, so measure before relying on
it.

## Captured diagnostics are not per-process

Diagnostics capture is global to the VM, and a captured record is forwarded by
whichever process next returns from a library call, so it carries no `Logger`
metadata identifying the work that produced it. See `PdfElixide.Logging`.

The process-wide structured warnings feed, `PdfElixide.Logging.structured_warnings/0`,
is global in the same way: an entry may have been recorded by a call on any
handle in the VM, and it becomes visible when the call that recorded it
returns, whether that call succeeded or failed.
`PdfElixide.Document.structured_warnings/1` is the per-handle half —
an ordinary shared read that lists only what reading that document recorded,
and does not empty the list, so several processes can read it.

## The other handles

`PdfElixide.Editor` is different in kind, because it mutates. Every call that
writes or changes the document takes the handle exclusively, so concurrent
*editing* of a single editor serializes instead of running in parallel. Give each
process its own editor if you need them to work at once.

The editor's shared reads are `PdfElixide.Editor.page_count/1`,
`PdfElixide.Editor.modified?/1`, `PdfElixide.Editor.rotation/2`,
`PdfElixide.Editor.media_box/2`, `PdfElixide.Editor.crop_box/2`,
`PdfElixide.Editor.metadata/1`, `PdfElixide.Editor.embedded_files/1`,
`PdfElixide.Editor.flatten_warnings/1`, `PdfElixide.Editor.marked_for_redaction?/2`
and `PdfElixide.Editor.closed?/1`. They do not wait on each other, but any of them
will queue behind an in-flight exclusive operation such as a save on the same
handle. For `flatten_warnings/1`, this ensures an in-flight save finishes before
the warnings are read.

`PdfElixide.Editor.redaction_count/2` is the one `PdfElixide.Editor` call that
reads without sharing: counting a page's redactions has to reach the annotations behind it,
which takes the handle exclusively. It serializes against every other call on
that editor even though it changes nothing.

`PdfElixide.Form.fields/1` and `PdfElixide.Form.export/3` inherit whichever
source they are handed — a shared read on a document, the editor's exclusive
lock on an editor — so reading fields from an editor serializes even though it
only reads.

`PdfElixide.Signature.list/1`, `PdfElixide.Signature.unsigned_fields/1`,
`PdfElixide.Signature.count/1` and `PdfElixide.Signature.dss/1` are shared reads
on *both* sources. Given an editor they read the document that editor was opened
from, which needs no exclusive lock, so listing signatures does not serialize the
way listing fields does.

Every other public signature operation takes a signature or security-store
struct, plain bytes, or scalar values rather than a handle, so it takes no handle
lock. Nothing else running on the source document can delay it, and closing the
document does not stop it answering. Certificates and timestamps reached from a
signature are plain values too, so their operations are lock-free for the same
reason.

`PdfElixide.Form.put_values/2` holds the editor exclusively for the whole batch,
so no other call on that editor runs between two of its writes.
`PdfElixide.Form.update_value/3` is a read followed by a write, each taking the
lock on its own, so another process holding the same editor can write in
between.

`PdfElixide.Document.Image`, `PdfElixide.Document.Font` and
`PdfElixide.Document.Table` handles are shareable the same way as a document, and
without the `/ActualText` hazard above. Concurrent `to_binary/2`, `data/1` and
table rendering calls can run alongside each other. Their `close/1` is the
exclusive operation and waits for in-flight calls in the same way as a
document's `close/1`.
