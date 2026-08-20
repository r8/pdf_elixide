# Concurrency

A `%PdfElixide.Document{}` is safe to pass to another process. Native document
reads use shared access, so workers extracting from one open document do not
queue behind each other at the handle boundary. Values already cached on the
Elixir struct — the version, source path, and usually the page count — need no
native access. There is no reason to open the same file once per worker or keep
a document inside the process that opened it.

```elixir
alias PdfElixide.Document

doc = Document.open!("path/to/file.pdf")

# One handle, one page per worker. Fanning out *by page* is the shape to prefer;
# the /ActualText hazard below says why.
pages =
  0..(Document.page_count!(doc) - 1)
  |> Task.async_stream(&Document.text!(doc, &1), ordered: true)
  |> Enum.map(fn {:ok, text} -> text end)

# Close once the workers are done. `close/1` waits for calls already in flight,
# but a read that starts afterwards gets an ordinary :closed error.
:ok = Document.close(doc)
```

## The exclusive calls

Three document operations take the native handle *exclusively*. They wait for
in-flight native calls on that handle and block new ones for their duration.

  * `PdfElixide.Document.authenticate/2` is exclusive because a first successful
    authentication replaces the document underneath, which a concurrent read must
    not be halfway through. Authenticate *before* fanning the document out to
    workers, not after.
  * `PdfElixide.Document.clear_search_index/1` is exclusive because a search
    running beside it would put its page back into the index moments after the
    release returned. Waiting for the searches to finish is what lets it promise
    the memory is gone. Its sibling `PdfElixide.Document.prepare_search/1` is an
    ordinary shared read.
  * `PdfElixide.Document.close/1` waits for every in-flight call to return rather
    than interrupting it — *immediately* means as soon as the handle is idle, not
    preemptively, and an extraction can hold its share of the lock for seconds.
    Afterwards every reader gets
    `{:error, %PdfElixide.Error{reason: :closed}}`, an ordinary error rather than
    a crash, so a worker racing a close is safe but may come back empty-handed.
    Close only once the workers are done.

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

## The other handles

`PdfElixide.Editor` is different in kind, because it mutates. Every call that
writes or changes the document takes the handle exclusively, so concurrent
*editing* of a single editor serializes instead of running in parallel. Give each
process its own editor if you need them to work at once.

Three editor calls are shared reads: `PdfElixide.Editor.page_count/1`,
`PdfElixide.Editor.modified?/1` and `PdfElixide.Editor.flatten_warnings/1`. They
do not wait on each other, but any of them will queue behind an in-flight
exclusive operation such as a save on the same handle — which is what you want
for the last one, since a save is what produces the warnings it reports.

`PdfElixide.Form.fields/1` inherits whichever source it is handed — a shared read
on a document, the editor's exclusive lock on an editor — so listing fields from
an editor serializes even though it only reads.

`PdfElixide.Signature.list/1` is a shared read on *both* sources. Given an editor
it reads the document that editor was opened from, which needs no exclusive lock,
so listing signatures does not serialize the way listing fields does.

`PdfElixide.Form.put_values/2` validates values together but does not make their
writes atomic. `PdfElixide.Form.update_value/3` is likewise a read followed by a
write, so another process holding the same editor can write in between.

`PdfElixide.Document.Image`, `PdfElixide.Document.Font` and
`PdfElixide.Document.Table` handles are shareable the same way as a document, and
without the `/ActualText` hazard above. Concurrent `to_binary/2`, `data/1` and
table rendering calls can run alongside each other. Their `close/1` is the
exclusive operation and waits for an in-flight call exactly as a document's
does.
