defmodule PdfElixide.UpstreamDriftTest do
  @moduledoc """
  Canaries for `pdf_oxide` behavior this library documents but does not own.

  **A failure here is a signal about upstream, not a bug in this library.** Do
  not relax an assertion to make it pass. Read the `pdf_oxide` changelog for
  the version just picked up, decide whether the corresponding `pdf_elixide`
  option should now be deprecated, removed or re-documented, and change the
  binding — then update the canary to pin the new truth.

  ## Why these are behavioral, not existence checks

  Some of the options this library exposes are already marked for removal
  upstream: `warn_deprecated_kwargs` in `pdf_oxide`'s Python bindings cites
  issue #457 Step 5 ("kwargs … will move to a separate `*_advanced` method in
  a future release") for `:word_gap_threshold`, `:line_gap_threshold` and
  `:profile`, and `extract_words_inner` describes its legacy span path as kept
  "pending the planned removal of `profile`".

  Hard removal is already covered: deleting `extract_words_with_thresholds` or
  `ExtractionProfile` stops the NIF compiling, and the pre-commit and pre-push
  hooks run `cargo check`. What no compiler catches is the *soft* deprecation,
  which is upstream's own precedent — `ExtractorConfig` still carries all five
  of its fields, each documented "retained for API compatibility but no longer
  has any effect". A hollowed-out knob compiles clean and silently starts
  lying to callers. So every canary below asserts that the knob still **changes
  the result**.
  """
  use ExUnit.Case, async: true

  @moduletag :upstream_drift

  alias PdfElixide.Document

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")

  @columns 0
  @artifacts 1
  @ruleless 3
  @kerned 4

  defp open(path) do
    doc = Document.open!(path)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp texts(items), do: Enum.map(items, & &1.text)

  describe "deprecated word and line knobs" do
    setup do: %{doc: open(@extraction_pdf)}

    test ":profile still routes to the legacy span path", %{doc: doc} do
      # Passing any profile switches `extract_words_inner` from the canonical
      # `page_reading_order` helper to an XY-cut plus row-aware sort. On this
      # two-column page the two paths group the columns differently, so the
      # word list differs even for :conservative — which is nominally the
      # default profile. That is what makes this one assertion catch both
      # outright removal and a silently inert :profile.
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
      # Upstream's Python binding carries a stale comment claiming
      # `include_artifacts=False` is the default while its signature says
      # `true`, which reads like an intended flip. This library is insulated —
      # its default routes explicitly to the artifact-keeping variant — but if
      # the meaning of the *option* ever inverts, this fails.
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

      # `extract_text_filtered` builds its own conversion options, so
      # `:extract_tables` never reaches upstream and the output matches the
      # default rather than the tables-off one. If this flips, upstream has
      # made the filtered path configurable and the `t:text_opts/0` caveat can
      # go.
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
      # `TableDetectionConfig::default()` sets `text_fallback: true`, so the
      # rule-less page *is* detectable as a table…
      assert length(Document.tables!(doc, @ruleless)) == 1

      # …but `extract_page_tables` overwrites the flag with `false` on the text
      # path, so no table is ever rendered there and asking for it changes
      # nothing. A rendered table would space-pad its columns; the row arriving
      # as bare concatenated cells is what proves none was rendered. If
      # upstream stops overriding, both assertions below flip and the
      # `:table_detection` typedoc becomes wrong.
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
      # The presets differ in fields no fixture this small can separate, so
      # this pins that each name still maps to a real upstream constructor —
      # a removed preset would fail to decode rather than quietly fall back.
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
end
