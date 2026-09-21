use std::{
    collections::HashSet,
    ops::{Deref, DerefMut},
    sync::OnceLock,
};

use pdf_oxide::{
    editor::{DocumentEditor, EditableDocument},
    writer::EmbeddedFile,
};
use rustler::NifResult;

use crate::{
    document::read_crop_box,
    form_tree::{self, Resolved},
    metadata::{has_info_text, read_metadata, to_document_info, MetadataNif},
};

// Upstream's editor plus the mirrors that compensate for what it keeps private
// or drops on a write, inside the `Closable` so every mirror shares its guard.
pub(crate) struct OpenEditor {
    editor: DocumentEditor,
    // Cacheable while no bound operation mutates the source document or fields.
    resolved_fields: OnceLock<Resolved>,
    // Visible pages in output order, including pending rotations and boxes.
    pages: Vec<PageEdits>,
    // Re-supplied after full writes drain the editor's pending list.
    embedded: Vec<EmbeddedFile>,
    // Caller-visible `/Info` values once a setter has run; `None` answers from
    // the source.
    info: Option<MetadataNif>,
    // Source pages carrying a queued region — the half of upstream's destructive
    // page set nothing exposes. It only grows: a region cannot be withdrawn.
    redaction_regions: HashSet<usize>,
    // Pending erase overlays by source page; `clear_erase` removes entries.
    erased_regions: HashSet<usize>,
    // Set after a deletion so whole-document flattens re-mark surviving pages
    // through the mapped per-page methods.
    pages_deleted: bool,
    // Set once a destructive redaction or sanitization has rewritten content,
    // which an incremental save carries none of.
    redacted: bool,
    // Set once a sanitization has scrubbed the catalog, which only a collecting
    // write completes.
    sanitized: bool,
    // Set once a destructive pass has run; a second one is refused from here on.
    applied_redactions: bool,
    // Monotonic scan gates, not current marks: marks can be removed or their
    // pages deleted. Each flag skips a quadratic scan of an untouched category.
    redactions_marked: bool,
    annotations_marked: bool,
    forms_marked: bool,
    // Set once sanitization dropped the source's embedded-file name tree, which
    // the editor otherwise keeps listing from `source()`.
    embedded_scrubbed: bool,
    // Set once sanitization dropped the source's JavaScript name tree. With
    // `embedded_scrubbed`, the whole record of what the staged catalog lost.
    javascript_scrubbed: bool,
}

// A visible page's source identity and pending properties in output order.
struct PageEdits {
    source: usize,
    rotation: Option<i32>,
    media_box: Option<[f32; 4]>,
    crop_box: Option<[f32; 4]>,
}

pub(crate) enum Marked {
    Redactions,
    Annotations,
    Forms,
}

// A visible index the mirror does not hold. Carried as data so the atom is
// built at the NIF boundary.
#[derive(Debug, PartialEq)]
pub(crate) struct OutOfRange {
    pub(crate) index: usize,
    pub(crate) count: usize,
}

// What a page read or write can fail with, for the same reason as `OutOfRange`.
pub(crate) enum PageError {
    OutOfRange(OutOfRange),
    Upstream(pdf_oxide::Error),
}

impl From<OutOfRange> for PageError {
    fn from(e: OutOfRange) -> Self {
        PageError::OutOfRange(e)
    }
}

impl From<pdf_oxide::Error> for PageError {
    fn from(e: pdf_oxide::Error) -> Self {
        PageError::Upstream(e)
    }
}

impl OpenEditor {
    // At open, visible and source page indices are identical.
    pub(crate) fn new(editor: DocumentEditor) -> Self {
        let pages = (0..editor.current_page_count())
            .map(|source| PageEdits {
                source,
                rotation: None,
                media_box: None,
                crop_box: None,
            })
            .collect();

        Self {
            editor,
            resolved_fields: OnceLock::new(),
            pages,
            embedded: Vec::new(),
            info: None,
            redaction_regions: HashSet::new(),
            erased_regions: HashSet::new(),
            pages_deleted: false,
            redacted: false,
            sanitized: false,
            applied_redactions: false,
            redactions_marked: false,
            annotations_marked: false,
            forms_marked: false,
            embedded_scrubbed: false,
            javascript_scrubbed: false,
        }
    }

