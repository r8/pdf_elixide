defmodule PdfElixide.OptionDefaultsTest do
  @moduledoc false
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

    test "to_plain_text/2,3" do
      assert Document.__option_defaults__(:plain_text) == %{
               extract_tables: true,
               table_detection: nil,
               reading_order: :structure_tree,
               include_form_fields: true
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

    test "structured/2,3" do
      assert Document.__option_defaults__(:structured) == %{column_mode: :auto}
    end

    test "tables/2,3" do
      assert Document.__option_defaults__(:tables) == %{
               detection: @table_detection_defaults,
               region: nil
             }
    end

    test ":table_detection, the nested form" do
      # Reached with `[]`, not `nil`: for every nested option, unset means "no
      # config at all", and only the list form builds a map to have defaults in.
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

    test "search/3,4" do
      assert Document.__option_defaults__(:search) == %{
               literal: true,
               case_insensitive: false,
               whole_word: false,
               max_results: 0
             }
    end

    test "Editor.save/3 and to_binary/2" do
      assert Editor.__option_defaults__(:save) == %{
               incremental: false,
               compress: true,
               garbage_collect: true,
               encryption: nil
             }
    end

    test ":encryption, the nested form" do
      # `[]` rather than `nil`, as for `:table_detection` above.
      assert Editor.__option_defaults__(:encryption) == %{
               user_password: "",
               owner_password: "",
               algorithm: :aes128,
               permissions: %{
                 print_low_res: true,
                 print_high_res: true,
                 modify: true,
                 copy: true,
                 annotate: true,
                 fill_forms: true,
                 accessibility: true,
                 assemble: true
               }
             }
    end

    test ":encryption's nested :permissions" do
      assert Editor.__option_defaults__(:permissions) == %{
               print_low_res: true,
               print_high_res: true,
               modify: true,
               copy: true,
               annotate: true,
               fill_forms: true,
               accessibility: true,
               assemble: true
             }
    end

    test "Editor.embed_file/4" do
      assert Editor.__option_defaults__(:embed) == %{description: nil, relationship: nil}
    end

    test "Table.to_markdown/2" do
      assert Document.Table.__option_defaults__(:markdown) == %{bold_markers: :conservative}
    end
  end

  describe "the no-option arities go through the builders" do
    setup do: %{doc: open(@extraction_pdf)}

    test "an empty option list matches the no-option arity", %{doc: doc} do
      assert Document.text!(doc, @columns, []) == Document.text!(doc, @columns)
      assert Document.text!(doc, []) == Document.text!(doc)

      assert Document.to_plain_text!(doc, @columns, []) ==
               Document.to_plain_text!(doc, @columns)

      assert Document.to_plain_text!(doc, []) == Document.to_plain_text!(doc)
      assert Document.words!(doc, @columns, []) == Document.words!(doc, @columns)
      assert Document.words!(doc, []) == Document.words!(doc)
      assert Document.chars!(doc, @columns, []) == Document.chars!(doc, @columns)
      assert Document.text_lines!(doc, @columns, []) == Document.text_lines!(doc, @columns)
      assert Document.spans!(doc, @columns, []) == Document.spans!(doc, @columns)
      assert Document.structured!(doc, @columns, []) == Document.structured!(doc, @columns)
      assert Document.structured!(doc, []) == Document.structured!(doc)
      assert Document.inks!(doc, @columns, []) == Document.inks!(doc, @columns)

      assert Document.search!(doc, "the", @columns, []) ==
               Document.search!(doc, "the", @columns)

      assert Document.search!(doc, "the", []) == Document.search!(doc, "the")
    end

    test "tables/3 with no options matches tables/2", %{doc: doc} do
      assert texts_of_tables(Document.tables!(doc, @ruleless, [])) ==
               texts_of_tables(Document.tables!(doc, @ruleless))
    end
  end

  describe "a default that only behavior can pin" do
    test ":compress true still compresses" do
      # Compare sizes rather than exact bytes; deterministic serialization is
      # not part of this library's contract.
      editor = Editor.open!(@fonts_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert byte_size(Editor.to_binary!(editor, compress: false)) >
               byte_size(Editor.to_binary!(editor))
    end

    test ":encryption nil writes an unencrypted document" do
      editor = Editor.open!(@fonts_pdf)
      on_exit(fn -> Editor.close(editor) end)

      doc = Document.from_binary!(Editor.to_binary!(editor))
      on_exit(fn -> Document.close(doc) end)

      refute Document.encrypted?(doc)
    end
  end
end
