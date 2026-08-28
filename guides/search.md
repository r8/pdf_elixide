# Search

`PdfElixide.Document.search/2` finds every non-overlapping occurrence of a
pattern in a document's text and reports where each one sits on the page, as
`PdfElixide.Document.SearchMatch` structs.

```elixir
alias PdfElixide.Document

doc = Document.open!("path/to/file.pdf")

# The whole document, in page order.
Document.search!(doc, "Figure 3")
#=> [%PdfElixide.Document.SearchMatch{page: 4, text: "Figure 3", bbox: %Rect{…}, …}]

# One page. `PdfElixide.Document.Page.search/3` is the same call from a page handle.
Document.search!(doc, "Figure 3", 4)
```

The examples below reuse this `doc`; close it after the last search.

Unlike extracting a page and scanning it in Elixir, searching builds a compact
per-page index and reuses it. Each match includes the boxes needed to locate it.

## Literal text and regular expressions

**The pattern is literal by default.** `Document.search(doc, "Fig. 3 (a)")` looks
for exactly that text; the `.` is a period and the parentheses are parentheses.

Pass `literal: false` to use a regular expression:

```elixir
Document.search!(doc, ~S"Figure \d+", literal: false)
```

Under `literal: false`, patterns use the [Rust `regex` crate][regex] rather than
PCRE. The important differences are:

  * There are **no backreferences and no lookaround** — `(?=…)`, `(?<=…)` and
    `\1` do not compile. In exchange, matching avoids catastrophic backtracking
    and has worst-case `O(m × n)` time for pattern size `m` and text size `n`.
    Very large patterns or pages can still take time.
  * Character classes, alternation, repetition, named groups, the inline flags
    `(?i)` `(?m)` `(?s)` `(?x)` and Unicode properties like `\p{Greek}` all work
    as usual.

A pattern that does not parse comes back as
`%PdfElixide.Error{reason: :invalid_pattern}` — and `search!/2` raises it, the
same split `Regex.compile/1` and `Regex.compile!/1` make. It is only reachable
under `literal: false`, since the default path escapes the pattern first.

### `:whole_word` and alternation

`whole_word: true` requires a word boundary at each end of the match, so `"cat"`
finds *cat* but not *category*.

The option wraps the complete pattern rather than each alternative. With
`literal: false`, `"cat|dog"` becomes `\bcat|dog\b`: *cat* must start at a word
boundary, while *dog* must end at one. Add explicit boundaries when combining
the option with alternation:

```elixir
Document.search!(doc, ~S"\b(?:cat|dog)\b", literal: false)
```

With the default `literal: true` the pattern is escaped before wrapping, so there
are no alternatives to misbind and the option means what it says.

## What a match covers

`:bbox` and `:span_boxes` locate a match on the page — but they are coarser than
the matched text, in two ways that matter if you are drawing on top of them.

**They cover whole runs of text.** A PDF stores text in runs, and a match reports
the box of every run it touches rather than the extents of the matched
characters. Searching `"Widgets"` in a line reading *Introduction to Widgets*
gives back the box of the entire line. The search API provides no narrower box.

**`:bbox` is the union of `:span_boxes`.** For a match inside one run they are
the same rectangle. For a match crossing two runs — including two on different
lines — the union is a single rectangle covering everything between them,
including whatever sits in the gap. Draw from `:span_boxes`, which has one entry
per run, and keep `:bbox` for coarse questions like "which part of the page".

**A match can cross a line.** Runs are concatenated before matching, with a space
inserted after a run only when that run does not already end in one. No newline
is inserted, so a phrase split across two lines still matches as one. The page
behaves as a single line: `^` and `$` anchor to the page rather than to a line,
and `.` never stops at a line end.

A match consisting entirely of inserted spaces — possible with a pattern such
as `~S"\s+"` — belongs to no run and returns empty `:span_boxes` and a zero-sized
`:bbox`.

The boxes use the same coordinate spaces as the rest of the library. A rotated
page has two: a search match is reported in the
*displayed* frame, alongside `words/1` and `text_lines/1`, where `spans/1` and
`chars/1` for the same text stay in raw page space. The "Rotated pages and
extracted geometry" section of `PdfElixide.Document` has the full account.

## Searching one page

`search/3` takes a zero-based page index in place of the option list, and
`search/4` takes both:

```elixir
Document.search!(doc, "Figure 3", 4)
Document.search!(doc, "figure 3", 4, case_insensitive: true)

# Or from a page handle, which is the same call.
doc |> Document.page!(4) |> Document.Page.search!("Figure 3")
```

There is no `:page_range` option: these arities are how a single page is
reached, and they report a page index past the end of the document as
`%PdfElixide.Error{reason: :out_of_range}`.

For a range of pages, search each one — the index below makes the repeat cheap:

```elixir
Enum.flat_map(3..7, &Document.search!(doc, "Figure", &1))
```

## The search index

The first search on a page builds a small index of it — the page's text and the
boxes of its runs, without the font and glyph data a full extraction carries —
and stores it on the document handle. Every later search on that page, **whatever
the pattern**, reuses it. Each term still compiles its own pattern and scans the
cached text; what the cache avoids is extracting the PDF text and rebuilding its
position map for every term.

Nothing evicts pages from the index during the handle's lifetime. Searching a
thousand-page PDF end to end therefore retains a thousand pages of text in
native memory without creating VM collection pressure. A whole-document
`search/2` with `:max_results` stops at the page that reaches the limit and does
not index later pages. Pages indexed by earlier calls remain until explicitly
cleared.

Two calls control it:

  * `PdfElixide.Document.clear_search_index/1` drops the index and the memory it
    holds. The document stays usable and a later search rebuilds what it needs.
    `PdfElixide.Document.close/1` releases it too, along with everything else.
  * `PdfElixide.Document.prepare_search/1` builds it for every page up front.
    This does not make searching cheaper overall — it moves the cost off the
    first `search/2` and onto a call you choose, which is useful when that first
    search is on a latency path.

Searching from several processes is supported. If searches may overlap
`clear_search_index/1`, see the [Concurrency](concurrency.md) guide for the
waiting and memory-release guarantees.

```elixir
:ok = Document.close(doc)
```

[regex]: https://docs.rs/regex/1.12.3/regex/#syntax
