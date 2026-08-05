defmodule PdfElixide.OptionKeysTest do
  @moduledoc """
  The caller-error contract for options, in one place.

  Every option-taking function validates its keyword list against a key list
  written out beside its `@typedoc`. That list is the only thing standing
  between a caller's typo and a silently ignored option, so this module pins
  both halves of the contract:

    * every key the typedoc *declares* is accepted, at a value of the declared
      type — a key dropped from the list, or a builder that stopped reading
      one, fails here rather than starting to reject working code;
    * a key the typedoc does not declare is rejected, with a message naming it.

  The key inventories below are hand-maintained mirrors of the `@typedoc`s on
  purpose. A generated one would agree with a wrong list as readily as a right
  one; the point is that adding an option means writing it down twice, and the
  second spelling is what catches a rename.

  The *behavior* of each option lives in `PdfElixide.ExtractionOptionsTest` and
  `PdfElixide.DocumentTest`. Nothing here asserts an option does anything.
  """
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")

  @rect %Rect{x: 0.0, y: 0.0, width: 1000.0, height: 1000.0}

  @adaptive_opts [
    median_multiplier: 1.5,
    min_threshold_pt: 0.1,
    max_threshold_pt: 10.0,
    use_iqr: true,
    min_samples: 5
  ]

  @span_merging_opts [
    preset: :aggressive,
    space_threshold_em_ratio: 0.3,
    conservative_threshold_pt: 0.5,
    column_boundary_threshold_pt: 10.0,
    severe_overlap_threshold_pt: -1.0,
    use_adaptive_threshold: true,
    adaptive: @adaptive_opts,
    detect_email_patterns: true,
    email_threshold_multiplier: 1.5,
    detect_citation_markers: true,
    citation_font_size_ratio: 0.7,
    merge_tm_tj_runs: false
  ]

  @table_detection_opts [
    preset: :strict,
    enabled: true,
    horizontal_strategy: :both,
    vertical_strategy: :lines,
    column_tolerance: 3.0,
    row_tolerance: 3.0,
    min_table_cells: 4,
    min_table_columns: 2,
    regular_row_ratio: 0.5,
    max_table_columns: 20,
    column_merge_threshold: 2.0,
    v_split_gap: 5.0,
    text_fallback: true
  ]

  @text_opts [
    extract_tables: true,
    expand_ligatures: true,
    table_detection: @table_detection_opts,
    region: @rect,
    region_mode: :intersects,
    exclude_regions: [@rect],
    exclude_regions_mode: :fully_contained,
    exclude_layers: ["Watermark"],
    exclude_inks: ["SpotRed"],
    on_page_error: :skip
  ]

  @markdown_opts [
    detect_headings: true,
    extract_tables: true,
    include_images: false,
    embed_images: true,
    image_output_dir: nil,
    include_form_fields: true,
    strip_running_headers_footers: false,
    expand_ligatures: false,
    annotate_skipped_pages: true,
    max_image_pixels: 1_000_000,
    reading_order: :structure_tree,
    bold_markers: :aggressive
  ]

  @html_opts [
    preserve_layout: true,
    detect_headings: true,
    extract_tables: true,
    include_images: false,
    embed_images: true,
    image_output_dir: nil,
    include_form_fields: true,
    max_image_pixels: 1_000_000,
    reading_order: :structure_tree
  ]

  @words_opts [
    include_artifacts: true,
    region: @rect,
    region_mode: :intersects,
    word_gap_threshold: 2.0,
    profile: :conservative
  ]

  @text_lines_opts [{:line_gap_threshold, 2.0} | @words_opts]

  @chars_opts [
    region: @rect,
    region_mode: :intersects,
    exclude_layers: ["Watermark"],
    exclude_inks: ["SpotRed"]
  ]

  @spans_opts [
    reading_order: :top_to_bottom,
    span_merging: @span_merging_opts,
    region: @rect,
    region_mode: :intersects,
    exclude_layers: ["Watermark"],
    exclude_inks: ["SpotRed"]
  ]

  @tables_opts [{:region, @rect} | @table_detection_opts]

  @search_opts [
    literal: true,
    case_insensitive: true,
    whole_word: true,
    max_results: 5
  ]

  @save_opts [
    incremental: false,
    compress: true,
    linearize: false,
    garbage_collect: true
  ]

  defp doc do
    doc = Document.open!(@valid_pdf)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  # Asserts the call did not reject its options. The result itself is
  # irrelevant — a `{:error, %PdfElixide.Error{}}` means the options were
  # accepted and something about the *document* failed, which is exactly the
  # split this module exists to pin.
  defp accepts!(key, fun) do
    fun.()
    :ok
  rescue
    error in ArgumentError ->
      flunk("#{inspect(key)} was rejected: #{Exception.message(error)}")
  end

  defp accepts_each!(opts, fun) do
    for {key, value} <- opts, do: accepts!(key, fn -> fun.([{key, value}]) end)
    # …and all of them together, which is the shape a real caller passes.
    accepts!(:all, fn -> fun.(opts) end)
  end

  describe "every declared key is accepted" do
    test "open/2" do
      accepts_each!([password: "secret"], &Document.open(@valid_pdf, &1))
    end

    test "text/2,3" do
      doc = doc()
      accepts_each!(@text_opts, &Document.text(doc, &1))
      accepts_each!(@text_opts, &Document.text(doc, 0, &1))
    end

    test "to_markdown/2,3" do
      doc = doc()
      accepts_each!(@markdown_opts, &Document.to_markdown(doc, &1))
      accepts_each!(@markdown_opts, &Document.to_markdown(doc, 0, &1))
    end

    test "to_html/2,3" do
      doc = doc()
      accepts_each!(@html_opts, &Document.to_html(doc, &1))
      accepts_each!(@html_opts, &Document.to_html(doc, 0, &1))
    end

    test "words/2,3" do
      doc = doc()
      accepts_each!(@words_opts, &Document.words(doc, &1))
      accepts_each!(@words_opts, &Document.words(doc, 0, &1))
    end

    test "text_lines/2,3" do
      doc = doc()
      accepts_each!(@text_lines_opts, &Document.text_lines(doc, &1))
      accepts_each!(@text_lines_opts, &Document.text_lines(doc, 0, &1))
    end

    test "chars/2,3" do
      doc = doc()
      accepts_each!(@chars_opts, &Document.chars(doc, &1))
      accepts_each!(@chars_opts, &Document.chars(doc, 0, &1))
    end

    test "spans/2,3" do
      doc = doc()
      accepts_each!(@spans_opts, &Document.spans(doc, &1))
      accepts_each!(@spans_opts, &Document.spans(doc, 0, &1))
    end

    test "tables/2,3" do
      doc = doc()
      accepts_each!(@tables_opts, &Document.tables(doc, &1))
      accepts_each!(@tables_opts, &Document.tables(doc, 0, &1))
    end

    test "inks/3" do
      doc = doc()
      accepts_each!([deep: true], &Document.inks(doc, 0, &1))
    end

    test "search/3,4" do
      doc = doc()
      accepts_each!(@search_opts, &Document.search(doc, "Page", &1))
      accepts_each!(@search_opts, &Document.search(doc, "Page", 0, &1))
    end

    test ":span_merging and its nested :adaptive" do
      doc = doc()
      accepts_each!(@span_merging_opts, &Document.spans(doc, 0, span_merging: &1))
      accepts_each!(@adaptive_opts, &Document.spans(doc, 0, span_merging: [adaptive: &1]))
    end

    test ":table_detection, which takes the detection keys but not :region" do
      doc = doc()
      accepts_each!(@table_detection_opts, &Document.text(doc, 0, table_detection: &1))
    end

    test "Editor.save/3 and to_binary/2" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      accepts_each!(@save_opts, &Editor.to_binary(editor, &1))
    end

    test "Table.to_markdown/2" do
      doc = Document.open!(@table_pdf)
      on_exit(fn -> Document.close(doc) end)
      [table] = Document.tables!(doc, 0)
      accepts_each!([bold_markers: :aggressive], &Document.Table.to_markdown(table, &1))
    end

    test "Image.to_binary/2 and save/3" do
      doc = Document.open!(@image_pdf)
      on_exit(fn -> Document.close(doc) end)
      [image] = Document.images!(doc, 0)
      accepts_each!([format: :jpeg], &Document.Image.to_binary(image, &1))
    end
  end

  describe "an undeclared key is rejected" do
    test "by every option-taking function" do
      doc = doc()
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      table_doc = Document.open!(@table_pdf)
      on_exit(fn -> Document.close(table_doc) end)
      [table] = Document.tables!(table_doc, 0)
      image_doc = Document.open!(@image_pdf)
      on_exit(fn -> Document.close(image_doc) end)
      [image] = Document.images!(image_doc, 0)

      calls = [
        fn opts -> Document.open(@valid_pdf, opts) end,
        fn opts -> Document.text(doc, opts) end,
        fn opts -> Document.text(doc, 0, opts) end,
        fn opts -> Document.to_markdown(doc, opts) end,
        fn opts -> Document.to_html(doc, opts) end,
        fn opts -> Document.words(doc, 0, opts) end,
        fn opts -> Document.text_lines(doc, 0, opts) end,
        fn opts -> Document.chars(doc, 0, opts) end,
        fn opts -> Document.spans(doc, 0, opts) end,
        fn opts -> Document.tables(doc, 0, opts) end,
        fn opts -> Document.inks(doc, 0, opts) end,
        fn opts -> Document.search(doc, "Page", opts) end,
        fn opts -> Document.search(doc, "Page", 0, opts) end,
        fn opts -> Document.text(doc, 0, table_detection: opts) end,
        fn opts -> Document.spans(doc, 0, span_merging: opts) end,
        fn opts -> Document.spans(doc, 0, span_merging: [adaptive: opts]) end,
        fn opts -> Editor.to_binary(editor, opts) end,
        fn opts -> Editor.save(editor, "/dev/null", opts) end,
        fn opts -> Document.Table.to_markdown(table, opts) end,
        fn opts -> Document.Image.to_binary(image, opts) end,
        fn opts -> Document.Image.save(image, "out.png", opts) end
      ]

      for call <- calls do
        assert_raise ArgumentError, ~r/:no_such_option/, fn ->
          call.(no_such_option: true)
        end
      end
    end
  end

  describe "a duplicated key is rejected" do
    test "rather than resolved to the first occurrence" do
      # `Keyword.get` used to take the first silently, which quietly discards
      # the intent of `defaults ++ user_opts`. Rejecting it is what pushes
      # callers to `Keyword.merge/2`.
      doc = doc()

      assert_raise ArgumentError, ~r/duplicate keys \[:detect_headings\]/, fn ->
        Document.to_html(doc, detect_headings: true, detect_headings: false)
      end

      assert_raise ArgumentError, ~r/duplicate keys \[:deep\]/, fn ->
        Document.inks(doc, 0, deep: true, deep: false)
      end
    end
  end
end