    // Failed builds are not cached, so malformed trees fail consistently. The
    // `&mut` upstream half comes back too: every caller needs both, and one
    // borrow of `self` cannot give them.
    pub(crate) fn resolved_fields(&mut self) -> NifResult<(&Resolved, &mut DocumentEditor)> {
        let Self {
            editor,
            resolved_fields,
            ..
        } = self;

        let resolved = match resolved_fields.get() {
            Some(resolved) => resolved,
            None => {
                let built = form_tree::resolved(editor.source())?;

                resolved_fields.get_or_init(|| built)
            }
        };

        Ok((resolved, editor))
    }

    // The mirror's length, not `current_page_count`: every mirror-bounded write
    // is bounded by this.
    pub(crate) fn visible_page_count(&self) -> usize {
        self.pages.len()
    }

    // The visible pages as source indices, in output order — the index space
    // upstream keys its destructive redaction set by.
    pub(crate) fn source_pages(&self) -> Vec<usize> {
        self.pages.iter().map(|page| page.source).collect()
    }

    pub(crate) fn source_page(&self, page_index: usize) -> Result<usize, OutOfRange> {
        self.pending(page_index, |_| None::<()>)
            .map(|(source, _)| source)
    }

    fn pending<T: Copy>(
        &self,
        page_index: usize,
        pick: impl FnOnce(&PageEdits) -> Option<T>,
    ) -> Result<(usize, Option<T>), OutOfRange> {
        let page = self.pages.get(page_index).ok_or(OutOfRange {
            index: page_index,
            count: self.pages.len(),
        })?;

        Ok((page.source, pick(page)))
    }

    // Record only after a successful write.
    fn record<T: Copy>(
        &mut self,
        page_index: usize,
        value: T,
        write: impl FnOnce(&mut DocumentEditor, usize, T) -> pdf_oxide::error::Result<()>,
        slot: impl FnOnce(&mut PageEdits) -> &mut Option<T>,
    ) -> Result<(), PageError> {
        let count = self.pages.len();
        let page = self.pages.get_mut(page_index).ok_or(OutOfRange {
            index: page_index,
            count,
        })?;

        write(&mut self.editor, page_index, value)?;
        *slot(page) = Some(value);

        Ok(())
    }

    pub(crate) fn delete_page(&mut self, page_index: usize) -> pdf_oxide::error::Result<()> {
        self.editor.remove_page(page_index)?;
        self.pages_deleted = true;
        self.pages.remove(page_index);

        Ok(())
    }

    // Shadows upstream's `move_page` on purpose: the mirror is indexed by
    // visible position, so it must take the same permutation, and a NIF must
    // not be able to call one half without the other.
    pub(crate) fn move_page(&mut self, from: usize, to: usize) -> pdf_oxide::error::Result<()> {
        self.editor.move_page(from, to)?;
        let page = self.pages.remove(from);
        self.pages.insert(to, page);

        Ok(())
    }

    pub(crate) fn pages_deleted(&self) -> bool {
        self.pages_deleted
    }

    // `source()` is the pre-edit document, so an unchanged rotation must be
    // read at the recorded source index rather than at the visible one.
    pub(crate) fn effective_rotation(&self, page_index: usize) -> Result<i32, PageError> {
        let (source, set) = self.pending(page_index, |page| page.rotation)?;

        match set {
            Some(rotation) => Ok(rotation),
            None => Ok(self.editor.source().get_page_rotation(source)?),
        }
    }

    pub(crate) fn write_rotation(
        &mut self,
        page_index: usize,
        degrees: i32,
    ) -> Result<(), PageError> {
        self.record(
            page_index,
            degrees,
            DocumentEditor::set_page_rotation,
            |page| &mut page.rotation,
        )
    }

