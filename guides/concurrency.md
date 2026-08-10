# Concurrency

A `%PdfElixide.Document{}` is safe to pass to another process, and its reads run
*concurrently*: every function that reads the document takes the native handle's
lock shared, so N workers extracting from one open document do not queue behind
each other. Only the struct travels between processes — the PDF stays where it
was loaded — so there is no reason to open the same file once per worker, nor to
keep a document inside the process that opened it.

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

Everything on a document reads through a shared lock except these three, which
take the handle *exclusively* — they wait for every in-flight call on that handle
and block new ones for their duration.

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

There is one **correctness** hazard, and it belongs to the underlying library
rather than to this binding.

On a tagged PDF that declares `/ActualText` both inside a page's content stream
and on a structure element covering the same marked content, the record of which
declaration wins is kept per *page index* on the shared document instead of per
call. Two extractions that touch the same page can therefore cross-contaminate,
and one of them returns the wrong replacement text for that page — text no error
accompanies.

Concurrency is only one way to trigger it: two calls in a row on one handle do it
too, which is why this is not a reason to stop sharing a document. Fanning the
work out **by page** avoids it entirely, since workers that never share a page
never collide. The shape to avoid is two whole-document extractions running on
one handle at once.

## Throughput is not linear

What the concurrency does *not* do is scale linearly. `pdf_oxide` serializes the
first, uncached read of each PDF object across threads and only lets
already-cached reads through in parallel, so a document being read for the first
time contends inside the library and runs close to fully parallel only
afterwards. Expect contention rather than a speedup proportional to workers.

## The other handles

`PdfElixide.Editor` is different in kind, because it mutates. Every call that
writes or changes the document takes the handle exclusively, so concurrent
*editing* of a single editor serializes instead of running in parallel. Give each
process its own editor if you need them to work at once.

Two editor calls are shared reads: `PdfElixide.Editor.page_count/1` and
`PdfElixide.Editor.modified?/1`, whose upstream counterparts genuinely only look.
They do not wait on each other — but a shared guard still waits behind an
exclusive one, so either will queue behind an in-flight save on the same handle.

`PdfElixide.Form.fields/1` inherits whichever source it is handed — a shared read
on a document, the editor's exclusive lock on an editor — so listing fields from
an editor serializes even though it only reads.

`PdfElixide.Form.put_values/2` is a convenience, not a batching optimization: it
takes the exclusive lock once per field plus once for the read it validates
against, exactly as the same number of `PdfElixide.Form.put_value/3` calls would.
`PdfElixide.Form.update_value/3` takes it twice, once to read and once to write,
so another process holding the same editor can write in between.

`PdfElixide.Document.Image`, `PdfElixide.Document.Font` and
`PdfElixide.Document.Table` handles are shareable the same way as a document, and
without the hazard above: each owns a value that is already materialized, with no
shared cache behind it, so concurrent `to_binary/2`, `data/1` and table rendering
really do run in parallel. Their `close/1` is the exclusive one, and waits for an
in-flight call exactly as a document's does.
