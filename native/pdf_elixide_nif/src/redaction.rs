use pdf_oxide::redaction::{OcgPolicy, RedactionOptions, RedactionReport};
use rustler::{Atom, NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    atoms,
    color::RgbNif,
    editor::{
        draws_redactions, ensure_contents_redactable, ensure_editor_page_in_range,
        ensure_info_is_direct, ensure_redaction_spliceable, ensure_source_is_not_encrypted,
        redaction_corners,
    },
    error::{tagged_err, to_nif_err},
    geometry::RectNif,
    open_editor::{Marked, OpenEditor},
    text_state::measures_restored_text_state,
    EditorResource,
};

#[derive(NifUnitEnum, Clone, Copy, Debug)]
pub enum OcgPolicyNif {
    Keep,
    StripHidden,
    Flatten,
}

impl From<OcgPolicyNif> for OcgPolicy {
    fn from(p: OcgPolicyNif) -> Self {
        match p {
            OcgPolicyNif::Keep => OcgPolicy::Keep,
            OcgPolicyNif::StripHidden => OcgPolicy::StripHidden,
            OcgPolicyNif::Flatten => OcgPolicy::Flatten,
        }
    }
}

#[derive(NifMap, Debug)]
pub struct RedactionOptionsNif {
    pub scrub_metadata: bool,
    pub remove_javascript: bool,
    pub remove_embedded_files: bool,
    pub optional_content: OcgPolicyNif,
    pub edge_padding: f32,
    pub default_fill: RgbNif,
    pub draw_default_overlay: bool,
    pub emit_redaction_artifacts: bool,
}

impl From<RedactionOptionsNif> for RedactionOptions {
    fn from(o: RedactionOptionsNif) -> Self {
        // `RedactionOptions` is non-exhaustive; construct it through Default.
        let mut opts = RedactionOptions::default();
        opts.scrub_metadata = o.scrub_metadata;
        opts.remove_javascript = o.remove_javascript;
        opts.remove_embedded_files = o.remove_embedded_files;
        opts.optional_content = o.optional_content.into();
        opts.edge_padding = o.edge_padding;
        opts.default_fill = [o.default_fill.r, o.default_fill.g, o.default_fill.b];
        opts.draw_overlay_when_no_ic = o.draw_default_overlay;
        opts.emit_redaction_artifacts = o.emit_redaction_artifacts;
        opts
    }
}

impl RedactionOptionsNif {
    // Reject at the NIF boundary too: upstream silently coerces invalid values.
    pub fn validate(&self) -> NifResult<()> {
        if !self.edge_padding.is_finite() || self.edge_padding < 0.0 {
            return Err(tagged_err(
                atoms::other(),
                format!(
                    "Invalid :edge_padding {:?}: it must be a non-negative number",
                    self.edge_padding
                ),
            ));
        }

        ensure_fill_in_range(
            [
                self.default_fill.r,
                self.default_fill.g,
                self.default_fill.b,
            ],
            ":default_fill",
        )
    }
}

// Upstream clamps invalid components instead of rejecting them.
pub fn ensure_fill_in_range(fill: [f32; 3], label: &str) -> NifResult<()> {
    if fill.iter().any(|c| !(0.0..=1.0).contains(c)) {
        return Err(tagged_err(
            atoms::other(),
            format!("Invalid {label} {fill:?}: each component must be between 0.0 and 1.0"),
        ));
    }

    Ok(())
}

#[derive(NifMap, Debug)]
pub struct RedactionReportNif {
    regions: usize,
    glyphs_removed: usize,
    bytes_removed: u64,
}

// Only the three fields `apply_redactions_destructive` actually sums; see
// `upstream_still_drops_six_report_fields_when_aggregating`.
fn redaction_report_to_nif(report: RedactionReport) -> RedactionReportNif {
    RedactionReportNif {
        regions: report.regions,
        glyphs_removed: report.glyphs_removed,
        bytes_removed: report.bytes_removed,
    }
}

#[derive(NifMap, Debug)]
pub struct SanitizeReportNif {
    roots_removed: usize,
    bytes_removed: u64,
}