    // Read unchanged boxes from the source to preserve inheritance and indirection.
    pub(crate) fn effective_media_box(&self, page_index: usize) -> Result<[f32; 4], PageError> {
        let (source, set) = self.pending(page_index, |page| page.media_box)?;

        match set {
            Some(media_box) => Ok(media_box),
            None => Ok(self
                .editor
                .source()
                .get_page_media_box(source)
                .map(|(llx, lly, urx, ury)| [llx, lly, urx, ury])?),
        }
    }

    pub(crate) fn effective_crop_box(
        &self,
        page_index: usize,
    ) -> Result<Option<[f32; 4]>, PageError> {
        let (source, set) = self.pending(page_index, |page| page.crop_box)?;

        match set {
            Some(crop_box) => Ok(Some(crop_box)),
            None => Ok(read_crop_box(self.editor.source(), source)?),
        }
    }

    pub(crate) fn write_media_box(
        &mut self,
        page_index: usize,
        corners: [f32; 4],
    ) -> Result<(), PageError> {
        self.record(
            page_index,
            corners,
            DocumentEditor::set_page_media_box,
            |page| &mut page.media_box,
        )
    }

    pub(crate) fn write_crop_box(
        &mut self,
        page_index: usize,
        corners: [f32; 4],
    ) -> Result<(), PageError> {
        self.record(
            page_index,
            corners,
            DocumentEditor::set_page_crop_box,
            |page| &mut page.crop_box,
        )
    }

    // Every marking NIF must enable its category's scan.
    pub(crate) fn mark(&mut self, what: Marked) {
        let flag = match what {
            Marked::Redactions => &mut self.redactions_marked,
            Marked::Annotations => &mut self.annotations_marked,
            Marked::Forms => &mut self.forms_marked,
        };

        *flag = true;
    }

    pub(crate) fn erase(
        &mut self,
        page_index: usize,
        corners: &[[f32; 4]],
    ) -> pdf_oxide::error::Result<()> {
        self.editor.erase_regions(page_index, corners)?;

        // Mirror successful calls by source page, including empty slices:
        // upstream records those too. The mirror must match the visible pages.
        debug_assert_eq!(self.pages.len(), self.editor.current_page_count());
        if let Some(page) = self.pages.get(page_index) {
            self.erased_regions.insert(page.source);
        }

        Ok(())
    }

    pub(crate) fn clear_erase(&mut self, page_index: usize) {
        self.editor.clear_erase_regions(page_index);

        if let Some(page) = self.pages.get(page_index) {
            self.erased_regions.remove(&page.source);
        }
    }

    // Upstream keys the region by the source page and marks that page too;
    // only the mark can be taken back, so the region is the half `apply` cannot
    // rediscover.
    pub(crate) fn queue_redaction(
        &mut self,
        page_index: usize,
        corners: [f32; 4],
        fill: Option<[f32; 3]>,
    ) -> pdf_oxide::error::Result<()> {
        self.editor.add_redaction(page_index, corners, fill)?;

        if let Some(page) = self.pages.get(page_index) {
            self.redaction_regions.insert(page.source);
        }
        self.mark(Marked::Redactions);

        Ok(())
    }

    pub(crate) fn queued_redactions(&self) -> &HashSet<usize> {
        &self.redaction_regions
    }

    pub(crate) fn applied_redactions(&self) -> bool {
        self.applied_redactions
    }

    // Arm before applying: an error can leave pages rewritten.
    pub(crate) fn arm_redaction(&mut self) {
        self.redacted = true;
        self.applied_redactions = true;
    }

    pub(crate) fn redacted(&self) -> bool {
        self.redacted
    }

    pub(crate) fn sanitized(&self) -> bool {
        self.sanitized
    }

    // Mirror every successful scrub so reads and later resupply match staged output.
    pub(crate) fn record_sanitize(
        &mut self,
        scrub_metadata: bool,
        remove_javascript: bool,
        remove_embedded_files: bool,
    ) {
        self.redacted = true;
        self.sanitized = true;

        if scrub_metadata {
            self.info = Some(MetadataNif::scrubbed());
        }
        if remove_javascript {
            self.javascript_scrubbed = true;
        }
        if remove_embedded_files {
            self.editor.clear_embedded_files();
            self.embedded.clear();
            self.embedded_scrubbed = true;
        }
    }

