defmodule PdfElixide.PerPageEquivalenceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  # Chosen for coverage of the extractors rather than of each other: `table.pdf`
  # is the only one with rules for `paths` and `lines`, `vector_shapes.pdf` the
  # only one drawing a rectangle, `annotations.pdf` and `markdown.pdf` the only
  # ones with annotations, `image.pdf` and `markdown.pdf` the only ones with
  # images.
  @fixtures ~w(sample.pdf extraction.pdf table.pdf annotations.pdf image.pdf fonts.pdf markdown.pdf vector_shapes.pdf)

  # Plain data — comparable with ==.
  @plain [:chars, :words, :text_lines, :spans, :paths, :rects, :lines, :annotations]

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

    assert Document.text!(doc) |> String.split("\f") |> Enum.join() == joined
  end
end
