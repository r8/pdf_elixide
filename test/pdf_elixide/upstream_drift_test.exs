defmodule PdfElixide.UpstreamDriftTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @moduletag :upstream_drift

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form
  alias PdfElixide.Signature

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @metadata_encodings_pdf Path.join(@fixtures, "metadata_encodings.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  @image_jpx_pdf Path.join(@fixtures, "image_jpx.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @html_escaping_pdf Path.join(@fixtures, "html_escaping.pdf")
  @actualtext_pdf Path.join(@fixtures, "actualtext.pdf")
  @rotation_pdf Path.join(@fixtures, "rotation.pdf")
  @inherited_boxes_pdf Path.join(@fixtures, "inherited_boxes.pdf")
  @layers_and_inks_pdf Path.join(@fixtures, "layers_and_inks.pdf")
  @vector_shapes_pdf Path.join(@fixtures, "vector_shapes.pdf")
  @tagged_pdf Path.join(@fixtures, "tagged.pdf")
  @markdown_pdf Path.join(@fixtures, "markdown.pdf")
  @search_pdf Path.join(@fixtures, "search.pdf")
  @no_pages_pdf Path.join(@fixtures, "no_pages.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @button_states_pdf Path.join(@fixtures, "form_button_states.pdf")
  @signature_pdf Path.join(@fixtures, "form_signature.pdf")
  @pades_lta_pdf Path.join(@fixtures, "form_signature_pades_lta.pdf")
  @ecdsa_p521_pdf Path.join(@fixtures, "form_signature_ecdsa_p521.pdf")
  @flatten_pdf Path.join(@fixtures, "flatten.pdf")
  @sample_pdf Path.join(@fixtures, "sample.pdf")

  @columns 0
  @artifacts 1
  @ruleless 3
  @kerned 4

  # In @broken_page_pdf: /Count says three pages, two page objects exist.
  @unreachable 2

  # In @image_jpx_pdf: a JPEG 2000 codestream carrying RGB plus alpha, whose
  # page declares /ColorSpace /DeviceRGB and /SMaskInData 1.
  @rgb_with_alpha 2

  # In @layers_and_inks_pdf: DeviceN plus /All and /None on one page, a tiling
  # pattern and an annotation appearance stream on another.
  @device_n 1
  @patterns 2

  # In @vector_shapes_pdf: one page per branch family of upstream's rectangle
  # and straight-line classification.
  @accepted_rects 0
  @accepted_lines 1
  @near_misses 2
  @surprises 3
  @fill_stroke 4

  # In @rotation_pdf, by /Rotate: 90 on the leaf, 180 inherited from an
  # intermediate /Pages node, -90 (reads as 270), 45 (invalid, reads as 0).
  @rotate_90 0
  @rotate_180 1
  @rotate_0 3

  defp open(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp texts(items), do: Enum.map(items, & &1.text)

  defp origin(%{bbox: %{x: x, y: y}}), do: {x, y}
  defp origins(items), do: Enum.map(items, &origin/1)

  describe "deprecated word and line knobs" do
    setup do: %{doc: open(@extraction_pdf)}

    test ":profile still routes to the legacy span path", %{doc: doc} do
      assert texts(Document.words!(doc, @columns, profile: :conservative)) !=
               texts(Document.words!(doc, @columns))
    end

    test "every profile name still resolves", %{doc: doc} do
      profiles = [
        :conservative,
        :tj_heavy,
        :aggressive,
        :balanced,
        :academic,
        :policy,
        :form,
        :government,
        :scanned_ocr,
        :adaptive
      ]

      for profile <- profiles do
        assert is_list(Document.words!(doc, @columns, profile: profile))
      end
    end

    test ":word_gap_threshold still decides word boundaries", %{doc: doc} do
      default = Document.words!(doc, @ruleless)
      merged = Document.words!(doc, @ruleless, word_gap_threshold: 200.0)

      assert length(merged) < length(default)
    end

    test ":line_gap_threshold still decides line grouping", %{doc: doc} do
      default = Document.text_lines!(doc, @ruleless)
      merged = Document.text_lines!(doc, @ruleless, line_gap_threshold: 100.0)

      assert length(merged) < length(default)
    end

    test ":include_artifacts still filters, and still defaults to keeping them", %{doc: doc} do
      assert "Running" in texts(Document.words!(doc, @artifacts))
      refute "Running" in texts(Document.words!(doc, @artifacts, include_artifacts: false))
    end
  end

  describe "documented routing drops" do
    setup do: %{doc: open(@table_pdf)}

    test "layer/ink filtering still discards the sibling text options", %{doc: doc} do
      plain = Document.text!(doc, 0)
      without_tables = Document.text!(doc, 0, extract_tables: false)
      filtered = Document.text!(doc, 0, exclude_layers: ["NoSuchLayer"], extract_tables: false)

      # Precondition: the option does something when it is not being dropped.
      assert without_tables != plain

      assert filtered == plain
    end

    test ":span_merging still discards :reading_order", %{doc: doc} do
      merging = [merge_tm_tj_runs: false]

      assert texts(Document.spans!(doc, 0, span_merging: merging)) ==
               texts(Document.spans!(doc, 0, span_merging: merging, reading_order: :column_aware))
    end
  end

  describe "table detection asymmetries" do
    setup do: %{doc: open(@extraction_pdf)}

    test "the text path still forces text_fallback off", %{doc: doc} do
      assert length(Document.tables!(doc, @ruleless)) == 1

      assert Document.text!(doc, @ruleless) =~ "RegionUnitsTotal"

      assert Document.text!(doc, @ruleless, table_detection: [text_fallback: true]) ==
               Document.text!(doc, @ruleless)
    end

    test "a region query still does not silently relax the config", %{doc: doc} do
      [table] = Document.tables!(doc, @ruleless)

      # Upstream's `extract_tables_in_rect` substitutes
      # `TableDetectionConfig::relaxed()`; this binding passes the caller's
      # config through, matching what the Python bindings do. A `:strict`
      # preset must therefore still reject inside a region.
      assert Document.tables!(doc, @ruleless, region: table.bbox, preset: :strict) == []
      assert length(Document.tables!(doc, @ruleless, region: table.bbox)) == 1
    end
  end

  describe "span merging" do
    setup do: %{doc: open(@extraction_pdf)}

    test "a gap threshold still reaches the span merger", %{doc: doc} do
      # `SpanMergingConfig` is the one upstream type this binding exposes that
      # no other binding does, so nothing else would notice it going inert.
      # The gap fields only govern gaps *inside* one text run, which is why
      # this uses the TJ-kerned page rather than the Tm-placed ones.
      assert texts(Document.spans!(doc, @kerned, span_merging: [])) !=
               texts(
                 Document.spans!(doc, @kerned,
                   span_merging: [column_boundary_threshold_pt: 500.0]
                 )
               )
    end

    test "every preset name still resolves", %{doc: doc} do
      for preset <- [:default, :aggressive, :conservative, :adaptive, :legacy] do
        assert is_list(Document.spans!(doc, @kerned, span_merging: [preset: preset]))
      end
    end

    test "an adaptive sub-config is still accepted with its documented default", %{doc: doc} do
      # `AdaptiveThresholdConfig`'s doc comment says `max_threshold_pt`
      # defaults to 1.0pt while its `Default` impl sets 100.0 — a live
      # mismatch upstream could resolve in either direction. Passing both the
      # documented and the actual value must keep working either way.
      for max <- [1.0, 100.0] do
        assert is_list(
                 Document.spans!(doc, @kerned,
                   span_merging: [preset: :adaptive, adaptive: [max_threshold_pt: max]]
                 )
               )
      end
    end
  end

  describe "absolutely-positioned cells fuse into one token" do
    setup do: %{doc: open(@table_pdf)}

    # `table.pdf` draws three horizontal rules, so its table *is* recognised —
    # which is the only reason the two `:extract_tables` cases below differ.

    test "text/1 joins a row's cells with no separator", %{doc: doc} do
      assert Document.text!(doc, 0) =~ "Age0.0420.0110.001"
    end

    test "without table rendering the fused form is the only one", %{doc: doc} do
      text = Document.text!(doc, 0, extract_tables: false)

      assert text =~ "Age0.0420.0110.001"
      # Absent, not merely joined differently — that is what "unreachable" means.
      refute text =~ ~r/\b0\.042\b/
    end

    test "table rendering adds a separated copy without removing the fused one",
         %{doc: doc} do
      text = Document.text!(doc, 0)

      assert text =~ ~r/\b0\.042\b/
      assert text =~ "Age0.0420.0110.001"
    end

    test "words/2 keeps every cell separate", %{doc: doc} do
      words = texts(Document.words!(doc, 0))

      for cell <- ["Age", "0.042", "0.011", "0.001"] do
        assert cell in words
      end
    end

    test "the fusion is upstream of assembly, and its own flag still undoes it", %{doc: doc} do
      assert "Age0.0420.0110.001" in texts(Document.spans!(doc, 0))

      assert "Age" in texts(Document.spans!(doc, 0, span_merging: [merge_tm_tj_runs: false]))
    end
  end

  describe "whole-document text on a page that fails" do
    test "a failed page still costs only its own slot" do
      doc = open(@broken_page_pdf)

      # Without this precondition, a repaired fixture makes the assertion vacuous.
      assert {:error, _} = Document.text(doc, @unreachable)

      assert String.split(Document.text!(doc), "\f") == ["One", "Two", ""]
    end

    test "fonts tolerate the same page, alone among the other extractors" do
      doc = open(@broken_page_pdf)

      # Keep the page unresolvable so the tolerance checks below are meaningful.
      assert {:error, %Error{reason: :invalid_pdf}} = Document.text(doc, @unreachable)

      assert {:ok, []} = Document.fonts(doc, @unreachable)

      assert [0, 1] = doc |> Document.fonts!() |> Enum.map(& &1.page)
      assert {:error, %Error{}} = Document.chars(doc)
      assert {:error, %Error{}} = Document.images(doc)
    end
  end

  describe "the two plain-text assemblers" do
    test "a trustworthy structure tree still collapses them into one" do
      doc = open(@tagged_pdf)

      for page <- 0..(Document.page_count!(doc) - 1) do
        assert Document.to_plain_text!(doc, page) == Document.text!(doc, page)
      end
    end

    test "an untagged page still assembles differently on each" do
      doc = open(@markdown_pdf)

      # The negative control: without it the equality above could hold because
      # the two calls had become one, rather than because the fixture is tagged.
      assert Document.text!(doc, 0) =~ "Markdown Fixture\nBody paragraph text."
      assert Document.to_plain_text!(doc, 0) =~ "Markdown Fixture Body paragraph text."
    end
  end

  describe "PDF text-string decoding" do
    test "a BOM-less buffer that is valid UTF-8 still decodes as UTF-8" do
      doc = open(@metadata_encodings_pdf)

      # The bytes decode to "Créateur" as UTF-8 and "CrÃ©ateur" otherwise.
      assert Document.metadata!(doc).creator == "Créateur"
    end
  end

  describe "a wrong password is not an upstream error" do
    test "authenticate reports it as {:ok, false}, and open/2 synthesizes the atom" do
      doc = open(@encrypted_pdf)

      assert {:ok, false} = Document.authenticate(doc, "wrong")

      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@encrypted_pdf, password: "wrong")
    end
  end

  describe "has_text_layer on a document that cannot be decrypted" do
    test "answers true where text/1 answers empty" do
      doc = open(@encrypted_pdf)

      assert {:ok, true} = Page.has_text_layer(Document.page!(doc, 0))
      assert {:ok, ""} = Document.text(doc, 0)
    end

    test "answers true once authenticated too, for the ordinary reason" do
      doc = Document.open!(@encrypted_pdf, password: "secret")

      assert {:ok, true} = Page.has_text_layer(Document.page!(doc, 0))
      assert {:ok, text} = Document.text(doc, 0)
      assert String.trim(text) != ""
    end
  end

  describe "HTML output escaping" do
    setup do: %{doc: open(@html_escaping_pdf)}

    test "text taken from the PDF is escaped in both output modes", %{doc: doc} do
      escaped = "&lt;script&gt;alert(&quot;x&quot;) &amp; 'y'&lt;/script&gt;"

      assert {:ok, html} = Document.to_html(doc)
      assert html =~ escaped
      refute html =~ "<script>"

      assert {:ok, positioned} = Document.to_html(doc, preserve_layout: true)
      assert positioned =~ escaped
      refute positioned =~ "<script>"

      # Escaping is the converters' job, not the extractor's: plain text comes
      # back verbatim.
      assert Document.text!(doc) =~ "<script>alert(\"x\") & 'y'</script>"
    end

    test "a /Link URI is escaped and the anchor is rel-hardened", %{doc: doc} do
      # The fixture's link target carries both `&` and `"`, either of which
      # would break out of the href attribute unescaped.
      assert {:ok, html} = Document.to_html(doc)

      assert html =~
               ~s(<a href="https://example.com/?a=1&amp;b=2&quot;x" rel="noopener noreferrer">Safe link</a>)
    end

    test "a javascript: /Link is dropped, keeping its text", %{doc: doc} do
      assert {:ok, html} = Document.to_html(doc)

      refute html =~ "javascript:"
      assert html =~ "Bad link"
      refute html =~ ~s(<a href="javascript)
    end
  end

  describe "competing /ActualText scopes" do
    test "a repeat span extraction of one page loses MC-scope precedence" do
      doc = open(@actualtext_pdf)

      assert texts(Document.spans!(doc, 0)) == ["INLINE"]
      assert texts(Document.spans!(doc, 0)) == ["ANCESTOR"]
    end

    test "an earlier span extraction changes a later text extraction" do
      untouched = open(@actualtext_pdf)
      assert Document.text!(untouched, 0) == "INLINE"
      assert Document.text!(untouched, 0) == "INLINE"

      poisoned = open(@actualtext_pdf)
      assert texts(Document.spans!(poisoned, 0)) == ["INLINE"]
      assert Document.text!(poisoned, 0) == "ANCESTOR"
    end
  end

  describe "which frame a rotated page's boxes are in" do
    setup do: %{doc: open(@rotation_pdf)}

    test "an unrotated page reports one frame", %{doc: doc} do
      assert [span] = Document.spans!(doc, @rotate_0)
      assert origins(Document.words!(doc, @rotate_0)) |> hd() == origin(span)
      assert origins(Document.text_lines!(doc, @rotate_0)) == [origin(span)]
      assert Document.chars!(doc, @rotate_0) |> hd() |> origin() == origin(span)
    end

    test "a 90-degree page leaves horizontal content raw", %{doc: doc} do
      assert [span] = Document.spans!(doc, @rotate_90)
      assert origins(Document.words!(doc, @rotate_90)) |> hd() == origin(span)
      assert origins(Document.text_lines!(doc, @rotate_90)) == [origin(span)]
    end

    test "a 180-degree page mirrors words and lines but not spans or chars",
         %{doc: doc} do
      # The page is 612 x 792 and the text is drawn at (72, 720) with a height
      # of 24, so the mirrored origin is (612 - 72 - width, 792 - 720 - 24).
      # The x is compared with a delta because the mirror is computed in f32
      # upstream and the expectation here in f64.
      assert [%{bbox: %{x: 72.0, y: 720.0, width: width}} = span] =
               Document.spans!(doc, @rotate_180)

      assert Document.chars!(doc, @rotate_180) |> hd() |> origin() == {72.0, 720.0}

      mirrored_x = 612.0 - 72.0 - width

      assert [{line_x, 48.0}] = origins(Document.text_lines!(doc, @rotate_180))
      assert_in_delta line_x, mirrored_x, 0.001

      assert [{first_word_x, 48.0} | _] = origins(Document.words!(doc, @rotate_180))
      assert_in_delta first_word_x, mirrored_x, 0.001

      # Said plainly: the same line, two frames.
      refute origins(Document.text_lines!(doc, @rotate_180)) == [origin(span)]
    end

    test "a search match is mapped, like words, and unlike the span it sits in",
         %{doc: doc} do
      assert [%{bbox: %{x: 72.0, y: 720.0}} = span] = Document.spans!(doc, @rotate_180)
      assert [match] = Document.search!(doc, span.text, @rotate_180)

      assert origin(match) == origins(Document.words!(doc, @rotate_180)) |> hd()
      refute origin(match) == origin(span)

      # The control: on the 90-degree page nothing is mapped, so search agrees
      # with `spans` again.
      assert [span_90] = Document.spans!(doc, @rotate_90)
      assert [match_90] = Document.search!(doc, span_90.text, @rotate_90)
      assert origin(match_90) == origin(span_90)
    end
  end

  describe "text search" do
    setup do: %{doc: open(@search_pdf)}

    test "a match's boxes cover whole spans, not the matched characters",
         %{doc: doc} do
      # `compute_match_bbox` (`src/search/text_search.rs`) selects spans by byte
      # overlap and takes each one's whole `bbox`; upstream carries
      # `char_widths` and `char_x_offsets` on the span and never consults them.
      # So a one-word match inside a long line reports the whole line's box.
      assert [span] = Document.spans!(doc, 0) |> Enum.filter(&(&1.text =~ "Widgets"))
      assert [match] = Document.search!(doc, "Widgets")

      assert match.span_boxes == [span.bbox]
      assert match.bbox == span.bbox
      assert span.bbox.width > 200.0
    end

    test "spans are joined with a space, so a match can cross a line",
         %{doc: doc} do
      # `build_text_with_positions` concatenates a page's spans into one string,
      # pushing a `' '` after any span not already ending in one — no newline
      # anywhere. "Quarterly" and "Report" are on separate lines and still match
      # as one phrase.
      assert [match] = Document.search!(doc, "Quarterly Report")
      assert [%{y: 640.0}, %{y: 600.0}] = match.span_boxes
    end

    test "matches are leftmost-first and non-overlapping", %{doc: doc} do
      # `find_iter` semantics: "aa" occurs twice in "aaa" by inspection, but the
      # second overlaps the first and is never reported.
      assert length(Document.search!(doc, "aa")) == 1
    end

    test "whole_word wraps the pattern without grouping it", %{doc: doc} do
      # `build_regex` builds `\b{pattern}\b`, not `\b(?:{pattern})\b`, so an
      # alternation binds as `(\bcat)|(Report\b)`. A correctly grouped pattern
      # would match "cat" and "Report" only; the leading `\b` alone also admits
      # "category". This is the whole reason `:literal` defaults to `true`
      # here — `regex::escape` makes the trap unreachable on the default path.
      matched = Document.search!(doc, "cat|Report", literal: false, whole_word: true)

      assert Enum.map(matched, & &1.text) == ["Report", "cat", "cat"]
      assert length(Document.search!(doc, "cat|Report", literal: false)) == 4
    end

    test "an unparseable pattern arrives as InvalidPdf with a known prefix",
         %{doc: doc} do
      assert {:error, %Error{reason: :invalid_pattern, message: message}} =
               Document.search(doc, "(", literal: false)

      assert message =~ "Invalid regex pattern: "
    end
  end

  describe "searching a document with no pages" do
    test "an inverted page range visits no page" do
      assert {:ok, []} = Document.search(open(@no_pages_pdf), "x")
    end
  end

  describe "inherited page boxes" do
    test "the outermost ancestor wins on the per-page traversal" do
      page = Document.page!(open(@inherited_boxes_pdf), 0)

      assert %{width: 200.0, height: 100.0} = Page.media_box!(page)
      assert Page.rotation!(page) == 90
    end

    test "the nearest ancestor wins once the bulk page-tree walk takes over" do
      doc = open(@inherited_boxes_pdf)

      # Page 0 must remain unread while the other pages trigger the bulk walk.
      for i <- 1..70, do: Page.media_box!(Document.page!(doc, i))

      page = Document.page!(doc, 0)
      assert %{width: 300.0, height: 500.0} = Page.media_box!(page)
      assert Page.rotation!(page) == 180
    end
  end

  describe "inks the deep walk deliberately skips" do
    test "a /Pattern colour space's underlying Separation is surfaced" do
      doc = open(@layers_and_inks_pdf)
      assert Document.inks!(doc, @patterns, deep: true) == ["UnderlyingInk"]
    end

    test "a pattern object's and an annotation appearance's own inks are not" do
      doc = open(@layers_and_inks_pdf)
      deep = Document.inks!(doc, @patterns, deep: true)

      refute "PatternInk" in deep
      refute "AnnotInk" in deep
    end

    test "/All and /None are never listed as colorants" do
      doc = open(@layers_and_inks_pdf)
      inks = Document.inks!(doc, @device_n)

      assert inks == ["SpotA", "SpotB"]
      refute "All" in inks
      refute "None" in inks
    end
  end

  describe "how upstream classifies a rectangle and a straight line" do
    test "the accepting shapes are the re operator and a three-segment polyline" do
      doc = open(@vector_shapes_pdf)
      rects = Document.rects!(doc, @accepted_rects)

      assert Enum.map(rects, & &1.operations) == [
               [{:rectangle, 50.0, 700.0, 100.0, 40.0}],
               [
                 {:move_to, 50.0, 600.0},
                 {:line_to, 150.0, 600.0},
                 {:line_to, 150.0, 640.0},
                 {:line_to, 50.0, 640.0},
                 :close_path
               ],
               [
                 {:move_to, 50.0, 500.0},
                 {:line_to, 150.0, 500.0},
                 {:line_to, 150.0, 540.0},
                 {:line_to, 50.0, 540.0}
               ]
             ]
    end

    test "a line closed with the s operator is still a straight line" do
      doc = open(@vector_shapes_pdf)

      assert Enum.map(Document.lines!(doc, @accepted_lines), & &1.operations) == [
               [{:move_to, 100.0, 700.0}, {:line_to, 300.0, 700.0}],
               [{:move_to, 100.0, 650.0}, {:line_to, 300.0, 650.0}, :close_path]
             ]
    end

    test "a rectangle drawn back to its starting corner is classified as neither" do
      doc = open(@vector_shapes_pdf)

      assert length(Document.paths!(doc, @near_misses)) == 2
      assert Document.rects!(doc, @near_misses) == []
      assert Document.lines!(doc, @near_misses) == []
    end

    test "four collinear points and a zero-area box are both rectangles" do
      doc = open(@vector_shapes_pdf)
      rects = Document.rects!(doc, @surprises)

      assert Enum.map(rects, &{&1.bbox.width, &1.bbox.height}) == [{0.0, 0.0}, {300.0, 0.0}]
    end

    test "a fill-and-stroke path is dropped and takes the next path with it" do
      doc = open(@vector_shapes_pdf)

      # `B` is never painted into a path of its own, and its operations are
      # prepended to the next one — so the stroked line that follows is
      # three operations long and classifies as nothing.
      assert [path] = Document.paths!(doc, @fill_stroke)

      assert path.operations == [
               {:rectangle, 50.0, 100.0, 60.0, 60.0},
               {:move_to, 200.0, 100.0},
               {:line_to, 400.0, 100.0}
             ]

      assert Document.rects!(doc, @fill_stroke) == []
      assert Document.lines!(doc, @fill_stroke) == []
    end

    test "the two sets are disjoint subsets of paths" do
      for fixture <- [@vector_shapes_pdf, @table_pdf] do
        doc = open(fixture)
        paths = Document.paths!(doc)
        rects = Document.rects!(doc)
        lines = Document.lines!(doc)

        assert rects -- paths == []
        assert lines -- paths == []
        assert rects -- lines == rects
        assert length(rects) + length(lines) <= length(paths)
      end
    end
  end

  describe "which writes clear the editor's modified flag" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "pdf_elixide_drift_#{System.unique_integer([:positive])}.pdf"
        )

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    defp edited_editor do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)
      Form.put_value!(editor, "full_name", "Ada")
      assert Editor.modified?(editor)
      editor
    end

    test "a full rewrite clears it, whether it lands in a file or in bytes", %{
      out_path: out_path
    } do
      to_file = edited_editor()
      Editor.save!(to_file, out_path)
      refute Editor.modified?(to_file)

      to_bytes = edited_editor()
      {:ok, _bytes} = Editor.to_binary(to_bytes)
      refute Editor.modified?(to_bytes)
    end

    test "an incremental save does not", %{out_path: out_path} do
      editor = edited_editor()

      Editor.save!(editor, out_path, incremental: true)

      assert Editor.modified?(editor)
    end
  end

  describe "what a deleted page leaves in the saved file" do
    # Compression would make the orphaned content stream impossible to grep.
    test "the page is gone from the tree and its bytes are still in the file" do
      editor = Editor.open!(@sample_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)
      bytes = Editor.to_binary!(editor, compress: false, garbage_collect: true)

      doc = Document.from_binary!(bytes)
      on_exit(fn -> Document.close(doc) end)

      assert Document.page_count!(doc) == 2
      refute doc |> Enum.map_join(&Page.text!/1) |> String.contains?("Page Two")

      assert String.contains?(bytes, "Page Two"),
             "the deleted page's content stream was dropped, so deletion now redacts"
    end

    test "a document emptied of pages reopens claiming it still has them" do
      editor = Editor.open!(@sample_pdf)
      on_exit(fn -> Editor.close(editor) end)

      for _ <- 1..3, do: Editor.delete_page!(editor, 0)
      assert Editor.page_count!(editor) == 0

      doc = Document.from_binary!(Editor.to_binary!(editor))
      on_exit(fn -> Document.close(doc) end)

      assert Document.page_count!(doc) == 3
    end
  end

  describe "what an incremental save carries out of the editor" do
    @tag :tmp_dir
    test "a page deletion and a move both go missing", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@sample_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(tmp_dir, "incremental_pages.pdf")

      editor |> Editor.delete_page!(1) |> Editor.move_page!(1, 0)
      assert Editor.page_count!(editor) == 2

      Editor.save!(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert Document.page_count!(doc) == 3

      assert doc |> Enum.map(&Page.text!/1) |> Enum.map(&String.trim/1) ==
               ["Page One", "Page Two", "Page Three"]
    end

    @tag :tmp_dir
    test "an embedded file goes missing too", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@sample_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(tmp_dir, "incremental_attachment.pdf")

      Editor.embed_file!(editor, "data.csv", "a,b\n")

      Editor.save!(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert Document.embedded_files!(doc) == [],
             "upstream now writes pending attachments into an incremental update"
    end

    @tag :tmp_dir
    test "a page rotation goes missing too", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(tmp_dir, "incremental_rotation.pdf")

      Editor.rotate_all_by!(editor, 90)
      assert Editor.rotation!(editor, @rotate_90) == 180

      Editor.save!(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert Enum.map(doc, &Page.rotation!/1) == [90, 180, 270, 0],
             "upstream now carries page properties into an incremental update"
    end
  end

  describe "how upstream reports an unknown form field" do
    test "an unknown name is an InvalidPdf carrying a known prefix" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :not_found, message: message}} =
               Form.put_value(editor, "no_such_field", "x")

      assert message =~ "Form field not found: "
    end

    test "the read side reports the same reason" do
      doc = Document.open!(@form_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert {:error, %Error{reason: :not_found}} = Form.field(doc, "no_such_field")
    end
  end

  describe "what upstream does to a field's value on write" do
    test "a /Sig field is still classified as one, so it stays out of fields/1" do
      doc = Document.open!(@signature_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert {:ok, [%PdfElixide.Form.Field.Text{name: "signer_name"}]} = Form.fields(doc)
    end

    test "clearing a field writes a PDF null over its value" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", nil)

      assert Editor.to_binary!(editor, compress: false) =~ "/V null"
    end

    # `/V` is copied verbatim into `/AS`, where §12.5.5 requires a name.
    test "a bare string on a button is copied into /AS as a string" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "subscribe", "Export1")

      assert Editor.to_binary!(editor, compress: false) =~ "/AS (Export1)"
    end
  end

  describe "how a form-data export encodes a value outside ASCII" do
    test "FDF writes it as raw UTF-8 inside a PDF literal string" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", "Café")
      fdf = Form.export!(editor, :fdf)

      # `(Caf` + the UTF-8 encoding of é + `)`. A conforming reader decodes a
      # literal string as PDFDocEncoded, so those two bytes render as `Ã©`.
      assert fdf =~ <<0x28, "Caf", 0xC3, 0xA9, 0x29>>
      refute fdf =~ <<0xE9>>
      refute fdf =~ "FEFF"
    end

    test "the same value written into the PDF itself is encoded conformantly" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", "Café")

      # PDFDocEncoded as a hex string, `43 61 66 E9` — not raw UTF-8.
      assert Editor.to_binary!(editor, compress: false) =~ "/V <436166E9>"
    end

    test "a value with no Latin-1 spelling takes the UTF-16BE branch on save" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", "Привет")

      assert Editor.to_binary!(editor, compress: false) =~ "/V <FEFF041F"
      assert Form.export!(editor, :fdf) =~ <<0xD0, 0x9F>>
    end

    test "XFDF carries it correctly, being UTF-8 XML" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", "Café")

      assert Form.export!(editor, :xfdf) =~ "<value>Café</value>"
    end
  end

  describe "how a check box on-state survives a read and an export" do
    test "an /On box and a /Yes box are the same value once read" do
      doc = Document.open!(@button_states_pdf)
      on_exit(fn -> Document.close(doc) end)

      values = Form.fields!(doc) |> Map.new(&{&1.name, &1.value})

      # The pair is the point: nothing in either struct says which name the file
      # spells, so no caller can compensate.
      assert values["on"] == true
      assert values["yes"] == true
      assert values["no"] == false

      assert values["custom"] == "Export1"
    end

    test "an /On box exports as the /Yes it is not" do
      doc = Document.open!(@button_states_pdf)
      on_exit(fn -> Document.close(doc) end)

      fdf = Form.export!(doc, :fdf)

      assert fdf =~ "/T (on) /V /Yes"
      assert fdf =~ "/T (yes) /V /Yes"

      assert fdf =~ "/T (no) /V /Off"
      assert fdf =~ "/T (custom) /V /Export1"
    end

    test "XFDF loses it the same way" do
      doc = Document.open!(@button_states_pdf)
      on_exit(fn -> Document.close(doc) end)

      xfdf = Form.export!(doc, :xfdf)

      assert xfdf =~ ~s(<field name="on">\n      <value>Yes</value>)
      assert xfdf =~ ~s(<field name="custom">\n      <value>Export1</value>)
    end
  end

  describe "how an archival timestamp is found" do
    test "the archival timestamp it finds is not one the listing reports" do
      doc = Document.open!(@pades_lta_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert [signature] = Signature.list!(doc)
      assert signature.sub_filter == :cades_detached
      assert Signature.document_timestamp?(File.read!(@pades_lta_pdf))
    end
  end

  describe "which signature algorithms upstream verifies" do
    # P-521/SHA-512 enters upstream's ECDSA dispatch but has no curve verifier.
    test "a curve it has no verifier for is unknown rather than invalid" do
      doc = Document.open!(@ecdsa_p521_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert [signature] = Signature.list!(doc)
      assert Signature.verify(signature, File.read!(@ecdsa_p521_pdf)) == {:ok, :unknown}
      assert Signature.verify_signer(signature) == {:ok, :unknown}
    end
  end

  describe "flattening" do
    # Only the whole-document path removes the AcroForm.
    test "the whole-document flatten drops the AcroForm, the per-page one rebuilds it" do
      whole = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(whole) end)

      {:ok, doc} =
        whole |> Form.flatten!() |> Editor.to_binary() |> elem(1) |> Document.from_binary()

      assert Form.fields!(doc) == []

      partial = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(partial) end)

      {:ok, doc} =
        partial |> Form.flatten!(0) |> Editor.to_binary() |> elem(1) |> Document.from_binary()

      assert Enum.map(Form.fields!(doc), & &1.name) == ["comments"]
    end

    test "warnings appear only after a write" do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.flatten!(editor)
      assert Editor.flatten_warnings!(editor) == []

      Editor.to_binary!(editor)
      assert [_ | _] = Editor.flatten_warnings!(editor)
    end

    test "warnings accumulate across writes rather than being cleared" do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.flatten!(editor)
      Editor.to_binary!(editor)
      first = Editor.flatten_warnings!(editor)

      Editor.to_binary!(editor)

      assert Editor.flatten_warnings!(editor) == first ++ first
    end

    test "an incremental save ignores the flatten marks entirely" do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(System.tmp_dir!(), "drift_incremental_flatten.pdf")
      on_exit(fn -> File.rm(path) end)

      editor |> Form.flatten!() |> Editor.save!(path, incremental: true)

      doc = Document.open!(path)
      assert Enum.map(Form.fields!(doc), & &1.name) == ["full_name", "comments"]
      assert Editor.flatten_warnings!(editor) == []
    end

    # The signature dictionary survives even when the catalog no longer links it.
    test "the whole-document flatten unhooks a signature field, the per-page one keeps it" do
      whole = Editor.open!(@signature_pdf)
      on_exit(fn -> Editor.close(whole) end)
      bytes = whole |> Form.flatten!() |> Editor.to_binary!(compress: false)

      assert bytes =~ "DEADBEEF"
      refute bytes =~ "/AcroForm"

      partial = Editor.open!(@signature_pdf)
      on_exit(fn -> Editor.close(partial) end)
      bytes = partial |> Form.flatten!(0) |> Editor.to_binary!(compress: false)

      assert bytes =~ "DEADBEEF"
      assert bytes =~ "/AcroForm"
    end

    # The inline annotation is observable only in the fixture bytes.
    test "an inline annotation is dropped by a flatten with no warning" do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)
      inline = "72 550"

      assert File.read!(@flatten_pdf) =~ inline
      assert Editor.to_binary!(editor, compress: false) =~ inline

      bytes = editor |> Form.flatten!() |> Editor.to_binary!(compress: false)

      refute bytes =~ inline
      assert [only] = Editor.flatten_warnings!(editor)
      assert only =~ "orphan"
    end

    test "flattening annotations removes even the ones it could not draw" do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      {:ok, bytes} = editor |> Editor.flatten_annotations!(0) |> Editor.to_binary()
      {:ok, doc} = Document.from_binary(bytes)

      assert Document.annotations!(doc, 0) == []
      assert Editor.flatten_warnings!(editor) == []
    end
  end

  describe "a JPEG 2000 image carrying alpha" do
    # Nothing upstream reads /SMaskInData, so a four-component RGB-plus-alpha
    # codestream is typed CMYK and encodes to a valid PNG in the wrong colours.
    test "still reads its alpha channel as ink" do
      doc = open(@image_jpx_pdf)

      assert [image] = Document.images!(doc, @rgb_with_alpha)

      # The struct contradicts its own pixels: three components declared, four
      # decoded. Without this pair the assertion below could pass on a fixture
      # that really was CMYK.
      assert image.color_space == :device_rgb
      assert {:ok, {:raw, pixels, :cmyk}} = Document.Image.data(image)
      assert byte_size(pixels) == image.width * image.height * 4

      assert {:ok, <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>} =
               Document.Image.to_binary(image)
    end
  end
end