    // The entries a sanitization dropped from the catalog the writer builds on.
    pub(crate) fn scrubbed_name_tree_entries(&self) -> Vec<&'static str> {
        let mut entries = Vec::new();
        if self.embedded_scrubbed {
            entries.push("EmbeddedFiles");
        }
        if self.javascript_scrubbed {
            entries.push("JavaScript");
        }

        entries
    }

    pub(crate) fn embedded_scrubbed(&self) -> bool {
        self.embedded_scrubbed
    }

    pub(crate) fn embedded_files(&self) -> &[EmbeddedFile] {
        &self.embedded
    }

    // Upstream first: it owns `is_modified`, and the mirror must not record an
    // attachment the editor rejected.
    pub(crate) fn attach_file(&mut self, file: EmbeddedFile) -> pdf_oxide::error::Result<()> {
        self.editor.embed_file_with_options(file.clone())?;
        self.embedded.push(file);

        Ok(())
    }

    // Full writes drain pending attachments, so restore them before repeats.
    pub(crate) fn resupply_embedded(&mut self) -> pdf_oxide::error::Result<()> {
        if self.editor.pending_embedded_files().len() == self.embedded.len() {
            return Ok(());
        }

        self.editor.clear_embedded_files();
        for file in &self.embedded {
            self.editor.embed_file_with_options(file.clone())?;
        }

        Ok(())
    }

    // Supply the source's values when no setter has populated the mirror. A
    // scrub leaves it `Some(scrubbed)`, which stops the resupply: re-reading the
    // source would write the very `/Info` the caller just had removed.
    pub(crate) fn resupply_info(&mut self) -> pdf_oxide::error::Result<()> {
        if self.info.is_some() {
            return Ok(());
        }

        let info = read_metadata(self.editor.source());
        if has_info_text(&info) {
            self.editor.set_info(to_document_info(&info))?;
        }

        Ok(())
    }

    pub(crate) fn info(&self) -> Option<&MetadataNif> {
        self.info.as_ref()
    }

    // Never `get_info`: `editor.rs`'s `upstream_still_*_info_*` canaries say why.
    pub(crate) fn seeded_info(&self) -> MetadataNif {
        self.info
            .clone()
            .unwrap_or_else(|| read_metadata(self.editor.source()))
    }

    // Upstream first, as for `attach_file`. Always the whole struct, so clearing
    // the last field replaces the earlier dictionary rather than keeping it.
    pub(crate) fn write_info(&mut self, info: MetadataNif) -> pdf_oxide::error::Result<()> {
        self.editor.set_info(to_document_info(&info))?;
        self.info = Some(info);

        Ok(())
    }

    // The categories of pending edit the incremental writer silently omits, in
    // the order the editing guide lists them.
    pub(crate) fn dropped_by_an_incremental_save(&self) -> Vec<&'static str> {
        let mut dropped = Vec::new();
        let sources = self.source_pages();

        // Deleting the last page leaves survivors' source and output indices equal.
        if self.pages_deleted {
            dropped.push("page deletions");
        }

        // Deletions preserve source order; an undone move restores it.
        if !sources.is_sorted() {
            dropped.push("page moves");
        }
        if self.pages.iter().any(|page| page.rotation.is_some()) {
            dropped.push("page rotations");
        }
        if self.pages.iter().any(|page| page.media_box.is_some()) {
            dropped.push("page media boxes");
        }
        if self.pages.iter().any(|page| page.crop_box.is_some()) {
            dropped.push("page crop boxes");
        }

        // Region mirrors use source indices; ignore regions on deleted pages.
        if pending_on_a_visible_page(&sources, &self.erased_regions) {
            dropped.push("erased regions");
        }
        if pending_on_a_visible_page(&sources, &self.redaction_regions) {
            dropped.push("queued redaction regions");
        }

        // Predicates take output indices and scan page_order to map them to
        // source. Gate each quadratic sweep on whether that category was ever
        // marked.
        let any_page = |gate: bool, ask: fn(&DocumentEditor, usize) -> bool| {
            gate && (0..sources.len()).any(|page| ask(&self.editor, page))
        };

        if any_page(
            self.redactions_marked,
            DocumentEditor::is_page_marked_for_redaction,
        ) {
            dropped.push("redaction marks");
        }

        if any_page(
            self.annotations_marked,
            DocumentEditor::is_page_marked_for_flatten,
        ) {
            dropped.push("annotation flatten marks");
        }

        // Check this first to avoid a sweep and catch flattening a page-less editor.
        if self.editor.will_remove_acroform()
            || any_page(
                self.forms_marked,
                DocumentEditor::is_page_marked_for_form_flatten,
            )
        {
            dropped.push("form flatten marks");
        }

        if !self.embedded.is_empty() {
            dropped.push("attachments");
        }

        dropped
    }
}

