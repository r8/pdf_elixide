defmodule PdfElixide.StructuredTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.StructuredPage
  alias PdfElixide.Document.StructuredPage.Region
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @structured_pdf Path.join(@fixtures, "structured.pdf")
  @sample_pdf Path.join(@fixtures, "sample.pdf")
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")

  # Pages of @structured_pdf.
  @columns 0
  @tagged 1
  @sparse 2

  # Page of @extraction_pdf carrying an /Artifact running header.
  @artifacts 1

  @left_lines ~w(one two three four five six) |> Enum.map(&"Left column line #{&1}")
  @right_lines ~w(one two three four five six) |> Enum.map(&"Right column line #{&1}")

  defp open(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp kinds_and_columns(%StructuredPage{regions: regions}) do
    Enum.map(regions, &{&1.kind, &1.column})
  end

  defp region(%StructuredPage{regions: regions}, kind, column \\ nil) do
    Enum.find(regions, &(&1.kind == kind and &1.column == column))
  end

  defp union([first | rest]) do
    Enum.reduce(rest, first, fn %Rect{} = r, %Rect{} = acc ->
      x0 = min(acc.x, r.x)
      y0 = min(acc.y, r.y)
      x1 = max(acc.x + acc.width, r.x + r.width)
      y1 = max(acc.y + acc.height, r.y + r.height)
      %Rect{x: x0, y: y0, width: x1 - x0, height: y1 - y0}
    end)
  end

  defp assert_rect_equal(%Rect{} = a, %Rect{} = b) do
    for key <- [:x, :y, :width, :height] do
      assert_in_delta Map.fetch!(a, key), Map.fetch!(b, key), 0.01
    end
  end

  describe "structured/2 on an untagged two-column page" do
    setup do: %{page: Document.structured!(open(@structured_pdf), @columns)}

    test "groups the body by column and marks the artifact chrome", %{page: page} do
      assert kinds_and_columns(page) == [
               {:header, nil},
               {:body, 0},
               {:body, 1},
               {:marginal_label, 0},
               {:marginal_label, 1},
               {:footer, nil},
               {:page_number, nil}
             ]

      assert region(page, :header).text == "Running header"
      assert region(page, :footer).text == "Running footer"
      assert region(page, :page_number).text == "1"
    end

    test "each column region reads its lines top to bottom", %{page: page} do
      assert region(page, :body, 0).text == Enum.join(@left_lines, " ")
      assert region(page, :body, 1).text == Enum.join(@right_lines, " ")
      assert Enum.map(region(page, :body, 0).spans, & &1.text) == @left_lines
    end

    test "a short standalone numeral is a marginal label", %{page: page} do
      assert region(page, :marginal_label, 0).text == "12"
      assert region(page, :marginal_label, 1).text == "7"
    end

    test "a region's box is the union of its spans' boxes", %{page: page} do
      for %Region{bbox: bbox, spans: spans} <- page.regions do
        assert_rect_equal(bbox, union(Enum.map(spans, & &1.bbox)))
      end
    end

    test "every span belongs to exactly one region and carries the page", %{page: page} do
      spans = Enum.flat_map(page.regions, & &1.spans)

      assert Enum.all?(spans, &match?(%Span{page: @columns}, &1))
      assert Enum.sort(spans) == Enum.sort(Document.spans!(open(@structured_pdf), @columns))
    end

    test "column_mode: :single never splits", %{page: _} do
      page = Document.structured!(open(@structured_pdf), @columns, column_mode: :single)

      assert Enum.map(page.regions, & &1.kind) ==
               [:header, :body, :marginal_label, :footer, :page_number]

      assert Enum.all?(page.regions, &is_nil(&1.column))
      assert region(page, :body).text =~ ~r/^Left column line one Right column line one /
      assert region(page, :marginal_label).text == "12 7"
    end
  end

  describe "structured/2 on a tagged page" do
    setup do: %{page: Document.structured!(open(@structured_pdf), @tagged)}

    test "a /Lbl element is a marginal label and the section is shared", %{page: page} do
      assert Enum.map(page.regions, &{&1.kind, &1.text}) == [
               {:body, "Chapter One"},
               {:marginal_label, "1."},
               {:body, "Body of the chapter"}
             ]

      assert [section] = page.regions |> Enum.map(& &1.section) |> Enum.uniq()
      assert is_integer(section)
    end

    test "an untagged page reports no section" do
      page = Document.structured!(open(@structured_pdf), @columns)
      assert Enum.all?(page.regions, &is_nil(&1.section))
    end
  end

  describe "the page struct" do
    test "carries the index and the MediaBox corner" do
      assert %StructuredPage{page: 0, width: 612.0, height: 792.0} =
               Document.structured!(open(@structured_pdf), @columns)
    end

    test "an /Artifact header on another fixture is a header" do
      page = Document.structured!(open(@extraction_pdf), @artifacts)

      assert [{:header, "Running header artifact"}, {:body, _}] =
               Enum.map(page.regions, &{&1.kind, &1.text})
    end

    test "an encrypted document opened without its password has no regions" do
      assert {:ok, %StructuredPage{regions: []}} =
               Document.structured(open(@encrypted_pdf), 0)
    end
  end

  describe "structured/1" do
    test "returns one page struct per page in order" do
      doc = open(@sample_pdf)

      assert [%StructuredPage{page: 0}, %StructuredPage{page: 1}, %StructuredPage{page: 2}] =
               pages = Document.structured!(doc)

      assert Enum.map(pages, fn p -> Enum.map(p.regions, &{&1.kind, &1.text}) end) == [
               [body: "Page One"],
               [body: "Page Two"],
               [body: "Page Three"]
             ]

      assert {:ok, ^pages} = Document.structured(doc)
      assert Document.structured!(doc, []) == pages
    end
  end

  describe "Page.structured/2" do
    test "equals the document call at the same index" do
      doc = open(@structured_pdf)
      page = Enum.at(doc, @sparse)

      assert Page.structured!(page, column_mode: :two) ==
               Document.structured!(doc, @sparse, column_mode: :two)

      assert Page.structured(page) == Document.structured(doc, @sparse)
    end
  end

  describe "errors" do
    test "an index past the last page is :out_of_range" do
      doc = open(@structured_pdf)

      assert {:error, %Error{reason: :out_of_range}} = Document.structured(doc, 99)
      assert_raise Error, fn -> Document.structured!(doc, 99) end
    end

    test "a negative index is a caller bug" do
      doc = open(@structured_pdf)
      assert_raise FunctionClauseError, fn -> Document.structured(doc, -1) end
    end

    test "a closed document is :closed" do
      doc = Document.open!(@structured_pdf)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.structured(doc, 0)
      assert {:error, %Error{reason: :closed}} = Document.structured(doc)
      assert {:error, %Error{reason: :closed}} = Page.structured(Enum.at(doc, 0))
    end
  end

  describe "inspect/1" do
    test "summarises the page and the region" do
      page = Document.structured!(open(@structured_pdf), @columns)

      assert inspect(page) == "#PdfElixide.Document.StructuredPage<p0 612.0x792.0 7 regions>"

      assert inspect(region(page, :header)) ==
               ~s(#PdfElixide.Document.StructuredPage.Region<:header "Running header" @ p0>)

      assert inspect(region(page, :marginal_label, 1)) ==
               ~s(#PdfElixide.Document.StructuredPage.Region<:marginal_label/1 "7" @ p0>)
    end
  end
end
