defmodule PdfElixide.OptionKeysTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Builder
  alias PdfElixide.Compliance
  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Form
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")

  @rect %Rect{x: 0.0, y: 0.0, width: 1000.0, height: 1000.0}

  @redaction_opts [
    edge_padding: 1.0,
    default_fill: %PdfElixide.Color.RGB{r: 1.0, g: 1.0, b: 1.0},
    draw_default_overlay: false
  ]

  @plain_text_create_opts [
    title: "Title",
    author: "Author",
    page_size: {300.0, 400.0},
    margin_top: 10,
    margin_bottom: 10.0,
    margin_left: 10,
    line_height: 1.2
  ]

  @create_opts @plain_text_create_opts ++ [subject: "Subject", font_size: 10.0]

  @builder_new_opts [
    title: "Title",
    author: "Author",
    subject: "Subject",
    creator: "Creator",
    page_size: {300.0, 400.0},
    margin_top: 10,
    margin_bottom: 10.0,
    margin_left: 10,
    margin_right: 10.0,
    font: :times,
    font_size: 10.0,
    line_height: 1.2
  ]

  @builder_output_opts [compress: false, garbage_collect: false, encryption: nil]

  @image_create_opts [
    title: "Title",
    author: "Author",
    subject: "Subject",
    page_size: {300.0, 400.0},
    margin_top: 10,
    margin_bottom: 10.0,
    margin_left: 10,
    margin_right: 10.0
  ]

  @non_redaction_opts [
    scrub_metadata: false,
    remove_javascript: false,
    remove_embedded_files: false,
    optional_content: :keep,
    emit_redaction_artifacts: true
  ]

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

  @text_table_detection_opts Keyword.delete(@table_detection_opts, :text_fallback)

  @text_opts [
    extract_tables: true,
    expand_ligatures: true,
    table_detection: @text_table_detection_opts,
    region: @rect,
    region_mode: :intersects,
    exclude_regions: [@rect],
    exclude_regions_mode: :fully_contained,
    exclude_layers: [],
    exclude_inks: [],
    on_page_error: :skip
  ]

  @page_text_opts Keyword.delete(@text_opts, :on_page_error)

  @markdown_opts [
    detect_headings: true,
    extract_tables: true,
    include_images: false,
    embed_images: true,
    image_output_dir: nil,
    include_form_fields: true,
    strip_running_headers_footers: false,
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

  @plain_text_opts [
    extract_tables: false,
    table_detection: @text_table_detection_opts,
    reading_order: :top_to_bottom,
    include_form_fields: false
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
    span_merging: nil,
    region: @rect,
    region_mode: :intersects,
    exclude_layers: ["Watermark"],
    exclude_inks: ["SpotRed"]
  ]

  @tables_opts [{:region, @rect}, {:region_mode, :intersects} | @table_detection_opts]

  @structured_opts [column_mode: :two]
  @running_regions_opts [area: :header, threshold: 0.5]

  @search_opts [
    literal: true,
    case_insensitive: true,
    whole_word: true,
    max_results: 5
  ]

  @save_opts [
    incremental: false,
    compress: true,
    garbage_collect: true,
    encryption: [user_password: "secret"]
  ]

  @encryption_opts [
    user_password: "secret",
    owner_password: "owner",
    algorithm: :aes128,
    permissions: [copy: false]
  ]

  @permission_opts [
    print_low_res: true,
    print_high_res: true,
    modify: true,
    copy: true,
    annotate: true,
    fill_forms: true,
    accessibility: true,
    assemble: true
  ]

  defp doc do
    doc = Document.open!(@valid_pdf)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  # Asserts the call did not reject its options. The result itself is
  # irrelevant — a `{:error, %PdfElixide.Error{}}` means the options were
  # accepted and something about the *document* failed.
  defp accepts!(key, fun) do
    fun.()
    :ok
  rescue
    error in ArgumentError ->
      flunk("#{inspect(key)} was rejected: #{Exception.message(error)}")
  end

  defp field_rect, do: %PdfElixide.Geometry.Rect{x: 72, y: 72, width: 100, height: 20}

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
      accepts_each!(@page_text_opts, &Document.text(doc, 0, &1))

      # The filters refuse the other non-default keys, so `@text_opts` leaves
      # them empty; test real values on their own.
      for opts <- [[exclude_layers: ["Watermark"]], [exclude_inks: ["SpotRed"]]] do
        accepts!(hd(Keyword.keys(opts)), fn -> Document.text(doc, opts) end)
        accepts!(hd(Keyword.keys(opts)), fn -> Document.text(doc, 0, opts) end)
      end
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

    test "to_plain_text/2,3" do
      doc = doc()
      accepts_each!(@plain_text_opts, &Document.to_plain_text(doc, &1))
      accepts_each!(@plain_text_opts, &Document.to_plain_text(doc, 0, &1))
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

      # `:span_merging` refuses the other non-default keys, so `@spans_opts`
      # leaves it nil; test a real config on its own.
      accepts!(:span_merging, fn -> Document.spans(doc, span_merging: @span_merging_opts) end)
      accepts!(:span_merging, fn -> Document.spans(doc, 0, span_merging: @span_merging_opts) end)
    end

    test "structured/2,3" do
      doc = doc()
      accepts_each!(@structured_opts, &Document.structured(doc, &1))
      accepts_each!(@structured_opts, &Document.structured(doc, 0, &1))
    end

    test "running_regions/2" do
      doc = doc()
      accepts_each!(@running_regions_opts, &Document.running_regions(doc, &1))
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

    test "bookmark_segments/2 and the Editor's bookmark calls" do
      doc = doc()
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      opts = [depth: 2, title_prefix: "Page", ignore_case: true, include_front_matter: false]

      accepts_each!(opts, &Document.bookmark_segments(doc, &1))
      accepts_each!(opts, &Editor.bookmark_segments(editor, &1))
      accepts_each!(opts, &Editor.split_by_bookmarks(editor, &1))
      accepts!(:depth, fn -> Document.bookmark_segments(doc, depth: :all) end)
    end

    test "render/3" do
      doc = doc()

      # Use `fit: nil` to avoid conflicts with `:dpi` and `:region`;
      # test a real fit separately.
      accepts_each!(
        [
          dpi: 72,
          format: :jpeg,
          background: %PdfElixide.Color.RGB{r: 0.5, g: 0.5, b: 0.5},
          render_annotations: false,
          jpeg_quality: 50,
          exclude_layers: ["Watermark"],
          fit: nil,
          region: %PdfElixide.Geometry.Rect{x: 0.0, y: 0.0, width: 10.0, height: 10.0},
          max_output_pixels: 8_000_000
        ],
        &Document.render(doc, 0, &1)
      )

      accepts!(:fit, fn -> Document.render(doc, 0, fit: {32, 32}) end)
      accepts!(:background, fn -> Document.render(doc, 0, background: nil) end)
      accepts!(:format, fn -> Document.render(doc, 0, format: :rgba8, dpi: 20) end)
    end

    test "separations/3, separation/4 and rasterize/2" do
      doc = doc()
      accepts_each!([dpi: 36], &Document.separations(doc, 0, &1))
      accepts_each!([dpi: 36], &Document.separation(doc, 0, "Cyan", &1))
      accepts_each!([dpi: 36], &Document.rasterize(doc, &1))
    end

    test "to_docx/2, to_pptx/2 and to_xlsx/2" do
      doc = doc()
      accepts_each!([mode: :flow], &Document.to_docx(doc, &1))
      accepts_each!([mode: :layout], &Document.to_pptx(doc, &1))
      accepts_each!([mode: :auto], &Document.to_xlsx(doc, &1))
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
      accepts_each!(@text_table_detection_opts, &Document.text(doc, 0, table_detection: &1))
    end

    test "Editor.open/2 and from_binary/2" do
      accepts_each!([password: "secret"], &Editor.open(@valid_pdf, &1))
    end

    test "Editor.from_markdown/2, from_html/2 and from_plain_text/2" do
      accepts_each!(@create_opts, &Editor.from_markdown("Text", &1))
      accepts_each!(@create_opts, &Editor.from_html("Text", &1))
      accepts_each!(@plain_text_create_opts, &Editor.from_plain_text("Text", &1))
    end

    test "Editor.from_images/2" do
      accepts_each!(
        @image_create_opts,
        &Editor.from_images([PdfElixide.Png.solid(8, 8, :rgb)], &1)
      )
    end

    test "Builder.new/1, paragraph/3 and to_binary/2" do
      accepts_each!(@builder_new_opts, &Builder.new/1)

      accepts_each!(
        [font: :courier, font_size: 10],
        &Builder.paragraph(Builder.new(), "Text", &1)
      )

      accepts_each!(
        [
          bold: true,
          italic: true,
          color: %PdfElixide.Color.RGB{r: 1.0, g: 0.0, b: 0.0},
          link: "https://example.com"
        ],
        &Builder.paragraph(Builder.new(), [{"Text", &1}])
      )

      accepts_each!([font: :times, font_size: 20], &Builder.heading(Builder.new(), 1, "T", &1))

      accepts_each!(
        [font: :times, font_size: 20],
        &Builder.text_at(Builder.new(), {72, 72}, "T", &1)
      )

      accepts_each!(
        [font: :times, font_size: 20, align: :center],
        &Builder.text_in_rect(
          Builder.new(),
          %PdfElixide.Geometry.Rect{x: 72, y: 72, width: 100, height: 100},
          "T",
          &1
        )
      )

      accepts_each!(
        [
          font: :times,
          font_size: 20,
          column_widths: [{:weight, 1}],
          align: [:right],
          header_rows: 1,
          header_fill: %PdfElixide.Color.RGB{r: 0.9, g: 0.9, b: 0.9},
          padding: 2,
          stroke_color: %PdfElixide.Color.RGB{r: 1.0, g: 0.0, b: 0.0},
          stroke_width: 1
        ],
        &Builder.table(Builder.new(), [["T"]], &1)
      )

      accepts_each!(
        [
          colspan: 1,
          rowspan: 1,
          align: :center,
          fill_color: %PdfElixide.Color.RGB{r: 0.9, g: 0.9, b: 0.9}
        ],
        &Builder.table(Builder.new(), [[Builder.cell("T", &1)]])
      )

      accepts_each!(
        [font: :courier, font_size: 10],
        &Builder.bullet_list(Builder.new(), ["a"], &1)
      )

      accepts_each!(
        [font: :courier, font_size: 10, style: :lower_alpha, start: 3],
        &Builder.numbered_list(Builder.new(), ["a"], &1)
      )

      accepts_each!(
        [regular: "a", bold: "b", italic: "c", bold_italic: "d"],
        &Builder.FontFamily.new(Keyword.merge([regular: "r"], &1))
      )

      accepts_each!(@builder_output_opts, &Builder.to_binary(Builder.new(), &1))
    end

    test "the Builder drawing operations" do
      red = %PdfElixide.Color.RGB{r: 1.0, g: 0.0, b: 0.0}
      line_opts = [stroke_color: red, stroke_width: 2, dash_pattern: {[3, 2], 0}]
      shape_opts = Keyword.put(line_opts, :fill_color, red)
      rect = %PdfElixide.Geometry.Rect{x: 72, y: 72, width: 10, height: 10}

      accepts_each!(shape_opts, &Builder.rect(Builder.new(), rect, &1))
      accepts_each!(shape_opts, &Builder.circle(Builder.new(), {72, 72}, 10, &1))
      accepts_each!(shape_opts, &Builder.ellipse(Builder.new(), {72, 72}, {10, 5}, &1))
      accepts_each!(shape_opts, &Builder.polygon(Builder.new(), [{0, 0}, {1, 0}, {0, 1}], &1))
      accepts_each!(shape_opts, &Builder.path(Builder.new(), [{:move_to, 0, 0}], &1))
      accepts_each!(line_opts, &Builder.line(Builder.new(), {0, 0}, {1, 1}, &1))
      accepts_each!(line_opts, &Builder.arc(Builder.new(), {72, 72}, 10, 0, 90, &1))

      accepts_each!(
        line_opts,
        &Builder.bezier(Builder.new(), {0, 0}, {1, 1}, {2, 1}, {3, 0}, &1)
      )

      assert_raise ArgumentError, ~r/:fill_color/, fn ->
        Builder.line(Builder.new(), {0, 0}, {1, 1}, fill_color: red)
      end
    end

    # Images are decoded when the document is built, so any bytes are accepted
    # here. `fit: :fill` alone raises, so the list keeps the default.
    test "the Builder image operations" do
      rect = %PdfElixide.Geometry.Rect{x: 72, y: 72, width: 10, height: 10}

      accepts_each!(
        [width: 100, height: 50, fit: :contain, align: :center],
        &Builder.image(Builder.new(), "image", &1)
      )

      assert %Builder{} =
               Builder.image(Builder.new(), "image", width: 100, height: 50, fit: :fill)

      accepts_each!([fit: :fill], &Builder.image_in_rect(Builder.new(), rect, "image", &1))
    end

    test "Builder.watermark/3" do
      accepts_each!(
        [
          pages: :all,
          center: {100, 100},
          rotation: 30,
          font: :times,
          bold: true,
          font_size: 40,
          color: %PdfElixide.Color.RGB{r: 1.0, g: 0.0, b: 0.0},
          opacity: 0.5
        ],
        &Builder.watermark(Builder.new(), "DRAFT", &1)
      )
    end

    test "the Builder form fields" do
      rect = field_rect()
      field = [required: true, read_only: true, tooltip: "tip"]

      accepts_each!(
        [value: "v", default_value: "d"] ++ field,
        &Builder.text_field(Builder.new(), "f", rect, &1)
      )

      accepts_each!([checked: true] ++ field, &Builder.check_box(Builder.new(), "f", rect, &1))

      accepts_each!(
        [selected: "a"] ++ field,
        &Builder.combo_box(Builder.new(), "f", rect, ["a"], &1)
      )

      accepts_each!(
        [multi_select: false, selected: "a"] ++ field,
        &Builder.list_box(Builder.new(), "f", rect, ["a"], &1)
      )

      accepts_each!(
        [read_only: true, tooltip: "tip"],
        &Builder.push_button(Builder.new(), "f", rect, "Go", &1)
      )

      accepts_each!(
        [read_only: true, tooltip: "tip"],
        &Builder.signature_field(Builder.new(), "f", rect, &1)
      )
    end

    test "Editor.save/3 and to_binary/2" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      accepts_each!(@save_opts, &Editor.to_binary(editor, &1))
    end

    test ":encryption, and each algorithm it accepts" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      accepts_each!(@encryption_opts, &Editor.to_binary(editor, encryption: &1))

      for algorithm <- [:aes128, :rc4_128] do
        accepts!(algorithm, fn ->
          Editor.to_binary(editor, encryption: [algorithm: algorithm])
        end)
      end
    end

    test ":encryption's nested :permissions" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      accepts_each!(
        @permission_opts,
        &Editor.to_binary(editor, encryption: [permissions: &1])
      )
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

    test "Form.export/3" do
      doc = Document.open!(@form_pdf)
      on_exit(fn -> Document.close(doc) end)
      accepts_each!([file_spec: "form.pdf"], &Form.export(doc, :fdf, &1))
    end

    test "Editor.embed_file/4" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      accepts_each!(
        [description: "Chart data", relationship: :data],
        &Editor.embed_file(editor, "data.csv", "a,b", &1)
      )
    end

    test "Editor.crop_margins/2" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      accepts_each!([left: 1, right: 1.5, top: 2, bottom: 0], &Editor.crop_margins(editor, &1))
    end

    # Reusing an editor would hit the one-pass refusal before exercising options.
    test "Editor.apply_redactions/2" do
      accepts_each!(@redaction_opts, fn opts ->
        editor = Editor.open!(@valid_pdf)
        on_exit(fn -> Editor.close(editor) end)

        Editor.apply_redactions(editor, opts)
      end)
    end

    test "Editor.sanitize/2" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      accepts_each!(
        [scrub_metadata: false, remove_javascript: false, remove_embedded_files: false],
        &Editor.sanitize(editor, &1)
      )
    end

    test "Compliance.convert/3" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      accepts_each!(
        [
          embed_fonts: false,
          remove_javascript: false,
          remove_embedded_files: false,
          icc_profile: "profile"
        ],
        &Compliance.convert(editor, :pdf_a_2b, &1)
      )
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
      form_doc = Document.open!(@form_pdf)
      on_exit(fn -> Document.close(form_doc) end)
      form_editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(form_editor) end)

      calls = [
        fn opts -> Document.open(@valid_pdf, opts) end,
        fn opts -> Document.text(doc, opts) end,
        fn opts -> Document.text(doc, 0, opts) end,
        fn opts -> Document.to_markdown(doc, opts) end,
        fn opts -> Document.to_html(doc, opts) end,
        fn opts -> Document.to_plain_text(doc, opts) end,
        fn opts -> Document.words(doc, 0, opts) end,
        fn opts -> Document.text_lines(doc, 0, opts) end,
        fn opts -> Document.chars(doc, 0, opts) end,
        fn opts -> Document.spans(doc, 0, opts) end,
        fn opts -> Document.structured(doc, 0, opts) end,
        fn opts -> Document.running_regions(doc, opts) end,
        fn opts -> Document.tables(doc, 0, opts) end,
        fn opts -> Document.inks(doc, 0, opts) end,
        fn opts -> Document.bookmark_segments(doc, opts) end,
        fn opts -> Document.render(doc, 0, opts) end,
        fn opts -> Document.separations(doc, 0, opts) end,
        fn opts -> Document.separation(doc, 0, "Cyan", opts) end,
        fn opts -> Document.rasterize(doc, opts) end,
        fn opts -> Document.to_docx(doc, opts) end,
        fn opts -> Document.to_pptx(doc, opts) end,
        fn opts -> Document.to_xlsx(doc, opts) end,
        fn opts -> Document.search(doc, "Page", opts) end,
        fn opts -> Document.search(doc, "Page", 0, opts) end,
        fn opts -> Document.text(doc, 0, table_detection: opts) end,
        fn opts -> Document.spans(doc, 0, span_merging: opts) end,
        fn opts -> Document.spans(doc, 0, span_merging: [adaptive: opts]) end,
        fn opts -> Editor.to_binary(editor, opts) end,
        fn opts -> Editor.save(editor, "/dev/null", opts) end,
        fn opts -> Editor.to_binary(editor, encryption: opts) end,
        fn opts -> Editor.to_binary(editor, encryption: [permissions: opts]) end,
        fn opts -> Document.Table.to_markdown(table, opts) end,
        fn opts -> Document.Image.to_binary(image, opts) end,
        fn opts -> Document.Image.save(image, "out.png", opts) end,
        fn opts -> Form.export(form_doc, :fdf, opts) end,
        fn opts -> Form.export(form_editor, :xfdf, opts) end,
        fn opts -> Editor.embed_file(editor, "data.csv", "a,b", opts) end,
        fn opts -> Editor.crop_margins(editor, opts) end,
        fn opts -> Editor.apply_redactions(editor, opts) end,
        fn opts -> Editor.sanitize(editor, opts) end,
        fn opts -> Compliance.convert(editor, :pdf_a_2b, opts) end,
        fn opts -> Editor.bookmark_segments(editor, opts) end,
        fn opts -> Editor.split_by_bookmarks(editor, opts) end,
        fn opts -> Editor.from_markdown("Text", opts) end,
        fn opts -> Editor.from_html("Text", opts) end,
        fn opts -> Editor.from_plain_text("Text", opts) end,
        fn opts -> Editor.from_images([PdfElixide.Png.solid(8, 8, :rgb)], opts) end,
        fn opts -> Builder.new(opts) end,
        fn opts -> Builder.paragraph(Builder.new(), "Text", opts) end,
        fn opts -> Builder.to_binary(Builder.new(), opts) end,
        fn opts -> Builder.save(Builder.new(), "/dev/null", opts) end,
        fn opts -> Builder.paragraph(Builder.new(), [{"Text", opts}]) end,
        fn opts -> Builder.heading(Builder.new(), 1, "Text", opts) end,
        fn opts -> Builder.text_at(Builder.new(), {72, 72}, "Text", opts) end,
        fn opts ->
          Builder.text_in_rect(
            Builder.new(),
            %PdfElixide.Geometry.Rect{x: 72, y: 72, width: 100, height: 100},
            "Text",
            opts
          )
        end,
        fn opts -> Builder.table(Builder.new(), [["Text"]], opts) end,
        fn opts -> Builder.cell("Text", opts) end,
        fn opts -> Builder.bullet_list(Builder.new(), ["Text"], opts) end,
        fn opts -> Builder.numbered_list(Builder.new(), ["Text"], opts) end,
        fn opts -> Builder.FontFamily.new([regular: "a"] ++ opts) end,
        fn opts ->
          Builder.rect(
            Builder.new(),
            %PdfElixide.Geometry.Rect{x: 0, y: 0, width: 1, height: 1},
            opts
          )
        end,
        fn opts -> Builder.line(Builder.new(), {0, 0}, {1, 1}, opts) end,
        fn opts -> Builder.circle(Builder.new(), {0, 0}, 1, opts) end,
        fn opts -> Builder.ellipse(Builder.new(), {0, 0}, {1, 1}, opts) end,
        fn opts -> Builder.polygon(Builder.new(), [{0, 0}, {1, 0}, {0, 1}], opts) end,
        fn opts -> Builder.arc(Builder.new(), {0, 0}, 1, 0, 90, opts) end,
        fn opts -> Builder.bezier(Builder.new(), {0, 0}, {1, 1}, {2, 1}, {3, 0}, opts) end,
        fn opts -> Builder.path(Builder.new(), [{:move_to, 0, 0}], opts) end,
        fn opts -> Builder.text_field(Builder.new(), "f", field_rect(), opts) end,
        fn opts -> Builder.check_box(Builder.new(), "f", field_rect(), opts) end,
        fn opts -> Builder.combo_box(Builder.new(), "f", field_rect(), ["a"], opts) end,
        fn opts -> Builder.list_box(Builder.new(), "f", field_rect(), ["a"], opts) end,
        fn opts -> Builder.push_button(Builder.new(), "f", field_rect(), "Go", opts) end,
        fn opts -> Builder.signature_field(Builder.new(), "f", field_rect(), opts) end
      ]

      for call <- calls do
        assert_raise ArgumentError, ~r/:no_such_option/, fn ->
          call.(no_such_option: true)
        end
      end
    end
  end

  describe "an option its call does not read is rejected" do
    test "one page's text takes no :on_page_error" do
      doc = doc()
      page = Document.page!(doc, 0)

      for call <- [
            fn -> Document.text(doc, 0, on_page_error: :halt) end,
            fn -> Document.text!(doc, 0, on_page_error: :skip) end,
            fn -> Document.Page.text(page, on_page_error: :halt) end
          ] do
        assert_raise ArgumentError, ~r/:on_page_error/, call
      end
    end

    test "to_markdown/2,3 takes no :expand_ligatures" do
      doc = doc()

      assert_raise ArgumentError, ~r/:expand_ligatures/, fn ->
        Document.to_markdown(doc, expand_ligatures: true)
      end

      assert_raise ArgumentError, ~r/:expand_ligatures/, fn ->
        Document.to_markdown(doc, 0, expand_ligatures: false)
      end
    end

    test "the text paths' :table_detection takes no :text_fallback" do
      doc = doc()

      for call <- [
            &Document.text(doc, &1),
            &Document.text(doc, 0, &1),
            &Document.to_plain_text(doc, &1),
            &Document.to_plain_text(doc, 0, &1)
          ],
          value <- [true, false] do
        assert_raise ArgumentError, ~r/:text_fallback/, fn ->
          call.(table_detection: [text_fallback: value])
        end
      end
    end

    test "Editor.apply_redactions/2 takes no sanitize, layer or artifact key" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      for {key, value} <- @non_redaction_opts do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn ->
          Editor.apply_redactions(editor, [{key, value}])
        end
      end
    end

    test "Editor.sanitize/2 takes no geometric key" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      for {key, value} <- @redaction_opts do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn ->
          Editor.sanitize(editor, [{key, value}])
        end
      end
    end

    test "Editor.from_plain_text/2 takes no :subject or :font_size" do
      for {key, value} <- @create_opts -- @plain_text_create_opts do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn ->
          Editor.from_plain_text("Text", [{key, value}])
        end
      end
    end

    test "Builder.to_binary/2 and save/3 take no :incremental" do
      assert_raise ArgumentError, ~r/:incremental/, fn ->
        Builder.to_binary(Builder.new(), incremental: false)
      end

      assert_raise ArgumentError, ~r/:incremental/, fn ->
        Builder.save(Builder.new(), "/dev/null", incremental: false)
      end
    end

    test "Editor.from_images/2 takes no :font_size or :line_height" do
      for {key, value} <- Keyword.drop(@create_opts, Keyword.keys(@image_create_opts)) do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn ->
          Editor.from_images([PdfElixide.Png.solid(8, 8, :rgb)], [{key, value}])
        end
      end
    end
  end

  describe "a duplicated key is rejected" do
    test "rather than resolved to the first occurrence" do
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