// On the sanitize path, `annotations_removed` counts catalog roots.
fn sanitize_report_to_nif(report: RedactionReport) -> SanitizeReportNif {
    SanitizeReportNif {
        roots_removed: report.annotations_removed,
        bytes_removed: report.bytes_removed,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_mark_page_redactions(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Inside the guard so the checks and the mark cannot straddle a writer
        // that changes the page count.
        ensure_editor_page_in_range(editor, page_index)?;
        ensure_redaction_spliceable(editor, page_index)?;

        editor
            .apply_page_redactions(page_index)
            .map_err(to_nif_err)?;
        editor.mark(Marked::Redactions);

        Ok(atoms::ok())
    })
}

// Upstream's bulk call marks raw output indices, so after a deletion it marks
// the wrong source pages. The per-page loop is conditional because with no
// deletion the bulk call is correct and the loop would be quadratic. Same shape
// as `editor_flatten_forms`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_mark_all_redactions(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // All-or-nothing: refusing halfway would leave a partly marked editor
        // whose marks cannot be told from ones the caller made.
        for page in 0..editor.current_page_count() {
            ensure_redaction_spliceable(editor, page)?;
        }

        // Enable the scan before the loop can fail with some pages marked.
        editor.mark(Marked::Redactions);

        if editor.pages_deleted() {
            for page in 0..editor.current_page_count() {
                editor.apply_page_redactions(page).map_err(to_nif_err)?;
            }
        } else {
            editor.apply_all_redactions().map_err(to_nif_err)?;
        }

        Ok(atoms::ok())
    })
}

// Upstream does not bounds-check this one, so the check here is the only one.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_unmark_page_redactions(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;

        editor.unmark_page_for_redaction(page_index);

        Ok(atoms::ok())
    })
}

// Shared: upstream's accessor takes `&self` and the bounds check needs no more.
// Upstream does not bounds-check this one either.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_is_page_marked_for_redaction(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<bool> {
    resource.editor.with_read(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;

        Ok(editor.is_page_marked_for_redaction(page_index))
    })
}

