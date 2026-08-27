# Text extraction

A PDF page stores positioned glyphs, not semantic lines or paragraphs, so both
plain-text surfaces have structure to infer. `PdfElixide.Document.text/2`
preserves the visual rows it infers; `PdfElixide.Document.to_plain_text/2`
infers prose blocks and reading order. Their bang variants return a string
directly; the non-bang variants return `{:ok, string}` or
`{:error, %PdfElixide.Error{}}`. On an untagged prose page the two strings often
differ; on a simple or trustworthy-tagged page they may not.

```elixir
alias PdfElixide.Document

doc = Document.open!("path/to/file.pdf")

Document.text!(doc, 0)
#=> "Automating the construction of index pairs,\nessential ingredients of the\ntheory."

Document.to_plain_text!(doc, 0)
#=> "Automating the construction of in- dex pairs, essential ingredients of the theory."
```

The examples below reuse this `doc`; close it when you are done.

Everything here is about those two. The structured extractors — `chars/2`,
`words/2`, `text_lines/2`, `spans/2` — return glyphs and geometry rather than a
string, and `to_markdown/2` and `to_html/2` return markup; the last section
points at each.

## `text/2` — the page as laid out

`text/2` walks the page's glyph runs and assembles them row by row. It keeps its
inferred visual line breaks, can rejoin lowercase words split across lines by
hyphenation, and can restrict what it reads. The rejoining is conservative, not
a general-purpose dehyphenator.

Reach for it when:

  * the line structure carries meaning — an address block, a code listing, a
    form, a table of contents;
  * you want to extract part of a page, or drop a watermark layer or a spot ink
    (only this surface takes `:region`, `:exclude_regions`, `:exclude_layers`
    and `:exclude_inks`);
  * you are extracting a whole document and want a page that fails to be
    skipped rather than to fail the call (`:on_page_error`);
  * you want ligatures expanded (`:expand_ligatures`).

## `to_plain_text/2` — the page as prose

`to_plain_text/2` groups spans into blocks, orders the blocks — detecting
columns, not just sorting by height — and generally reflows prose paragraphs
onto one line, separating them with a blank line. Tables and some columnar
layouts retain internal line breaks.

Reach for it when you want paragraph text rather than page text: indexing,
chunking for retrieval, feeding a model, or diffing two versions of a document
whose line wrapping has changed.

One thing to know before you use it on typeset or OCR-backed scanned prose: **a
hyphen at a line break stays where it fell.** Where `text/2` rejoins `in-` and
`dex` into `index`, this returns `in- dex`. If hyphen-joined words matter more
than paragraph shape to you, that alone is a reason to prefer `text/2`.

Neither function performs OCR. An image-only scanned page normally returns an
empty string; supply an OCR text layer before using either extractor.

## A tagged PDF collapses the difference

When a document carries a readable structure tree and its producer has not
marked the tags suspect, `to_plain_text/2` reads the page in the order those
tags declare and returns **exactly** what `text/2` returns for it.

```elixir
tagged = Document.open!("tagged.pdf")

Document.to_plain_text!(tagged, 0) == Document.text!(tagged, 0)
#=> true
```

Two consequences worth keeping in mind. `:reading_order` and
`:include_form_fields` stop having an effect on such a document — the order is
the tags' and field values are inlined either way.

`PdfElixide.Document.has_structure_tree?/1` is only a hint here: it reports a
readable tree even when the producer marked its tags suspect, while extraction
correctly falls back to geometric order in that case. There is no public exact
predicate for the branch. If the distinction matters for a corpus, compare the
two outputs on representative pages rather than deciding from that predicate
alone.

## Which options each takes

The two surfaces overlap on `:extract_tables` and `:table_detection` and
nowhere else. Passing a key the other one owns raises `ArgumentError` naming it,
rather than being accepted and ignored.

| Option | `text/2` | `to_plain_text/2` |
|---|---|---|
| `:extract_tables` | yes | yes |
| `:table_detection` | yes | yes |
| `:region`, `:region_mode` | yes | — |
| `:exclude_regions`, `:exclude_regions_mode` | yes | — |
| `:exclude_layers`, `:exclude_inks` | yes | — |
| `:expand_ligatures` | yes | — |
| `:on_page_error` | whole document only | — |
| `:reading_order` | — | yes |
| `:include_form_fields` | — | yes (always on for `text/2`) |

On an untagged document, `:reading_order` has three values and two behaviours:
`:structure_tree` and `:column_aware` both run the column-detecting pass, and
`:top_to_bottom` sorts blocks by vertical position instead. On a single-column
page all three agree.

`t:PdfElixide.Document.text_opts/0` and
`t:PdfElixide.Document.plain_text_opts/0` document each key in full.

## Whole documents, and getting back to pages

Both have a whole-document arity, and they join pages differently:

```elixir
Document.text!(doc)            # pages separated by a form feed, "\f"
Document.to_plain_text!(doc)   # pages separated by "\n\n---\n\n"
```

Splitting `text/1` on the form feed recovers its pages, and always yields
exactly `page_count/1` parts, because a page that fails to extract still gets
its separator. The `---` boundary is not as safe: `to_plain_text/2` separates
paragraphs with a blank line, so a page whose own text has a `---` line between
two paragraphs emits the same bytes and splits into an extra part, shifting
every page after it. When the page a result came from has to be right,
enumerate pages instead of splitting.

Neither bounds memory: each builds the whole result before returning. Working a
page at a time does, and needs no extra API, since a document is enumerable over
its pages and `PdfElixide.Document.Page` offers both functions:

```elixir
Stream.map(doc, &PdfElixide.Document.Page.to_plain_text!/1)
```

That is also the shape to fan out across processes; the
[Concurrency](concurrency.md) guide explains why per-page is the right unit.

## When a page fails

`text/1` is the only whole-document text call that can tolerate one: under its
`:on_page_error` default a page that fails contributes an empty string and the
call still succeeds. `to_plain_text/1`, `to_markdown/1` and `to_html/1` all fail
the whole call instead.

In practice few damaged pages fail at all — an undecodable content stream, a
missing font, a scan with no text layer and a document that could not be
decrypted all extract as `""` rather than an error, on either surface. See the
"`:on_page_error` and partly extractable documents" section of
`t:PdfElixide.Document.text_opts/0` for what that option can and cannot catch.

## Tables inside a text result

With `:extract_tables` on — the default for both — a recognised table is
rendered from its detected cells. Both assemblers try to suppress flowing spans
that those cells already represent, so ordinary cell text appears once.

Duplication can still occur when a flowing span cannot be matched back to a
cell. A common example is a generated table whose independently positioned
cells were fused into one wide span: the result then contains the separated
cell rendering as well as the fused span. Trustworthy tagged extraction avoids
adding a second table rendering. The "Choosing an extractor for search and
matching" section of `PdfElixide.Document` explains this failure mode and when
to use `words/2` instead.

When the separate cell rendering is emitted, `to_plain_text/2` keeps its column
padding while `text/2` collapses the padding to single spaces.

## Beyond plain text

  * **Glyphs and geometry.** `chars/2`, `spans/2`, `words/2` and
    `text_lines/2` return structs with bounding boxes, fonts and colors. Use
    them to locate text on the page rather than to read it.
  * **Markup.** `to_markdown/2` represents detected headings, lists and tables;
    `to_html/2` returns an escaped fragment, optionally absolutely positioned.
    Both take a larger option set than either plain-text surface.
  * **Finding a known string.** `PdfElixide.Document.search/2` indexes each page
    once and returns match geometry — see the [Search](search.md) guide.
