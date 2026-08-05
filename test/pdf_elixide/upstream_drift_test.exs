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
  alias PdfElixide.Document.Page
  alias PdfElixide.Error

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @extraction_pdf Path.join(@fixtures, "extraction.pdf")
  @table_pdf Path.join(@fixtures, "table.pdf")
  @metadata_encodings_pdf Path.join(@fixtures, "metadata_encodings.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @html_escaping_pdf Path.join(@fixtures, "html_escaping.pdf")
  @actualtext_pdf Path.join(@fixtures, "actualtext.pdf")
  @rotation_pdf Path.join(@fixtures, "rotation.pdf")
  @inherited_boxes_pdf Path.join(@fixtures, "inherited_boxes.pdf")
  @layers_and_inks_pdf Path.join(@fixtures, "layers_and_inks.pdf")
  @vector_shapes_pdf Path.join(@fixtures, "vector_shapes.pdf")
  @search_pdf Path.join(@fixtures, "search.pdf")
  @no_pages_pdf Path.join(@fixtures, "no_pages.pdf")

  @columns 0
  @artifacts 1
  @ruleless 3
  @kerned 4

  # In @broken_page_pdf: /Count says three pages, two page objects exist.
  @unreachable 2

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

  describe "whole-document text on a page that fails" do
    test "a failed page still costs only its own slot" do
      # `Document.text/1` does not call upstream's `extract_all_text` — it
      # cannot, having a `ConversionOptions` and an `:on_page_error` to honour
      # that the whole-document form accepts neither of. The NIF reimplements
      # the loop, and `:skip` is its default purely because that is upstream's
      # policy, so the two must keep agreeing about what a failed page does.
      #
      # This pins the half a caller can see: the separator goes in *before* the
      # fallible extraction, so a failed page leaves an empty slot rather than
      # vanishing, and the document still succeeds. The other half — that
      # upstream's own loop still produces the identical string — is pinned in
      # `document.rs`, which can reach `extract_all_text` where Elixir cannot.
      #
      # If upstream starts failing the document instead (its `to_plain_text_all`
      # already does), don't relax the assertion: reconsider whether `:skip`
      # should still be the default.
      doc = open(@broken_page_pdf)

      # Precondition: the page really is unextractable on its own. Upstream
      # degrades nearly every damaged page to empty text, so a fixture that
      # stopped failing here would let the assertion below pass vacuously.
      assert {:error, _} = Document.text(doc, @unreachable)

      assert String.split(Document.text!(doc), "\f") == ["One", "Two", ""]
    end

    test "fonts tolerate the same page, alone among the other extractors" do
      # `extract_page_fonts` (`fonts.rs`) is infallible by construction because
      # `PdfDocument::page_font_face_lookups` is: upstream's per-page walk
      # `continue`s past a page that does not resolve, past a page object that
      # is not a dictionary, past a dangling `/Resources` reference, and past a
      # font that fails to load (`if load_fonts_public(..).is_ok()`). It pushes
      # an empty lookup for each and returns `Ok`.
      #
      # That is the whole reason `fonts/1` is exempt from the claim `text/1`'s
      # `:on_page_error` docs make about every other whole-document extractor,
      # and why it needs no `:on_page_error` of its own. If upstream starts
      # propagating instead, don't relax the assertion: `fonts` loses its
      # justification for swallowing and the binding has to decide whether an
      # unreadable page should fail the call.
      doc = open(@broken_page_pdf)

      # Precondition, as above: the page really is unresolvable.
      assert {:error, %Error{reason: :invalid_pdf}} = Document.text(doc, @unreachable)

      # Yet fonts reports it as a page with no fonts...
      assert {:ok, []} = Document.fonts(doc, @unreachable)

      # ...and the whole-document call succeeds with the two readable pages,
      # where the extractors that have no upstream loop to match propagate.
      assert [0, 1] = doc |> Document.fonts!() |> Enum.map(& &1.page)
      assert {:error, %Error{}} = Document.chars(doc)
      assert {:error, %Error{}} = Document.images(doc)
    end
  end

  describe "PDF text-string decoding" do
    test "a BOM-less buffer that is valid UTF-8 still decodes as UTF-8" do
      # `metadata/1` decodes /Info strings with the public
      # `pdf_oxide::optional_content::decode_pdf_text_string`. Its BOM-less
      # branch tries UTF-8 *before* PDFDocEncoding, which ISO 32000-1 §7.9.2.2
      # does not sanction — a string with no BOM is PDFDocEncoding, full stop.
      # Upstream is being lenient for the producers that emit raw UTF-8 anyway.
      #
      # The spec-mandated half (0x85 -> en dash, etc.) is pinned in
      # document_test.exs; only this deliberate non-conformance is upstream's
      # to change. If the branch goes, every raw-UTF-8 /Info value in the wild
      # silently starts arriving as mojibake, and this binding has to decide
      # whether to decode text strings itself. Don't relax the assertion.
      doc = open(@metadata_encodings_pdf)

      # /Creator is <4372C3A96174657572>: "Créateur" read as UTF-8,
      # "CrÃ©ateur" read as PDFDocEncoding.
      assert Document.metadata!(doc).creator == "Créateur"
    end
  end

  describe "a wrong password is not an upstream error" do
    test "authenticate reports it as {:ok, false}, and open/2 synthesizes the atom" do
      # `pdf_oxide::Error` has no wrong-password variant: `authenticate`
      # returns `Ok(false)`, and `EncryptedPdf` — the only password-adjacent
      # variant — means "not authenticated yet". So `:wrong_password` is not
      # produced by `to_nif_err`/`classify` at all; the NIF synthesizes it in
      # `OpenOptionsNif::apply` from that `false`.
      #
      # Both halves below break together if upstream starts returning an
      # `Error` for a rejected password: `document_authenticate` maps a real
      # `Err` through `to_nif_err`, so the check turns into
      # `{:error, %Error{reason: :other}}`, and the open path — which routes
      # the same `Err` through the same `?` before it can reach its own
      # `if !ok` — degrades from `:wrong_password` to `:other`, silently
      # breaking every caller matching on it.
      #
      # The fix then is an arm in `classify` (`native/.../error.rs`) mapping
      # the new variant to `:wrong_password`, plus a re-read of
      # `authenticate/2`'s documented `{:ok, false}` contract — not a relaxed
      # assertion here.
      doc = open(@encrypted_pdf)

      assert {:ok, false} = Document.authenticate(doc, "wrong")

      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@encrypted_pdf, password: "wrong")
    end
  end

  describe "has_text_layer on a document that cannot be decrypted" do
    test "answers true where text/1 answers empty" do
      # Upstream's `has_text_layer` (`src/document.rs`) has no
      # `is_encrypted_unreadable()` guard, unlike `extract_spans` and
      # `assemble_text_via_reading_order`, which both bail early and return
      # nothing. Instead the page dictionary resolves, the resource check passes
      # on its /Font entry, and the content stream then fails to decrypt — which
      # lands on the deliberate `Err(_) => Ok(true)` arm, "be conservative, let
      # extraction try".
      #
      # So an unauthenticated encrypted page reports a text layer it cannot
      # produce a single character of. That is upstream's posture, not this
      # binding's: `Page.has_text_layer/1`'s docs say `true` is not a promise
      # `text/1` returns anything, and this is the sharpest case of it.
      #
      # If this flips to an error, or to `{:ok, false}`, upstream has added the
      # guard — re-read that paragraph rather than relaxing the assertion, and
      # note the reason atom would then be `:encrypted`.
      doc = open(@encrypted_pdf)

      assert {:ok, true} = Page.has_text_layer(Document.page!(doc, 0))
      assert {:ok, ""} = Document.text(doc, 0)
    end

    test "answers true once authenticated too, for the ordinary reason" do
      # The control: with the password applied the same page reaches the byte
      # scan and finds real text, so the `true` above cannot be read as
      # "authentication makes no difference".
      doc = Document.open!(@encrypted_pdf, password: "secret")

      assert {:ok, true} = Page.has_text_layer(Document.page!(doc, 0))
      assert {:ok, text} = Document.text(doc, 0)
      assert String.trim(text) != ""
    end
  end

  describe "HTML output escaping" do
    # `to_html/2`'s docs promise that text taken from the PDF cannot inject
    # markup, and that `:image_output_dir` is the only unescaped input. That
    # promise is upstream's to keep — `escape_html`
    # (`src/pipeline/converters/html.rs`) is what makes it true — so it is
    # pinned here rather than in `document_test.exs`. The complement, that the
    # image path really is *not* escaped, is pinned there.
    #
    # A failure here means the docs are now claiming a safety property the
    # library no longer has: fix the escaping story before touching the
    # assertion. Note what is *not* covered — a detected table's cells escape
    # through a separate `escape_html` call site, and no fixture produces a
    # table with markup in a cell. Canary 1 covers the function, not that call.
    setup do: %{doc: open(@html_escaping_pdf)}

    test "text taken from the PDF is escaped in both output modes", %{doc: doc} do
      # The fixture's first line is literally `<script>alert("x") & 'y'</script>`,
      # covering all four characters upstream replaces. `'` is deliberately not
      # among them, which is safe only because every attribute the converter
      # emits is double-quoted — so it is asserted raw, and a consumer must not
      # re-quote the fragment with single quotes.
      escaped = "&lt;script&gt;alert(&quot;x&quot;) &amp; 'y'&lt;/script&gt;"

      assert {:ok, html} = Document.to_html(doc)
      assert html =~ escaped
      refute html =~ "<script>"

      # `preserve_layout` is a separate converter path, and the same promise
      # has to hold there.
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
      # `is_safe_link_uri` (`src/pipeline/converters/mod.rs`) allows only
      # http, https, mailto, tel, ftp and ftps. An unsafe scheme loses the
      # anchor, not the words.
      assert {:ok, html} = Document.to_html(doc)

      refute html =~ "javascript:"
      assert html =~ "Bad link"
      refute html =~ ~s(<a href="javascript)
    end
  end

  describe "competing /ActualText scopes" do
    # Upstream keeps the record of which MCIDs had an *in-stream* (BDC)
    # `/ActualText` in `PdfDocument::mc_actualtext_mcids` (`src/document.rs`) —
    # document-global state keyed only by page index. It is written at the tail
    # of `extract_spans_impl` and read back in a *later*, separate lock
    # acquisition by the struct-tree applier (`apply_actualtext_to_spans` and
    # the two assemblers). That makes it per-invocation scratch parked in shared
    # storage, not a cache: nothing ties the value read to the call that wrote
    # it.
    #
    # `actualtext.pdf` is built to make the consequence observable. MCID 0
    # carries `/ActualText (INLINE)` in a Form XObject's content stream, and the
    # structure element whose MCR covers that same MCID carries
    # `/ActualText (ANCESTOR)`. ISO 32000-1:2008 §14.9.4 gives the innermost
    # declaration precedence, so `"INLINE"` is the correct extraction — and it
    # is what upstream produces exactly once per handle.
    #
    # The reason it degrades is the Form XObject span cache: a repeat extraction
    # is served from `xobject_spans_cache` (`src/extractors/text.rs`), which
    # returns early *without* re-scanning the XObject's BDCs, so that call
    # records an empty set and clears the page's entry. The ancestor replacement
    # then wins where it should have been declined.
    #
    # Why it is pinned here: `PdfElixide.Document`'s "Sharing a document across
    # processes" section documents this as the one place concurrent same-page
    # extraction can return wrong text, and the binding cannot fix it — the
    # field is `pub(crate)` with no way to make it invocation-local. These
    # canaries assert it *sequentially*, so they carry no timing assumption at
    # all. **A failure means upstream repaired the state model**: relax the
    # moduledoc hazard and the `Closable` doc comment in
    # `native/pdf_elixide_nif/src/resource.rs`, then re-pin the new truth here.
    test "a repeat span extraction of one page loses MC-scope precedence" do
      doc = open(@actualtext_pdf)

      assert texts(Document.spans!(doc, 0)) == ["INLINE"]

      # Same call, same handle, same options — a different answer, and the
      # wrong one.
      assert texts(Document.spans!(doc, 0)) == ["ANCESTOR"]
    end

    test "an earlier span extraction changes a later text extraction" do
      # On its own, `text/2` is stable and correct however often it is called:
      # it reaches the page span cache rather than re-entering the extractor.
      untouched = open(@actualtext_pdf)
      assert Document.text!(untouched, 0) == "INLINE"
      assert Document.text!(untouched, 0) == "INLINE"

      # But an unrelated extraction of the same page first is enough to change
      # what it returns. This is the shape that makes concurrency unsafe: two
      # calls that share nothing but the page index, and the second is wrong.
      poisoned = open(@actualtext_pdf)
      assert texts(Document.spans!(poisoned, 0)) == ["INLINE"]
      assert Document.text!(poisoned, 0) == "ANCESTOR"
    end
  end

  describe "which frame a rotated page's boxes are in" do
    # `PdfElixide.Document`'s "Rotated pages and extracted geometry" section
    # tells callers that on a rotated page the extractors do not all report in
    # one coordinate frame. That split is upstream's, and it is not visible from
    # any signature — hence a canary.
    #
    # Where it comes from: `postprocess_spans` (`src/document.rs`) maps span
    # geometry into the *displayed* frame before reading-order sorting, so a
    # 180-degree page reads forwards rather than word- and line-reversed. Only
    # the calls that run it are affected. `extract_spans` does; the
    # reading-order variants this binding's `spans/2` uses
    # (`extract_spans_filtered_with_reading_order`) do not, and neither does
    # `extract_chars`. `extract_words` reaches it through
    # `pipeline::page_reading_order`, which calls `extract_spans` — so `words`
    # and `text_lines` are mapped where the `spans` describing the same glyphs
    # are not.
    #
    # The mapping is also selective on quadrant pages: at 90 and 270 degrees
    # only spans whose own text matrix is rotated are mapped, because
    # `TextSpan::to_chars` lays glyphs out along the horizontal axis and cannot
    # express a now-vertical run. `rotation.pdf`'s text is horizontal on every
    # page, which is what makes the 90-degree page a control for the
    # 180-degree one.
    #
    # A failure means upstream changed *when* it maps. Do not relax it: fix the
    # moduledoc section, which is the only thing telling callers which
    # extractor to trust for a box.
    setup do: %{doc: open(@rotation_pdf)}

    test "an unrotated page reports one frame", %{doc: doc} do
      assert [span] = Document.spans!(doc, @rotate_0)
      assert origins(Document.words!(doc, @rotate_0)) |> hd() == origin(span)
      assert origins(Document.text_lines!(doc, @rotate_0)) == [origin(span)]
      assert Document.chars!(doc, @rotate_0) |> hd() |> origin() == origin(span)
    end

    test "a 90-degree page leaves horizontal content raw", %{doc: doc} do
      # Every extractor still agrees, because the run's own text matrix is not
      # rotated. This is the control: it fails if upstream starts mapping every
      # span on a quadrant-rotated page.
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
      # `search` reaches its spans through `PdfDocument::search_page_index`,
      # which calls the plain `extract_spans` — so it is on the mapped side of
      # the split above, even though `spans/2` is not. Nothing in either
      # signature shows that, which is why it is pinned rather than assumed.
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
    # Everything here is upstream's rule, not this binding's, and none of it is
    # visible from `TextSearcher::search`'s signature. `guides/search.md` is
    # what tells callers about each one; a failure here means that guide has
    # gone wrong, so fix the guide rather than the assertion.
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
      # Upstream maps a `regex` compile failure onto `Error::InvalidPdf`, the
      # same variant a corrupt document produces. `error::to_search_err` tells
      # the two apart by the message prefix alone, which is the coupling this
      # pins: if upstream rewords it, the reason atom silently degrades to
      # `:invalid_pdf` and callers matching `:invalid_pattern` stop seeing it.
      assert {:error, %Error{reason: :invalid_pattern, message: message}} =
               Document.search(doc, "(", literal: false)

      assert message =~ "Invalid regex pattern: "
    end
  end

  describe "searching a document with no pages" do
    test "an inverted page range visits no page" do
      # `TextSearcher::search` clamps the *end* of the range it is given
      # (`end.min(page_count.saturating_sub(1))`) and never the start, so
      # `document_all_search` says "no pages" as the range `1..=0` — empty,
      # rather than the `0..=0` upstream would derive on its own and fail in
      # `get_page`.
      #
      # If this starts erroring, upstream has begun clamping the start too:
      # find another way to express an empty sweep rather than restoring the
      # early return, which would accept an unparseable pattern here.
      assert {:ok, []} = Document.search(open(@no_pages_pdf), "x")
    end
  end

  describe "inherited page boxes" do
    # `/MediaBox` and `/Rotate` are inheritable (ISO 32000-1 §7.7.3.4, which
    # says the *nearest* ancestor wins). Upstream resolves them in two places
    # that disagree, and which one runs depends on how many pages have been
    # read:
    #
    #   * `get_page_from_tree_inner` (`src/document.rs`) — the per-page
    #     traversal `get_page` uses by default — merges an ancestor's
    #     attributes with `inherited.entry(..).or_insert_with(..)`. First
    #     writer wins, so the *outermost* ancestor survives, against the spec
    #     and against that code's own comment ("child values override
    #     parent"); it also never restores the map as it unwinds.
    #   * `collect_all_pages` does it correctly — `insert` plus a
    #     snapshot/restore around the recursion — so the *nearest* wins.
    #
    # `get_page` switches to the second once the page cache passes
    # `LAZY_THRESHOLD = 64`. So the same page of the same document answers
    # differently depending on what was read before it, which is what the two
    # tests below pin. `inherited_boxes.pdf` page 0 sits under an outer /Pages
    # of [0 0 200 100] + /Rotate 90 and an inner one of [0 0 300 500] +
    # /Rotate 180; its other 70 pages exist only to cross that threshold.
    #
    # A failure means upstream unified the two walks. That is good news, but
    # it makes the "Which ancestor an inherited box comes from" subsection of
    # `PdfElixide.Document`'s "Page boxes and the coordinate origin" wrong —
    # rewrite it, and say which rule now holds, rather than relaxing this.
    test "the outermost ancestor wins on the per-page traversal" do
      page = Document.page!(open(@inherited_boxes_pdf), 0)

      assert %{width: 200.0, height: 100.0} = Page.media_box!(page)
      assert Page.rotation!(page) == 90
    end

    test "the nearest ancestor wins once the bulk page-tree walk takes over" do
      doc = open(@inherited_boxes_pdf)

      # Reading past LAZY_THRESHOLD is the whole trigger; the values are not
      # the point, and page 0 is deliberately not among them.
      for i <- 1..70, do: Page.media_box!(Document.page!(doc, i))

      page = Document.page!(doc, 0)
      assert %{width: 300.0, height: 500.0} = Page.media_box!(page)
      assert Page.rotation!(page) == 180
    end
  end

  describe "inks the deep walk deliberately skips" do
    # `inks/3`'s docs promise three boundaries that are upstream policy, not
    # ours: a /Pattern *colour space*'s underlying space is read, while a
    # colorant declared only inside a tiling pattern object's own resources or
    # only inside an annotation appearance stream is not. Page 2 of
    # @layers_and_inks_pdf declares one of each and nothing else, so the
    # positive control sits beside the two absences — without it, upstream
    # starting to walk pattern resources would look the same as upstream
    # ceasing to walk the underlying space.
    #
    # A failure means the "Optional content" limits in the docs now
    # under-promise. Widen the `inks/3` docblock rather than this assertion.
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
    # `rects/2` and `lines/2` are `paths/2` filtered by upstream's
    # `PathContent::is_rectangle` / `is_straight_line`, which test the *drawing
    # commands* rather than the geometry. The "Rectangles and straight lines"
    # section of `PdfElixide.Document.Path` promises callers exactly what that
    # accepts, including four results that read as wrong, so every one of them
    # is pinned here rather than in document_test.exs: they are upstream's
    # rules, not this library's, and a failure means the docblock now lies.
    #
    # Each page of @vector_shapes_pdf carries one branch family and nothing
    # else, so a count is a complete statement about that page.
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

      # Both paths are extracted; neither is classified. If upstream starts
      # accepting the six-operation form, drop that bullet from the docs.
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
end
