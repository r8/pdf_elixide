defmodule PdfElixide.ExtractionOptionsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  @markdown_pdf Path.join(@fixtures, "markdown.pdf")
  @structured_pdf Path.join(@fixtures, "structured.pdf")

  # Page indices within @extraction_pdf.
  @columns 0
  @artifacts 1
  @markup 2
  @ruleless 3

  defp open(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp texts(items), do: Enum.map(items, & &1.text)

  describe "text/3" do
    setup do: %{doc: open(@extraction_pdf), table_doc: open(@table_pdf)}

    test ":extract_tables false drops the inline table rendering", %{table_doc: doc} do
      refute Document.text!(doc, 0, extract_tables: false) == Document.text!(doc, 0)
    end

    test ":expand_ligatures splits U+FB01 into its component letters", %{doc: doc} do
      assert Document.text!(doc, @markup) =~ "coﬁn"
      refute Document.text!(doc, @markup) =~ "cofin"

      assert Document.text!(doc, @markup, expand_ligatures: true) =~ "cofin"
      refute Document.text!(doc, @markup, expand_ligatures: true) =~ "coﬁn"
    end

    test ":region keeps only the text overlapping it", %{doc: doc} do
      [first | _] = Document.text_lines!(doc, @ruleless)
      text = Document.text!(doc, @ruleless, region: first.bbox)

      assert text =~ "Region"
      refute text =~ "North"
    end

    test ":region filters whole spans, not individual glyphs", %{doc: doc} do
      # Upstream applies the region to the span list before assembling text, so
      # a region covering part of a span keeps all of it. Here the whole first
      # row is one span even though it is three text-matrix runs.
      [first | _] = Document.text_lines!(doc, @ruleless)

      assert Document.text!(doc, @ruleless, region: first.bbox) == "RegionUnitsTotal"

      assert Enum.map_join(Document.chars!(doc, @ruleless, region: first.bbox), & &1.text) ==
               "Region"
    end

    test ":exclude_regions drops the text overlapping them", %{doc: doc} do
      [first | _] = Document.text_lines!(doc, @ruleless)
      text = Document.text!(doc, @ruleless, exclude_regions: [first.bbox])

      refute text =~ "Region"
      assert text =~ "North"
    end

    test ":exclude_inks drops a Separation-inked line", %{doc: doc} do
      assert Document.text!(doc, @markup) =~ "Spot inked line"
      refute Document.text!(doc, @markup, exclude_inks: ["SpotRed"]) =~ "Spot inked line"
    end

    test ":exclude_layers drops an optional-content layer", %{doc: doc} do
      assert Document.text!(doc, @markup) =~ "Layered watermark line"

      refute Document.text!(doc, @markup, exclude_layers: ["Watermark"]) =~
               "Layered watermark line"
    end

    test "an unmatched ink or layer name leaves the text alone", %{doc: doc} do
      assert Document.text!(doc, @markup, exclude_inks: ["NoSuchInk"]) ==
               Document.text!(doc, @markup)
    end

    test "the whole-document arity separates pages with a form feed", %{doc: doc} do
      assert Document.text!(doc, []) |> String.split("\f") |> length() == 5
    end

    test "options apply to every page of the whole-document arity", %{doc: doc} do
      assert Document.text!(doc, expand_ligatures: true) =~ "cofin"
      refute Document.text!(doc, expand_ligatures: true) =~ "coﬁn"
    end
  end

  describe "to_plain_text/3" do
    setup do
      %{doc: open(@extraction_pdf), table_doc: open(@table_pdf), form_doc: open(@markdown_pdf)}
    end

    test ":include_form_fields false drops the widget's value", %{form_doc: doc} do
      assert Document.to_plain_text!(doc, 0) =~ "John Doe"
      refute Document.to_plain_text!(doc, 0, include_form_fields: false) =~ "John Doe"
    end

    test ":extract_tables false drops the column-aligned rendering", %{table_doc: doc} do
      assert Document.to_plain_text!(doc, 0) =~ "Age       0.042"
      refute Document.to_plain_text!(doc, 0, extract_tables: false) =~ "Age       0.042"
    end

    test ":table_detection reaches the detector", %{table_doc: doc} do
      assert Document.to_plain_text!(doc, 0, table_detection: [min_table_cells: 999]) ==
               Document.to_plain_text!(doc, 0, extract_tables: false)
    end

    test "every :reading_order value is accepted", %{doc: doc} do
      # Acceptance rather than divergence: no fixture page here is laid out so
      # that the three strategies order it differently.
      for order <- [:structure_tree, :column_aware, :top_to_bottom] do
        assert Document.to_plain_text!(doc, @columns, reading_order: order) =~ "Alpha one"
      end
    end

    test "a paragraph reflows where text/3 keeps the line break", %{form_doc: doc} do
      assert Document.text!(doc, 0) =~ "Markdown Fixture\nBody paragraph text."
      assert Document.to_plain_text!(doc, 0) =~ "Markdown Fixture Body paragraph text."
    end

    test "the whole-document arity separates pages with its own break", %{doc: doc} do
      assert Document.to_plain_text!(doc, []) |> String.split("\n\n---\n\n") |> length() == 5
    end
  end

  describe "words/3" do
    setup do: %{doc: open(@extraction_pdf)}

    test ":include_artifacts false drops an /Artifact-tagged running header", %{doc: doc} do
      assert "Running" in texts(Document.words!(doc, @artifacts))
      refute "Running" in texts(Document.words!(doc, @artifacts, include_artifacts: false))
    end

    test ":region keeps only the words overlapping it", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)

      assert texts(Document.words!(doc, @ruleless, region: first.bbox)) == ["Region"]
    end

    test ":region_mode distinguishes partial from full containment", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)
      %Rect{} = bbox = first.bbox
      half = %{bbox | width: bbox.width / 2}

      assert length(Document.words!(doc, @ruleless, region: half)) == 1
      assert Document.words!(doc, @ruleless, region: half, region_mode: :fully_contained) == []

      assert Document.words!(doc, @ruleless, region: half, region_mode: {:min_overlap, 0.9}) ==
               []
    end

    test "a reversed-corner region normalizes instead of matching nothing", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)
      %Rect{} = bbox = first.bbox

      # Same area, corners given the other way round. `Rect`'s fields are
      # public and PdfElixide.Geometry.Rect documents width/height as
      # non-negative, so building one by hand can easily produce this; it must
      # go through upstream's normalizing constructor rather than reach the
      # geometry helpers with a negative width and silently match nothing.
      reversed = %Rect{
        x: bbox.x + bbox.width,
        y: bbox.y + bbox.height,
        width: -bbox.width,
        height: -bbox.height
      }

      assert texts(Document.words!(doc, @ruleless, region: reversed)) ==
               texts(Document.words!(doc, @ruleless, region: bbox))
    end

    test ":region composes with the other options rather than replacing them", %{doc: doc} do
      [first | _] = Document.words!(doc, @artifacts)
      assert first.text == "Running"

      # Upstream's own `extract_words_in_rect` would discard `:include_artifacts`;
      # applying the region ourselves keeps both live.
      assert Document.words!(doc, @artifacts,
               region: first.bbox,
               include_artifacts: false
             ) == []
    end
  end

  describe "text_lines/3" do
    setup do: %{doc: open(@extraction_pdf)}

    test ":line_gap_threshold merges lines when raised", %{doc: doc} do
      default = Document.text_lines!(doc, @ruleless)
      merged = Document.text_lines!(doc, @ruleless, line_gap_threshold: 100.0)

      assert length(merged) < length(default)
    end

    test ":include_artifacts false drops the running header line", %{doc: doc} do
      assert Enum.any?(Document.text_lines!(doc, @artifacts), &(&1.text =~ "Running"))

      refute Enum.any?(
               Document.text_lines!(doc, @artifacts, include_artifacts: false),
               &(&1.text =~ "Running")
             )
    end
  end

  describe "chars/3" do
    setup do: %{doc: open(@extraction_pdf)}

    test ":region keeps only the characters overlapping it", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)
      chars = Document.chars!(doc, @ruleless, region: first.bbox)

      assert Enum.map_join(chars, & &1.text) == "Region"
    end

    test ":exclude_inks drops a Separation-inked line's characters", %{doc: doc} do
      all = Enum.map_join(Document.chars!(doc, @markup), & &1.text)

      filtered =
        Enum.map_join(Document.chars!(doc, @markup, exclude_inks: ["SpotRed"]), & &1.text)

      assert all =~ "Spot"
      refute filtered =~ "Spot"
    end

    test ":exclude_layers drops an optional-content layer's characters", %{doc: doc} do
      filtered =
        Enum.map_join(Document.chars!(doc, @markup, exclude_layers: ["Watermark"]), & &1.text)

      refute filtered =~ "watermark"
    end
  end

  describe "spans/3" do
    setup do: %{doc: open(@extraction_pdf)}

    test ":span_merging merge_tm_tj_runs false splits each text-matrix run", %{doc: doc} do
      # Both columns share a baseline, so the default merges each row into one
      # span; splitting on Tm yields the eight original runs in stream order.
      assert texts(Document.spans!(doc, @columns)) == [
               "Alpha oneBeta one",
               "Alpha twoBeta two",
               "Alpha threeBeta three",
               "Alpha fourBeta four"
             ]

      assert texts(Document.spans!(doc, @columns, span_merging: [merge_tm_tj_runs: false])) == [
               "Alpha one",
               "Alpha two",
               "Alpha three",
               "Alpha four",
               "Beta one",
               "Beta two",
               "Beta three",
               "Beta four"
             ]
    end

    test ":span_merging accepts a preset with per-field overrides", %{doc: doc} do
      assert texts(
               Document.spans!(doc, @columns,
                 span_merging: [preset: :conservative, merge_tm_tj_runs: false]
               )
             ) == texts(Document.spans!(doc, @columns, span_merging: [merge_tm_tj_runs: false]))
    end

    test ":span_merging accepts a nested :adaptive config", %{doc: doc} do
      assert texts(
               Document.spans!(doc, @columns,
                 span_merging: [
                   preset: :adaptive,
                   adaptive: [min_samples: 2, median_multiplier: 2.0]
                 ]
               )
             ) == texts(Document.spans!(doc, @columns))
    end

    test ":reading_order is accepted for every strategy", %{doc: doc} do
      # This fixture's columns merge into one span per row, so no strategy can
      # reorder them — the assertion is that each value decodes and returns the
      # full span set, not that the three differ.
      for order <- [:top_to_bottom, :column_aware, :structure] do
        assert length(Document.spans!(doc, @columns, reading_order: order)) == 4
      end
    end

    test ":exclude_layers drops a layer's spans", %{doc: doc} do
      refute Enum.any?(
               Document.spans!(doc, @markup, exclude_layers: ["Watermark"]),
               &(&1.text =~ "watermark")
             )
    end

    test ":region keeps only the spans overlapping it", %{doc: doc} do
      [first | _] = Document.spans!(doc, @ruleless)

      assert texts(Document.spans!(doc, @ruleless, region: first.bbox)) == [first.text]
    end
  end

  describe "tables/3" do
    setup do: %{doc: open(@extraction_pdf), table_doc: open(@table_pdf)}

    test ":min_table_cells rejects a grid that is too small", %{table_doc: doc} do
      assert length(Document.tables!(doc, 0)) == 1
      assert Document.tables!(doc, 0, min_table_cells: 999) == []
    end

    test ":preset :strict demands ruling lines and regular rows", %{doc: doc, table_doc: table} do
      # The booktabs fixture has ruling lines but rows that are too irregular
      # for :strict; the rule-less page has no lines for :strict to find.
      assert Document.tables!(table, 0, preset: :strict) == []
      assert Document.tables!(doc, @ruleless, preset: :strict) == []
      assert length(Document.tables!(doc, @ruleless)) == 1
    end

    test ":enabled false turns detection off", %{table_doc: doc} do
      assert Document.tables!(doc, 0, enabled: false) == []
    end

    test ":region keeps only the tables overlapping it", %{doc: doc} do
      [table] = Document.tables!(doc, @ruleless)
      far_away = %Rect{x: 0.0, y: 0.0, width: 10.0, height: 10.0}

      assert length(Document.tables!(doc, @ruleless, region: table.bbox)) == 1
      assert Document.tables!(doc, @ruleless, region: far_away) == []
    end

    test ":region keeps the caller's detection config", %{doc: doc} do
      [table] = Document.tables!(doc, @ruleless)

      # Upstream's own `extract_tables_in_rect` would substitute its :relaxed
      # preset here; ours passes the config through, so the cell floor still
      # rejects the table.
      assert Document.tables!(doc, @ruleless, region: table.bbox, min_table_cells: 999) == []
    end
  end

  describe "structured/3" do
    # In @structured_pdf: page 2 holds one body span per side of the page
    # midpoint, too few for the gutter detector.
    @sparse 2

    setup do: %{doc: open(@structured_pdf)}

    test ":column_mode :auto leaves a sparse page as one region", %{doc: doc} do
      assert [%{kind: :body, column: nil, text: "Left alone Right alone", spans: [_, _]}] =
               Document.structured!(doc, @sparse).regions
    end

    test ":column_mode :two splits it at the page midpoint", %{doc: doc} do
      assert [%{column: 0, text: "Left alone"}, %{column: 1, text: "Right alone"}] =
               Document.structured!(doc, @sparse, column_mode: :two).regions
    end

    test ":column_mode :single matches :auto there", %{doc: doc} do
      assert Document.structured!(doc, @sparse, column_mode: :single) ==
               Document.structured!(doc, @sparse)
    end
  end

  describe "Page delegates" do
    setup do: %{doc: open(@extraction_pdf)}

    test "each extractor forwards its options", %{doc: doc} do
      artifacts = Document.page!(doc, @artifacts)
      markup = Document.page!(doc, @markup)
      ruleless = Document.page!(doc, @ruleless)

      assert Page.text!(markup, expand_ligatures: true) =~ "cofin"
      refute "Running" in texts(Page.words!(artifacts, include_artifacts: false))

      refute Enum.any?(
               Page.text_lines!(artifacts, include_artifacts: false),
               &(&1.text =~ "Running")
             )

      refute Enum.map_join(Page.chars!(markup, exclude_inks: ["SpotRed"]), & &1.text) =~ "Spot"
      assert length(Page.spans!(ruleless, span_merging: [merge_tm_tj_runs: false])) == 12
      assert Page.tables!(ruleless, min_table_cells: 999) == []
    end

    test "no options still matches the document-level default", %{doc: doc} do
      page = Document.page!(doc, @columns)

      assert Page.text!(page) == Document.text!(doc, @columns)
      assert Page.words!(page) == Document.words!(doc, @columns)
    end
  end

  describe ":min_overlap range" do
    setup do: %{doc: open(@extraction_pdf)}

    test "a ratio outside 0.0..1.0 is rejected on both sides", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)

      for ratio <- [-0.1, -1.0, 1.1, 2.0] do
        error =
          assert_raise ArgumentError, fn ->
            Document.words(doc, @ruleless,
              region: first.bbox,
              region_mode: {:min_overlap, ratio}
            )
          end

        message = Exception.message(error)

        assert message =~ ":region_mode"
        assert message =~ "between 0.0 and 1.0"
        # The ratio echoes back in the float form it was passed, not as an
        # integer-looking `-1`.
        assert message =~ inspect(ratio)
      end
    end

    test ":exclude_regions_mode is checked too", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)

      # This is the arm where an unchecked ratio does the most damage: a
      # negative one matches every object, so the exclusion would silently
      # empty the page instead of dropping one region.
      assert_raise ArgumentError, ~r/:exclude_regions_mode/, fn ->
        Document.text(doc, @ruleless,
          exclude_regions: [first.bbox],
          exclude_regions_mode: {:min_overlap, -1.0}
        )
      end
    end

    test "every extractor that takes a mode rejects it", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)
      opts = [region: first.bbox, region_mode: {:min_overlap, 2.0}]

      for call <- [
            fn -> Document.text(doc, @ruleless, opts) end,
            fn -> Document.chars(doc, @ruleless, opts) end,
            fn -> Document.words(doc, @ruleless, opts) end,
            fn -> Document.text_lines(doc, @ruleless, opts) end,
            fn -> Document.spans(doc, @ruleless, opts) end,
            # …and the whole-document arities, which validate before looping.
            fn -> Document.text(doc, opts) end,
            fn -> Document.chars(doc, opts) end,
            fn -> Document.words(doc, opts) end,
            fn -> Document.text_lines(doc, opts) end,
            fn -> Document.spans(doc, opts) end
          ] do
        assert_raise ArgumentError, ~r/:region_mode/, call
      end
    end

    test "a ratio that is not a number falls through to the NIF's decoder", %{doc: doc} do
      # The Elixir pre-check owns the *range* only; type checking stays in one
      # place. Either way the caller gets an `ArgumentError` naming the field.
      assert_raise ArgumentError, ~r/:region_mode/, fn ->
        Document.words(doc, @ruleless, region_mode: {:min_overlap, :half})
      end
    end

    test "the in-range boundaries are accepted", %{doc: doc} do
      [first | _] = Document.words!(doc, @ruleless)

      assert texts(
               Document.words!(doc, @ruleless,
                 region: first.bbox,
                 region_mode: {:min_overlap, 1.0}
               )
             ) == ["Region"]

      assert Document.words!(doc, @ruleless,
               region: first.bbox,
               region_mode: {:min_overlap, 0.0}
             ) != []
    end

    test "{:min_overlap, 0.0} matches objects that do not touch the region", %{doc: doc} do
      # A non-overlapping object scores 0.0, which satisfies a 0.0 threshold.
      far_away = %Rect{x: 0.0, y: 0.0, width: 1.0, height: 1.0}
      all = Document.words!(doc, @ruleless)

      assert Document.words!(doc, @ruleless, region: far_away) == []

      assert length(
               Document.words!(doc, @ruleless, region: far_away, region_mode: {:min_overlap, 0.0})
             ) ==
               length(all)
    end
  end

  describe "option errors" do
    setup do: %{doc: open(@valid_pdf)}

    test "a declared key with a wrong-typed value raises, naming the key", %{doc: doc} do
      assert_raise ArgumentError, ~r/:include_artifacts/, fn ->
        Document.words(doc, 0, include_artifacts: "yes")
      end
    end

    test "a bad value inside a nested option map names the outer field", %{doc: doc} do
      # Rustler reports the field it failed to decode, and for a nested map
      # that is the nesting key rather than the offending leaf.
      assert_raise ArgumentError, ~r/:detection/, fn ->
        Document.tables(doc, 0, preset: :nope)
      end
    end

    test "a wrong-typed nested option value raises, naming the outer key", %{doc: doc} do
      # Wrong shapes must reach the decoder so the error names the public option,
      # not a private builder.
      for {call, field} <- [
            {fn -> Document.text(doc, 0, table_detection: :bad) end, ":table_detection"},
            {fn -> Document.spans(doc, 0, span_merging: :bad) end, ":span_merging"},
            {fn -> Document.spans(doc, 0, span_merging: [adaptive: :bad]) end, ":span_merging"}
          ] do
        assert_raise ArgumentError, ~r/#{field}/, call
      end
    end

    test "an unknown key nested inside an option map raises too", %{doc: doc} do
      assert_raise ArgumentError, ~r/:no_such_option/, fn ->
        Document.spans(doc, 0, span_merging: [no_such_option: true])
      end

      assert_raise ArgumentError, ~r/:no_such_option/, fn ->
        Document.spans(doc, 0, span_merging: [adaptive: [no_such_option: true]])
      end

      assert_raise ArgumentError, ~r/:no_such_option/, fn ->
        Document.text(doc, 0, table_detection: [no_such_option: true])
      end
    end

    test "a key valid for a sibling extractor is still unknown here", %{doc: doc} do
      # `:region` is a `tables/3` key, but not a `:table_detection` one — the
      # two lists are checked separately.
      assert_raise ArgumentError, ~r/:region/, fn ->
        Document.text(doc, 0, table_detection: [region: nil])
      end

      assert Document.tables!(doc, 0, region: nil) == Document.tables!(doc, 0)
    end

    test "nil still means unset for every nested option", %{doc: doc} do
      assert Document.text!(doc, 0, table_detection: nil) == Document.text!(doc, 0)
      assert Document.spans!(doc, 0, span_merging: nil) == Document.spans!(doc, 0)

      assert Document.spans!(doc, 0, span_merging: [adaptive: nil]) ==
               Document.spans!(doc, 0, span_merging: [])
    end

    test "an unknown key raises rather than being ignored", %{doc: doc} do
      # A typo must not silently do nothing, and the message names both the
      # offending key and what was allowed instead.
      error =
        assert_raise ArgumentError, fn -> Document.words(doc, 0, no_such_option: true) end

      message = Exception.message(error)

      assert message =~ ":no_such_option"
      assert message =~ ":include_artifacts"
    end

    test "a near-miss typo of a real key raises", %{doc: doc} do
      assert_raise ArgumentError, ~r/:include_artifact/, fn ->
        Document.words(doc, 0, include_artifact: true)
      end
    end

    test "a non-list, non-integer second argument raises", %{doc: doc} do
      assert_raise FunctionClauseError, fn -> Document.words(doc, :nope) end
    end

    test "a list that is not a keyword list raises", %{doc: doc} do
      assert_raise ArgumentError, ~r/keyword list/, fn -> Document.words(doc, 0, [:nope]) end
    end
  end
end