// Exclusive because upstream's `redaction_count` takes `&mut self` to reach the
// private annotation reader; it is a one-shot, so the cost is a single call.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_redaction_count(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<usize> {
    resource.editor.with_lock(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;

        editor.redaction_count(page_index).map_err(to_nif_err)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_add_redaction(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    rect: RectNif,
    fill: Option<RgbNif>,
) -> NifResult<Atom> {
    // Converted before the lock: neither check needs an editor.
    let corners = redaction_corners(rect)?;
    let fill = fill.map(|c| [c.r, c.g, c.b]);
    if let Some(fill) = fill {
        ensure_fill_in_range(fill, "fill")?;
    }

    resource.editor.with_lock(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;
        // A queued region cannot be withdrawn, so refuse one no pass can apply.
        ensure_source_is_not_encrypted(editor, "A destructive redaction")?;
        ensure_contents_redactable(editor, page_index)?;

        editor
            .queue_redaction(page_index, corners, fill)
            .map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

// Check only before destructive apply: cosmetic marks measure no glyphs.
fn ensure_text_state_measurable(editor: &OpenEditor) -> NifResult<()> {
    let sources = editor.source_pages();
    let queued = editor.queued_redactions();

    // Only half of upstream's destructive set is readable, hence the mirror. A
    // source page with no output index needs no check: nothing of it is written.
    let destructive: Vec<(usize, usize, bool)> = sources
        .iter()
        .enumerate()
        .map(|(output, source)| (output, *source, queued.contains(source)))
        .filter(|(output, _, queued)| *queued || editor.is_page_marked_for_redaction(*output))
        .collect();

    for (output, source, queued) in destructive {
        // A mark without any regions rewrites nothing and needs no measurement.
        if !queued && !draws_redactions(editor, source)? {
            continue;
        }

        // The document reader sees at least what the editor's private one does,
        // so the guard can only over-refuse. A page whose content cannot be read
        // is upstream's error to report, not this guard's to pre-empt.
        let Ok(content) = editor.source().get_page_content_data(source) else {
            continue;
        };

        if measures_restored_text_state(&content) {
            return Err(tagged_err(
                atoms::unsupported(),
                format!(
                    "Page {output} selects a font, size, text spacing or line \
                     leading inside a q/Q block and then draws text, or moves to a \
                     new line, after the restore. A destructive redaction measures \
                     that text with the state the restore discarded, so it could \
                     leave the text in place and report success. The page can \
                     still be saved unchanged."
                ),
            ));
        }
    }

    Ok(())
}

// A second pass rebuilds from the source and can restore removed text.
fn ensure_first_pass(editor: &OpenEditor) -> NifResult<()> {
    if editor.applied_redactions() {
        return Err(tagged_err(
            atoms::unsupported(),
            "This editor has already applied a destructive redaction. A second \
             pass rebuilds each page from the unredacted source, so it can restore \
             what the first removed. Queue every region before applying, or reopen \
             the source.",
        ));
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_apply_redactions(
    resource: ResourceArc<EditorResource>,
    options: RedactionOptionsNif,
) -> NifResult<RedactionReportNif> {
    options.validate()?;

    resource.editor.with_lock(|editor| {
        // Keep before preflight and arming: preflight decrypts, while apply does not.
        ensure_source_is_not_encrypted(editor, "A destructive redaction")?;
        ensure_first_pass(editor)?;
        ensure_text_state_measurable(editor)?;

        editor.arm_redaction();

        let report = editor
            .apply_redactions_destructive(options.into())
            .map_err(to_nif_err)?;

        Ok(redaction_report_to_nif(report))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_sanitize(
    resource: ResourceArc<EditorResource>,
    options: RedactionOptionsNif,
) -> NifResult<SanitizeReportNif> {
    options.validate()?;
    let scrub_metadata = options.scrub_metadata;
    let remove_javascript = options.remove_javascript;
    let remove_embedded_files = options.remove_embedded_files;

    resource.editor.with_lock(|editor| {
        if scrub_metadata {
            ensure_info_is_direct(editor)?;
        }

        let report = editor
            .sanitize_document(options.into())
            .map_err(to_nif_err)?;

        editor.record_sanitize(scrub_metadata, remove_javascript, remove_embedded_files);

        Ok(sanitize_report_to_nif(report))
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{
        editor::{DocumentEditor, EditableDocument, SaveOptions},
        redaction::{OcgPolicy, RedactionOptions, RedactionReport},
    };

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    fn editor(name: &str) -> DocumentEditor {
        DocumentEditor::open(fixture(name)).expect("fixture opens")
    }

    fn uncompressed() -> SaveOptions {
        SaveOptions {
            compress: false,
            ..SaveOptions::full_rewrite()
        }
    }

    fn authenticated(name: &str) -> DocumentEditor {
        let editor = editor(name);
        assert!(
            editor
                .source()
                .authenticate(b"secret")
                .expect("the fixture authenticates"),
            "the fixture's password is still `secret`"
        );
        editor
    }

    // A decrypted control prevents fixture drift from passing the canary.
    fn decrypted_twin(name: &str) -> DocumentEditor {
        let bytes = authenticated(name)
            .save_to_bytes_with_options(SaveOptions::full_rewrite())
            .expect("a full rewrite decrypts");

        DocumentEditor::from_bytes(bytes).expect("the rewritten bytes open")
    }

    fn redact(editor: &mut DocumentEditor, rect: [f32; 4]) -> pdf_oxide::Result<RedactionReport> {
        editor
            .add_redaction(0, rect, None)
            .expect("a region is queued");
        editor.apply_redactions_destructive(RedactionOptions::default())
    }

    #[test]
    fn upstream_still_reads_encrypted_page_content_as_ciphertext() {
        const OVER_PAGE_ONE: [f32; 4] = [65.0, 690.0, 250.0, 725.0];

        assert!(
            redact(&mut decrypted_twin("encrypted.pdf"), OVER_PAGE_ONE)
                .expect("the decrypted twin redacts")
                .glyphs_removed
                > 0,
            "the region no longer covers any text; fix it before reading the canary"
        );

        assert!(
            redact(&mut authenticated("encrypted.pdf"), OVER_PAGE_ONE).is_err(),
            "upstream now decrypts the page content a destructive redaction reads"
        );
    }

    #[test]
    fn upstream_still_under_redacts_an_encrypted_page() {
        const OVER_THE_SECRET: [f32; 4] = [65.0, 630.0, 300.0, 665.0];

        assert!(
            redact(
                &mut decrypted_twin("encrypted_array_contents.pdf"),
                OVER_THE_SECRET
            )
            .expect("the decrypted twin redacts")
            .glyphs_removed
                > 0,
            "the region no longer covers any text; fix it before reading the canary"
        );

        let report = redact(
            &mut authenticated("encrypted_array_contents.pdf"),
            OVER_THE_SECRET,
        )
        .expect("upstream now fails a redaction it cannot read");

        assert_eq!(
            (report.regions, report.glyphs_removed),
            (0, 0),
            "upstream now redacts an encrypted page whose /Contents is an array"
        );
    }

    #[test]
    fn upstream_still_marks_all_redactions_by_output_index() {
        let mut editor = editor("redact.pdf");
        editor.remove_page(0).expect("page 0 is removed");
        editor
            .apply_all_redactions()
            .expect("marking every page succeeds");

        // One page survives, and it is source page 1. Upstream inserted the
        // output index 0, so the survivor is unmarked and a deleted page is not.
        assert_eq!(editor.current_page_count(), 1);
        assert!(
            !editor.is_page_marked_for_redaction(0),
            "upstream now maps the bulk redaction mark through the page order"
        );
    }

    #[test]
    fn upstream_still_ignores_queued_regions_in_the_cosmetic_overlay() {
        let mut editor = editor("redact_unknown_font.pdf");
        editor
            .add_redaction(0, [95.0, 695.0, 250.0, 725.0], Some([0.0, 1.0, 0.0]))
            .expect("the region is queued");

        let bytes = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        let text = String::from_utf8_lossy(&bytes);

        // The queued fill would be `0.000 1.000 0.000 rg`; the page's own
        // `/Redact` annotation is what the cosmetic writer draws instead.
        assert!(
            !text.contains("0.000 1.000 0.000 rg"),
            "upstream now draws queued redaction regions without a destructive apply"
        );
    }

    #[test]
    fn upstream_still_ignores_the_sanitize_options_when_redacting() {
        let mut editor = editor("sanitize.pdf");
        editor
            .add_redaction(0, [95.0, 695.0, 250.0, 730.0], None)
            .expect("the region is queued");

        let report = editor
            .apply_redactions_destructive(RedactionOptions::default())
            .expect("the page redacts");
        // Non-vacuity: the pass must have done real work on the page.
        assert!(report.glyphs_removed > 0, "the region must cover the text");

        let bytes = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        let text = String::from_utf8_lossy(&bytes);

        for (what, needle) in [
            ("XMP metadata", "Sanitize me"),
            ("document JavaScript", "app.alert"),
            ("the embedded file", "note.txt"),
        ] {
            assert!(
                text.contains(needle),
                "upstream now scrubs {what} on the destructive redaction path"
            );
        }
    }

    #[test]
    fn upstream_still_ignores_the_optional_content_policy() {
        let mut editor = editor("render_layers.pdf");
        editor
            .add_redaction(0, [15.0, 125.0, 90.0, 145.0], None)
            .expect("the region is queued");

        let mut opts = RedactionOptions::default();
        opts.optional_content = OcgPolicy::Flatten;
        let report = editor
            .apply_redactions_destructive(opts)
            .expect("the page redacts");
        assert!(report.glyphs_removed > 0, "the region must cover `Shown`");

        let bytes = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        let text = String::from_utf8_lossy(&bytes);

        // `/L2` is OFF by default, so `StripHidden` and `Flatten` both claim to
        // remove its span; the fixture keeps `Hidden` outside every region so
        // only the policy could have taken it.
        assert!(
            text.contains("Hidden"),
            "upstream now strips a hidden layer's content"
        );
        assert!(
            text.contains("/OCProperties"),
            "upstream now flattens the optional-content configuration"
        );
    }

    #[test]
    fn upstream_still_emits_no_redaction_artifacts() {
        let mut editor = editor("tagged.pdf");
        editor
            .add_redaction(0, [65.0, 715.0, 250.0, 750.0], None)
            .expect("the region is queued");

        let mut opts = RedactionOptions::default();
        opts.emit_redaction_artifacts = true;
        let report = editor
            .apply_redactions_destructive(opts)
            .expect("the page redacts");
        assert!(report.glyphs_removed > 0, "the region must cover the text");

        let bytes = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");

        // The fixture is the tagged one, so a structure tree is present and the
        // option's stated precondition is met.
        assert!(
            !String::from_utf8_lossy(&bytes).contains("Redaction"),
            "upstream now tags redacted areas in the structure tree"
        );
    }

    #[test]
    fn upstream_still_keeps_actual_text_after_a_redaction() {
        let mut editor = editor("redact_actualtext.pdf");
        editor.apply_page_redactions(0).expect("page 0 is marked");
        let report = editor
            .apply_redactions_destructive(RedactionOptions::default())
            .expect("the page redacts");
        assert!(report.glyphs_removed > 0, "the region must cover `Shown`");

        let bytes = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        let text = String::from_utf8_lossy(&bytes);

        assert!(
            text.contains("PRIVATE SECRET"),
            "upstream now scrubs marked-content /ActualText under a region"
        );
        // Non-vacuity in the other direction: the glyphs really did go.
        assert!(
            !text.contains("(Shown) Tj"),
            "the fixture's covered show operator must have been rewritten"
        );
    }

    #[test]
    fn upstream_still_cannot_read_an_indirect_contents_that_is_not_a_stream() {
        // The fixture resolves to null; a dictionary decodes to empty content.
        let mut annotated = editor("redact_unreadable_annotated.pdf");
        annotated
            .apply_page_redactions(0)
            .expect("page 0 is marked");
        // Non-vacuity: the annotation is what makes the region set non-empty.
        // Without one the pass returns early and never reads the contents, which
        // is why marking such a page is still allowed.
        assert_eq!(
            annotated.redaction_count(0).expect("the page is in range"),
            1
        );

        let err = annotated
            .apply_redactions_destructive(RedactionOptions::default())
            .expect_err("upstream now decodes a non-stream /Contents");
        assert!(
            err.to_string().contains("Stream"),
            "expected a stream-type failure, got {err}"
        );
    }

    #[test]
    fn upstream_still_rereads_the_source_page_on_a_second_pass() {
        let mut editor = editor("redact.pdf");
        editor.apply_page_redactions(0).expect("page 0 is marked");

        let mut wide = RedactionOptions::default();
        wide.edge_padding = 150.0;
        let first = editor
            .apply_redactions_destructive(wide)
            .expect("the page redacts");
        assert!(first.glyphs_removed > 0, "the wide pass must remove text");
        let after_first = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        // Precondition: the padding must be wide enough to take `Kept` too,
        // or the second pass has nothing to restore and the test is vacuous.
        assert!(
            !String::from_utf8_lossy(&after_first).contains("(Kept) Tj"),
            "the padding must reach `Kept` for this test to mean anything"
        );

        editor
            .apply_redactions_destructive(RedactionOptions::default())
            .expect("the page redacts again");
        let after_second = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");

        assert!(
            String::from_utf8_lossy(&after_second).contains("(Kept) Tj"),
            "upstream now builds a second pass on the first one's result"
        );
    }

    #[test]
    fn upstream_still_keeps_an_indirect_info_value_after_sanitizing() {
        let mut editor = editor("sanitize_indirect_info.pdf");
        let report = editor
            .sanitize_document(RedactionOptions::default())
            .expect("the document sanitizes");
        // Non-vacuity: the scrub must have removed something, or the assertion
        // below would pass on a call that did nothing at all.
        assert!(
            report.annotations_removed > 0,
            "the scrub must do real work"
        );

        let bytes = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        let text = String::from_utf8_lossy(&bytes);

        assert!(
            text.contains("INDIRECT SECRET"),
            "upstream now drops the objects an /Info value points at"
        );
        // The control: the direct half of the same dictionary really is gone.
        assert!(
            !text.contains("(Ada)"),
            "upstream must still replace /Info itself"
        );
    }

    #[test]
    fn upstream_still_drops_six_report_fields_when_aggregating() {
        let mut editor = editor("redact.pdf");
        // The destructive page set is the marked pages plus the pages carrying
        // a queued region. A `/Redact` annotation alone marks nothing, so
        // without this the pass is a no-op and the assertions below are vacuous.
        editor.apply_page_redactions(0).expect("page 0 is marked");
        let report = editor
            .apply_redactions_destructive(Default::default())
            .expect("the page redacts");

        assert!(report.glyphs_removed > 0, "the fixture must lose glyphs");
        for (name, value) in [
            ("images_modified", report.images_modified),
            ("images_removed", report.images_removed),
            ("paths_pruned", report.paths_pruned),
            ("xobjects_specialized", report.xobjects_specialized),
            ("annotations_removed", report.annotations_removed),
            ("fonts_scrubbed", report.fonts_scrubbed),
        ] {
            assert_eq!(
                value, 0,
                "upstream now aggregates {name}, so the report struct gains it"
            );
        }
    }

    #[test]
    fn upstream_still_keeps_a_queued_region_after_unmarking() {
        let mut editor = editor("redact.pdf");
        editor
            .add_redaction(1, [95.0, 695.0, 250.0, 725.0], None)
            .expect("the region is queued");
        editor.unmark_page_for_redaction(1);

        let report = editor
            .apply_redactions_destructive(Default::default())
            .expect("the pages redact");

        // Page 1 is no longer in `apply_redactions_pages`, but the queued
        // region keeps it in the destructive page set on its own.
        assert_eq!(
            report.regions, 1,
            "upstream now drops a queued region when its page is unmarked"
        );
        assert!(
            report.glyphs_removed > 0,
            "the queued region must cover text"
        );
    }

    #[test]
    fn upstream_still_copies_object_stream_containers_without_gc() {
        let mut editor = editor("sanitize_objstm.pdf");
        editor
            .sanitize_document(RedactionOptions::default())
            .expect("the document sanitizes");

        let leaky = editor
            .save_to_bytes_with_options(SaveOptions {
                garbage_collect: false,
                ..uncompressed()
            })
            .expect("the editor writes");
        let leaked = String::from_utf8_lossy(&leaky);

        // The fixture's /ObjStm is uncompressed, so the scrubbed values are
        // plain bytes in the copied-out container.
        assert!(
            leaked.contains("OBJSTMTITLE"),
            "upstream now drops the orphaned object stream container"
        );
        assert!(
            leaked.contains("app.alert"),
            "the JavaScript comes back too"
        );

        // The control: collecting drops the container, which is why the
        // refusal names garbage collection as the remedy.
        let collected = editor
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        assert!(
            !String::from_utf8_lossy(&collected).contains("OBJSTMTITLE"),
            "the default save must still strip the scrubbed /Info"
        );
    }

    #[test]
    fn upstream_still_ignores_q_on_the_text_state() {
        // The tail of the word at 24pt; at the stale 1pt nothing reaches it.
        let tail = [145.0, 695.0, 185.0, 730.0];

        let mut diverging = editor("redact_qq_text_state.pdf");
        diverging
            .add_redaction(0, tail, None)
            .expect("the region is queued");

        let report = diverging
            .apply_redactions_destructive(RedactionOptions::default())
            .expect("upstream reports success");

        assert_eq!(
            report.glyphs_removed, 0,
            "upstream now restores the text state on Q"
        );

        let bytes = diverging
            .save_to_bytes_with_options(uncompressed())
            .expect("the editor writes");
        assert!(
            String::from_utf8_lossy(&bytes).contains("Secret"),
            "upstream now restores the text state on Q"
        );

        // The control arm, and the reason the guard is a difference rather than
        // a pattern: the same q/Q with the font re-set afterwards measures right.
        let mut control = editor("redact_qq_text_state.pdf");
        control
            .add_redaction(1, tail, None)
            .expect("the region is queued");

        assert_eq!(
            control
                .apply_redactions_destructive(RedactionOptions::default())
                .expect("the control page redacts")
                .glyphs_removed,
            4
        );
    }

    // The other half of the same defect, and the one a parameter comparison
    // misses: a discarded *leading* moves the line and the parameters agree
    // again afterwards, so only `line_matrix` shows it.
    #[test]
    fn upstream_still_moves_the_line_by_a_restored_leading() {
        let shown = [100.0, 766.0, 200.0, 790.0];

        for page in [2, 3] {
            let mut doc = editor("redact_qq_text_state.pdf");
            doc.add_redaction(page, shown, None)
                .expect("the region is queued");

            assert_eq!(
                doc.apply_redactions_destructive(RedactionOptions::default())
                    .expect("upstream reports success")
                    .glyphs_removed,
                0,
                "upstream now restores the leading on Q (page {page})"
            );
        }
    }
}
