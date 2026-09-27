defmodule PdfElixide.RunningRegionsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @running_pdf Path.join(@fixtures, "running_headers.pdf")
  @folios_pdf Path.join(@fixtures, "running_folios.pdf")
  @rotated_pdf Path.join(@fixtures, "running_rotated.pdf")
  @structured_pdf Path.join(@fixtures, "structured.pdf")
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  @sample_pdf Path.join(@fixtures, "sample.pdf")

  # Page of @running_pdf carrying `/Rotate 90`.
  @rotate_90 3

  defp open(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp texts(regions),
    do: Map.new(regions, fn {page, spans} -> {page, Enum.map(spans, & &1.text)} end)

  defp boxes(spans), do: Enum.map(spans, & &1.bbox)

  # The written overlay round-trips its corners through a decimal string.
  defp rounded(%Rect{x: x, y: y, width: width, height: height}),
    do: Enum.map([x, y, width, height], &Float.round(&1, 2))

  defp user_space_boxes(doc, index, spans) do
    page = Document.page!(doc, index)
    rotation = Page.rotation!(page)
    media_box = Page.media_box!(page)

    for span <- spans do
      if rotation == 180 or (rotation in [90, 270] and span.rotation != 0.0),
        do: Rect.to_user_space(span.bbox, rotation, media_box),
        else: span.bbox
    end
  end

  defp erase_all(doc, path) do
    editor =
      Enum.reduce(Document.running_regions!(doc), Editor.open!(path), fn {index, spans}, editor ->
        Editor.erase_regions!(editor, index, user_space_boxes(doc, index, spans))
      end)

    written = editor |> Editor.to_binary!() |> Document.from_binary!()
    Editor.close(editor)
    on_exit(fn -> Document.close(written) end)
    written
  end

  describe "running_regions/1,2 on an untagged document" do
    setup do: %{doc: open(@running_pdf)}

    test "finds the position-locked header and footer on every page", %{doc: doc} do
      assert texts(Document.running_regions!(doc)) ==
               Map.new(0..3, &{&1, ["Quarterly Report", "Confidential"]})
    end

    test "leaves body text, drifting margin text and page numbers alone", %{doc: doc} do
      found = doc |> Document.running_regions!() |> texts() |> Map.values() |> List.flatten()

      for text <- ["Check if applicable", "1", "Body text on page 1 of the report."] do
        refute text in found
      end

      # The body copy of the header shares its text but not its place.
      page = doc |> Document.spans!(0) |> Enum.map(& &1.text)
      assert Enum.count(page, &(&1 == "Quarterly Report")) == 2
      assert length(Document.running_regions!(doc)[0]) == 2
    end

    test ":threshold admits a line repeated on fewer pages", %{doc: doc} do
      # "Draft copy" repeats on two of the four pages.
      assert texts(Document.running_regions!(doc, threshold: 0.5)) == %{
               0 => ["Quarterly Report", "Draft copy", "Confidential"],
               1 => ["Quarterly Report", "Draft copy", "Confidential"],
               2 => ["Quarterly Report", "Confidential"],
               3 => ["Quarterly Report", "Confidential"]
             }
    end

    test ":area narrows to one margin", %{doc: doc} do
      assert texts(Document.running_regions!(doc, area: :header)) ==
               Map.new(0..3, &{&1, ["Quarterly Report"]})

      assert texts(Document.running_regions!(doc, area: :footer)) ==
               Map.new(0..3, &{&1, ["Confidential"]})
    end

    test "measures horizontal text on a 90-degree page before it is turned", %{doc: doc} do
      assert {:ok, 90} = doc |> Document.page!(@rotate_90) |> Page.rotation()

      regions = Document.running_regions!(doc)
      assert boxes(regions[@rotate_90]) == boxes(regions[0])
    end

    test "leaves no mask on the handle", %{doc: doc} do
      before = Document.text!(doc)
      Document.running_regions!(doc)
      assert Document.text!(doc) == before
    end
  end

  describe "running_regions/1,2 on a folio whose number changes" do
    setup do: %{doc: open(@folios_pdf)}

    test "reports it on every page but the first, whatever the threshold", %{doc: doc} do
      for threshold <- [0.8, 1.0] do
        assert texts(Document.running_regions!(doc, threshold: threshold)) ==
                 Map.new(1..3, &{&1, ["Page #{&1 + 1} of 4"]})
      end
    end

    test "a later page's box covers the first page's copy", %{doc: doc} do
      %{1 => spans} = Document.running_regions!(doc)
      boxes = boxes(spans)

      refute Document.text!(doc, 0, exclude_regions: boxes) =~ "Page 1 of 4"
      assert Document.text!(doc, 0, exclude_regions: boxes) =~ "Body text on page 1"
    end
  end

  describe "running_regions/1,2 on a tagged document" do
    test "answers from header and footer artifacts, without the page number" do
      doc = open(@structured_pdf)
      [page] = doc |> Document.running_regions!() |> texts() |> Map.values()

      assert length(page) == 2
      refute Enum.any?(page, &(&1 =~ ~r/^\d+$/))
    end

    test "finds an artifact header on the one page that has it" do
      doc = open(@extraction_pdf)
      assert %{1 => [_header]} = Document.running_regions!(doc)
    end
  end

  describe "running_regions/1,2 results" do
    test "a document without running content returns an empty map" do
      assert Document.running_regions(open(@sample_pdf)) == {:ok, %{}}
    end

    test "a page's regions exclude its running text from text/3" do
      doc = open(@running_pdf)
      regions = Document.running_regions!(doc)

      text = Document.text!(doc, 0, exclude_regions: boxes(regions[0]))

      refute text =~ "Confidential"
      assert length(String.split(text, "Quarterly Report")) == 2
      assert text =~ "Body text on page 1"
    end

    test "Editor.erase_regions/3 paints over the same boxes on a 90-degree page" do
      doc = open(@running_pdf)
      regions = Document.running_regions!(doc)
      written = erase_all(doc, @running_pdf)

      for page <- [0, @rotate_90] do
        painted = for path <- Document.rects!(written, page), do: rounded(path.bbox)
        assert painted == Enum.map(regions[page], &rounded(&1.bbox))
      end
    end
  end

  describe "running_regions/1,2 on a 180-degree page" do
    setup do: %{doc: open(@rotated_pdf)}

    test "measures the margins as displayed", %{doc: doc} do
      assert {:ok, 180} = doc |> Document.page!(0) |> Page.rotation()

      assert texts(Document.running_regions!(doc, area: :header)) ==
               Map.new(0..2, &{&1, ["Internal use"]})

      assert texts(Document.running_regions!(doc, area: :footer)) ==
               Map.new(0..2, &{&1, ["Annual Summary"]})
    end

    test "reports boxes in the displayed frame", %{doc: doc} do
      media_box = doc |> Document.page!(0) |> Page.media_box!()

      for span <- Document.running_regions!(doc)[0] do
        [raw] = for s <- Document.spans!(doc, 0), s.text == span.text, do: s.bbox

        refute rounded(span.bbox) == rounded(raw)
        assert rounded(Rect.to_user_space(span.bbox, 180, media_box)) == rounded(raw)
      end
    end

    test "the boxes exclude the running text from text/3", %{doc: doc} do
      regions = Document.running_regions!(doc)
      text = Document.text!(doc, 0, exclude_regions: boxes(regions[0]))

      refute text =~ "Internal use"
      refute text =~ "Annual Summary"
      assert text =~ "Body text on page 1"
    end

    test "the erase recipe paints over the raw boxes", %{doc: doc} do
      written = erase_all(doc, @rotated_pdf)

      for page <- 0..2 do
        raw =
          for span <- Document.spans!(doc, page),
              span.text in ["Internal use", "Annual Summary"],
              do: rounded(span.bbox)

        painted = for path <- Document.rects!(written, page), do: rounded(path.bbox)
        assert Enum.sort(painted) == Enum.sort(raw)
      end
    end
  end

  describe "running_regions/1,2 errors" do
    test "a closed document is :closed" do
      doc = Document.open!(@running_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.running_regions(doc)
      assert_raise Error, fn -> Document.running_regions!(doc) end
    end

    test "raises for a threshold outside 0.0..1.0" do
      doc = open(@running_pdf)

      for threshold <- [1.5, -0.1] do
        assert_raise ArgumentError, ~r/:threshold/, fn ->
          Document.running_regions(doc, threshold: threshold)
        end
      end
    end

    test "raises for a bad value or an unknown key" do
      doc = open(@running_pdf)

      for {opts, key} <- [
            {[area: :sides], ~r/:area/},
            {[threshold: "high"], ~r/:threshold/},
            {[areas: :header], ~r/:areas/}
          ] do
        assert_raise ArgumentError, key, fn -> Document.running_regions(doc, opts) end
      end
    end
  end
end
