defmodule PdfElixide.OptionDefaultsTest do
  @moduledoc """
  The default *value* of every option, in one place.

  A `NifMap` decode is total, so each `build_*_options/1` must emit every key
  its Rust struct declares, with the default written inline as the third
  argument of a `Keyword.get/3`. Those ~90 values are a public contract, and
  they are the one kind of drift nothing else notices: a *missing* key is a
  decode error the very next call raises, but a *changed* default is silent.

  The obvious shape for catching it does not work. `f(doc, key: default) ==
  f(doc)` cannot fail, because both sides go through the same builder and reach
  the same map — and `f(doc, i, []) == f(doc, i)` is likewise a tautology
  today, the no-option arity being defined as the option arity with a literal
  `[]`. Roughly half the keys default to `nil` and are observable on no fixture
  at all, so behavior cannot reach them either.

  So this module compares the built maps directly, through the `@doc false`
  `__option_defaults__/1` of each module, which calls the real builders with an
  empty list. `lib` therefore spells each default once and cannot disagree with
  itself; only the maps below can disagree with it, which is the point — they
  are hand-written mirrors of the `@typedoc`s, and adding an option means
  writing it down a third time (key list, typedoc, default).

  Each assertion is a whole-map `==`, never a subset, so a renamed or added key
  fails here too.

  Nothing here asserts that a default *does* anything. That half lives with the
  behavior it pins: `PdfElixide.ExtractionOptionsTest` for the extractor knobs,
  `PdfElixide.DocumentTest` for `:detect_headings`, `:on_page_error` and the
  image `:format`, `PdfElixide.UpstreamDriftTest` for `:include_artifacts` and
  the table-detection preset, `PdfElixide.EditorTest` for `:incremental`. The
  one default with no home elsewhere, `:compress`, is pinned at the bottom.
  """
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  # The largest fixture, so compression has something to bite on.
  @fonts_pdf Path.join(@fixtures, "fonts.pdf")

  # Page indices within @extraction_pdf.
  @columns 0
  @ruleless 3

  # Every key except `:preset` is `nil`, meaning "keep the preset's value" —
  # the preset is resolved in Rust so its numbers cannot drift from upstream.
  # Filling one in here would move that decision back into Elixir.
  @table_detection_defaults %{
    preset: :default,
    enabled: nil,
    horizontal_strategy: nil,
    vertical_strategy: nil,
    column_tolerance: nil,
    row_tolerance: nil,
    min_table_cells: nil,
    min_table_columns: nil,
    regular_row_ratio: nil,
    max_table_columns: nil,
    column_merge_threshold: nil,
    v_split_gap: nil,
    text_fallback: nil
  }

  defp open(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp texts_of_tables(tables), do: Enum.map(tables, & &1.rows)

  describe "every builder emits exactly its documented defaults" do
    test "open/2" do
      assert Document.__option_defaults__(:open) == %{password: nil}
    end

    test "inks/3" do
      assert Document.__option_defaults__(:inks) == %{deep: false}
    end

    test "text/2,3" do
      assert Document.__option_defaults__(:text) == %{
               extract_tables: true,
               expand_ligatures: false,
               table_detection: nil,
               region: nil,
               region_mode: :intersects,
               exclude_regions: [],
               exclude_regions_mode: :intersects,
               exclude_layers: [],
               exclude_inks: [],
               on_page_error: :skip
             }
    end

    test "to_markdown/2,3" do
      assert Document.__option_defaults__(:markdown) == %{
               detect_headings: true,
               extract_tables: true,
               include_images: false,
               embed_images: true,
               image_output_dir: nil,
               include_form_fields: true,
               strip_running_headers_footers: false,
               expand_ligatures: false,
               annotate_skipped_pages: true,
               max_image_pixels: nil,
               reading_order: :structure_tree,
               bold_markers: :conservative
             }
    end

    test "to_html/2,3" do
      # The four markdown-only fields are absent rather than defaulted: the
      # HTML converter never reads them, and `build_html_options/1` rejects
      # them outright.
      assert Document.__option_defaults__(:html) == %{
               preserve_layout: false,
               detect_headings: true,
               extract_tables: true,
               include_images: false,
               embed_images: true,
               image_output_dir: nil,
               include_form_fields: true,
               max_image_pixels: nil,
               reading_order: :structure_tree
             }
    end

    test "words/2,3" do
      assert Document.__option_defaults__(:words) == %{
               include_artifacts: true,
               word_gap_threshold: nil,
               profile: nil,
               region: nil,
               region_mode: :intersects
             }
    end

    test "text_lines/2,3" do
      assert Document.__option_defaults__(:text_lines) == %{
               include_artifacts: true,
               word_gap_threshold: nil,
               line_gap_threshold: nil,
               profile: nil,
               region: nil,
               region_mode: :intersects
             }
    end

    test "chars/2,3" do
      assert Document.__option_defaults__(:chars) == %{
               region: nil,
               region_mode: :intersects,
               exclude_layers: [],
               exclude_inks: []
             }
    end

    test "spans/2,3" do
      # `:reading_order` is the span-level upstream type, which names its
      # values differently from the converters' — hence `:top_to_bottom` here
      # against `:structure_tree` there.
      assert Document.__option_defaults__(:spans) == %{
               reading_order: :top_to_bottom,
               span_merging: nil,
               region: nil,
               region_mode: :intersects,
               exclude_layers: [],
               exclude_inks: []
             }
    end

    test "tables/2,3" do
      assert Document.__option_defaults__(:tables) == %{
               detection: @table_detection_defaults,
               region: nil
             }
    end

    test ":table_detection, the nested form" do
      # Reached with `[]`, not `nil`: unset means "no config at all", and only
      # the list form builds a map to have defaults in.
      assert Document.__option_defaults__(:table_detection) == @table_detection_defaults
    end

    test ":span_merging" do
      assert Document.__option_defaults__(:span_merging) == %{
               preset: :default,
               space_threshold_em_ratio: nil,
               conservative_threshold_pt: nil,
               column_boundary_threshold_pt: nil,
               severe_overlap_threshold_pt: nil,
               use_adaptive_threshold: nil,
               adaptive: nil,
               detect_email_patterns: nil,
               email_threshold_multiplier: nil,
               detect_citation_markers: nil,
               citation_font_size_ratio: nil,
               merge_tm_tj_runs: nil
             }
    end

    test ":span_merging's nested :adaptive" do
      assert Document.__option_defaults__(:adaptive_threshold) == %{
               median_multiplier: nil,
               min_threshold_pt: nil,
               max_threshold_pt: nil,
               use_iqr: nil,
               min_samples: nil
             }
    end

    test "Editor.save/3 and to_binary/2" do
      assert Editor.__option_defaults__(:save) == %{
               incremental: false,
               compress: true,
               linearize: false,
               garbage_collect: true
             }
    end

    test "Table.to_markdown/2" do
      assert Document.Table.__option_defaults__(:markdown) == %{bold_markers: :conservative}
    end
  end

  describe "the no-option arities go through the builders" do
    setup do: %{doc: open(@extraction_pdf)}

    # These two are tautologies *today* — every no-option arity is defined as
    # the option arity with a literal `[]`, so both sides are the same call —
    # and they exist to keep it that way. An arity that stopped delegating and
    # hand-built its own option map would quietly acquire a second set of
    # defaults, which the describe above could not see. Neither test pins an
    # individual value.
    test "an empty option list matches the no-option arity", %{doc: doc} do
      assert Document.text!(doc, @columns, []) == Document.text!(doc, @columns)
      assert Document.text!(doc, []) == Document.text!(doc)
      assert Document.words!(doc, @columns, []) == Document.words!(doc, @columns)
      assert Document.words!(doc, []) == Document.words!(doc)
      assert Document.chars!(doc, @columns, []) == Document.chars!(doc, @columns)
      assert Document.text_lines!(doc, @columns, []) == Document.text_lines!(doc, @columns)
      assert Document.spans!(doc, @columns, []) == Document.spans!(doc, @columns)
      assert Document.inks!(doc, @columns, []) == Document.inks!(doc, @columns)
    end

    test "tables/3 with no options matches tables/2", %{doc: doc} do
      assert texts_of_tables(Document.tables!(doc, @ruleless, [])) ==
               texts_of_tables(Document.tables!(doc, @ruleless))
    end
  end

  describe "a default that only behavior can pin" do
    test ":compress true still compresses" do
      # The map above pins the value; this pins that `true` still reaches
      # upstream and means what it says. Sizes rather than bytes: upstream's
      # writer happens to be deterministic — no clock, no `/ID`, sorted keys —
      # but that is its business, not a contract this library should assert.
      editor = Editor.open!(@fonts_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert byte_size(Editor.to_binary!(editor, compress: false)) >
               byte_size(Editor.to_binary!(editor))
    end
  end
end
