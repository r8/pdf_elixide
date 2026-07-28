defmodule PdfElixide.PerPageEquivalenceTest do
  @moduledoc """
  The per-page recipe the docs recommend, pinned against the whole-document call.

  The "Whole-document extraction and memory" section of `PdfElixide.Document`
  tells callers that `f(doc)` builds every page's results at once and that
  folding `PdfElixide.Document.Page.f/1` over `pages/1` is the bounded-memory
  way to ask for the same thing. That advice is only safe while the two really
  do agree, and nothing else in the suite compares them: `document_test.exs`
  exercises each arity against fixture content, so both could drift the same way
  and stay green.

  What could break the equivalence is a change to how a whole-document NIF
  *loops* — a sort, a dedup across pages, an added tolerance for a failed page,
  a different page order — none of which the per-page arity would see. Each of
  those is a legitimate thing to want; the point here is that it must not happen
  silently, because the moduledoc would then be recommending something that
  returns different data.

  Three functions deliberately do **not** hold, and `text/1` is asserted not to
  below rather than left out: it joins pages with a form feed and applies
  `:on_page_error`. `to_markdown/1` (a `---` break) and `to_html/1` (a
  `<div class="page">` wrapper) differ the same way, and the moduledoc says so.

  `fonts/1`, `images/1` and `tables/1` return structs carrying a native handle,
  and two extractions never mint the same one, so those compare with `:ref`
  dropped — the same reasoning `document_test.exs` gives for comparing a
  table's `:rows`.

  The `@fixtures` list is checked for vacuity at the end: an extractor that
  found nothing anywhere would pass every equivalence assertion trivially, so
  each one must produce a non-empty result on at least one fixture.
  """
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  # Chosen for coverage of the extractors rather than of each other: `table.pdf`
  # is the only one with rules for `paths`, `annotations.pdf` and `markdown.pdf`
  # the only ones with annotations, `image.pdf` and `markdown.pdf` the only ones
  # with images.
  @fixtures ~w(sample.pdf extraction.pdf table.pdf annotations.pdf image.pdf fonts.pdf markdown.pdf)

  # Plain data — comparable with ==.
  @plain [:chars, :words, :text_lines, :spans, :paths, :annotations]

  # Each returned struct carries a handle; compare with :ref dropped.
  @handled [:fonts, :images, :tables]

  defp open!(name), do: Document.open!(Path.join(@fixtures_dir, name))

  defp whole(doc, extractor), do: apply(Document, :"#{extractor}!", [doc])

  defp per_page(doc, extractor) do
    Enum.flat_map(doc, &apply(Page, :"#{extractor}!", [&1]))
  end

  defp strip_refs(items), do: Enum.map(items, &Map.delete(&1, :ref))

  for extractor <- @plain do
    test "#{extractor}/1 equals its per-page concatenation" do
      found =
        for fixture <- @fixtures do
          doc = open!(fixture)
          whole = whole(doc, unquote(extractor))

          assert whole == per_page(doc, unquote(extractor)),
                 "#{unquote(extractor)}/1 and Page.#{unquote(extractor)}/1 disagree on #{fixture}"

          length(whole)
        end

      assert Enum.sum(found) > 0, "no fixture exercises #{unquote(extractor)}/1"
    end
  end

  for extractor <- @handled do
    test "#{extractor}/1 equals its per-page concatenation, handles aside" do
      found =
        for fixture <- @fixtures do
          doc = open!(fixture)
          whole = whole(doc, unquote(extractor))

          assert strip_refs(whole) == strip_refs(per_page(doc, unquote(extractor))),
                 "#{unquote(extractor)}/1 and Page.#{unquote(extractor)}/1 disagree on #{fixture}"

          length(whole)
        end

      assert Enum.sum(found) > 0, "no fixture exercises #{unquote(extractor)}/1"
    end
  end

  test "the handled extractors really do carry a distinct handle per extraction" do
    # Otherwise `strip_refs/1` above would be dropping a field that never
    # differed, and the tests using it would silently be plain `==` after all.
    doc = open!("image.pdf")

    assert [%{ref: first}] = Document.images!(doc)
    assert [%{ref: second}] = Document.images!(doc)
    refute first == second
  end

  test "text/1 is not its per-page concatenation — it adds page separators" do
    doc = open!("sample.pdf")

    joined = Enum.map_join(doc, &Page.text!/1)

    refute Document.text!(doc) == joined
    assert Document.text!(doc) =~ "\f"
    refute joined =~ "\f"

    # The separator is the whole of the difference on a document whose pages all
    # extract, which is what makes `String.split(text, "\f")` the documented way
    # back to per-page text.
    assert Document.text!(doc) |> String.split("\f") |> Enum.join() == joined
  end
end