// Avoid scanning pages when no regions were queued.
fn pending_on_a_visible_page(sources: &[usize], pending: &HashSet<usize>) -> bool {
    !pending.is_empty() && sources.iter().any(|source| pending.contains(source))
}

impl Deref for OpenEditor {
    type Target = DocumentEditor;

    fn deref(&self) -> &Self::Target {
        &self.editor
    }
}

impl DerefMut for OpenEditor {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.editor
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    fn open(name: &str) -> OpenEditor {
        OpenEditor::new(DocumentEditor::open(fixture(name)).expect("fixture opens"))
    }

    #[test]
    fn a_fresh_editor_has_nothing_an_incremental_save_drops() {
        let editor = open("sample.pdf");

        assert_eq!(editor.visible_page_count(), 3);
        assert!(editor.dropped_by_an_incremental_save().is_empty());
    }

    #[test]
    fn a_visible_index_past_the_mirror_is_out_of_range() {
        let editor = open("sample.pdf");

        assert_eq!(editor.source_page(2), Ok(2));
        assert_eq!(
            editor.source_page(3),
            Err(OutOfRange { index: 3, count: 3 })
        );
    }

    #[test]
    fn an_undone_move_restores_source_order() {
        let mut editor = open("sample.pdf");
        editor.move_page(0, 2).expect("page moved");
        assert_eq!(editor.source_pages(), [1, 2, 0]);
        assert_eq!(editor.dropped_by_an_incremental_save(), ["page moves"]);

        editor.move_page(2, 0).expect("page moved back");

        assert_eq!(editor.source_pages(), [0, 1, 2]);
        assert!(editor.dropped_by_an_incremental_save().is_empty());
    }

    #[test]
    fn a_deletion_keeps_source_order_and_reports_only_itself() {
        let mut editor = open("sample.pdf");
        editor.delete_page(1).expect("page removed");

        assert_eq!(editor.source_pages(), [0, 2]);
        assert_eq!(editor.dropped_by_an_incremental_save(), ["page deletions"]);
    }

    // The region mirror is keyed by source page, so a region on a page that is
    // no longer visible must not be reported.
    #[test]
    fn a_queued_region_on_a_deleted_page_is_not_reported() {
        let mut editor = open("sample.pdf");
        editor
            .queue_redaction(1, [10.0, 10.0, 50.0, 50.0], None)
            .expect("region queued");
        assert_eq!(
            editor.dropped_by_an_incremental_save(),
            ["queued redaction regions", "redaction marks"]
        );

        editor.delete_page(1).expect("page removed");

        assert_eq!(editor.dropped_by_an_incremental_save(), ["page deletions"]);
    }

    #[test]
    fn page_properties_and_erases_are_reported_by_visible_page() {
        let mut editor = open("sample.pdf");
        editor.write_rotation(0, 90).ok().expect("rotation written");
        editor
            .erase(2, &[[0.0, 0.0, 10.0, 10.0]])
            .expect("erase recorded");
        assert_eq!(
            editor.dropped_by_an_incremental_save(),
            ["page rotations", "erased regions"]
        );

        editor.clear_erase(2);

        assert_eq!(editor.dropped_by_an_incremental_save(), ["page rotations"]);
    }
}
