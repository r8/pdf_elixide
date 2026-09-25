use std::{
    collections::HashSet,
    ops::{Deref, DerefMut, Range},
    sync::OnceLock,
};

use pdf_oxide::{
    editor::{DocumentEditor, EditableDocument},
    writer::EmbeddedFile,
    PdfDocument,
};
use rustler::NifResult;

use crate::{
    document::read_crop_box,
    form_tree::{self, Resolved},
    merge::{
        declares_structure, on_import_stack, root_declares_resources, Incoming, MergeError,
        PageAttrs,
    },
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
    applied: Option<AppliedPass>,
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
    // Records staged XMP removal; the source catalog is unchanged until save.
    xmp_scrubbed: bool,
    // Set once a merge has replaced the editor with one built from bytes, which
    // an incremental save cannot append to. Never cleared.
    merged: bool,
    // The replacement starts unmodified; this reports the merge until a full
    // write carries it.
    merge_unsaved: bool,
    // The replaced editor's flatten warnings, which upstream offers no way to
    // hand to its successor.
    carried_warnings: Vec<String>,
    // Upstream's flatten warnings from a merge snapshot that did not land, which
    // upstream never clears and the next write reports again.
    discarded_warnings: Vec<Range<usize>>,
}

// Upstream keeps every region and mark a pass applied, so what that pass covered
// has to be recorded to tell it from what was queued or marked since.
struct AppliedPass {
    // Source pages marked when the pass ran.
    marked: HashSet<usize>,
    // Source pages given a region after it.
    queued_since: HashSet<usize>,
    // False until the pass finishes; after an error its committed pages are unknown.
    completed: bool,
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

#[derive(Debug)]
pub(crate) enum PageError {
    OutOfRange(OutOfRange),
    BadSelection,
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
            applied: None,
            redactions_marked: false,
            annotations_marked: false,
            forms_marked: false,
            embedded_scrubbed: false,
            javascript_scrubbed: false,
            xmp_scrubbed: false,
            merged: false,
            merge_unsaved: false,
            carried_warnings: Vec::new(),
            discarded_warnings: Vec::new(),
        }
    }

    pub(crate) fn modified(&self) -> bool {
        self.editor.is_modified() || self.merge_unsaved
    }

    pub(crate) fn merged(&self) -> bool {
        self.merged
    }

    // Only a successful full write carries a merge.
    pub(crate) fn record_full_write(&mut self) {
        self.merge_unsaved = false;
    }

    pub(crate) fn all_flatten_warnings(&self) -> Vec<String> {
        let mut warnings = self.carried_warnings.clone();
        warnings.extend(
            self.editor
                .flatten_warnings()
                .iter()
                .enumerate()
                .filter(|(index, _)| !self.discarded_warnings.iter().any(|r| r.contains(index)))
                .map(|(_, warning)| warning.clone()),
        );

        warnings
    }

    // Normalize imported pages through a snapshot so later page operations treat
    // them as ordinary pages. Build and validate the replacement before swapping it in.
    pub(crate) fn merge(&mut self, incoming: &Incoming) -> Result<usize, MergeError> {
        if incoming.pages.is_empty() {
            return Ok(0);
        }

        // A page-less snapshot reopens by scanning, which finds deleted pages.
        let count = self.pages.len();
        if count == 0 {
            return Err(MergeError::NoPages);
        }

        let every_page: Vec<usize> = (0..count).collect();
        self.check_selection(&every_page)?;
        // Decide before the snapshot, whose pending flattens append warnings.
        let takes_resources = incoming.pages.iter().position(|page| !page.owns_resources);
        if let Some(page) = takes_resources {
            if root_declares_resources(self.editor.source()) {
                return Err(MergeError::TakesDestinationResources { page });
            }
        }
        if let Some(page) = incoming.tagged_page {
            if declares_structure(self.editor.source()) {
                return Err(MergeError::CollidesWithStructure { page });
            }
        }
        let written = self.editor.flatten_warnings().len();
        let (added, fresh) = match self.merge_snapshot(incoming, &every_page, takes_resources) {
            Ok(merged) => merged,
            Err(e) => {
                let now = self.editor.flatten_warnings().len();
                if now > written {
                    self.discarded_warnings.push(written..now);
                }

                return Err(e);
            }
        };

        let fixes = inheritance_fixes(fresh.source(), count, &incoming.pages);
        let carried_warnings = self.all_flatten_warnings();
        *self = Self {
            merged: true,
            merge_unsaved: true,
            carried_warnings,
            ..Self::new(fresh)
        };

        for (index, fix) in fixes {
            if let Some(rotation) = fix.rotation {
                self.write_rotation(index, rotation)?;
            }
            if let Some(media_box) = fix.media_box {
                self.write_media_box(index, media_box)?;
            }
            if let Some(crop_box) = fix.crop_box {
                self.write_crop_box(index, crop_box)?;
            }
        }

        Ok(added)
    }

    // Discard warnings appended by a snapshot that fails to land.
    fn merge_snapshot(
        &mut self,
        incoming: &Incoming,
        every_page: &[usize],
        takes_resources: Option<usize>,
    ) -> Result<(usize, DocumentEditor), MergeError> {
        // Avoid `extract_pages`, whose resupply would make a failed merge modified.
        // State drained by the snapshot is restored on the scratch editor.
        self.editor.clear_embedded_files();
        let snapshot = self.editor.extract_pages_to_bytes(every_page)?;

        let info = self.seeded_info();
        let info = has_info_text(&info).then(|| to_document_info(&info));
        let embedded = &self.embedded;
        let (added, fresh) = on_import_stack(|| {
            let mut scratch = DocumentEditor::from_bytes(snapshot)?;
            for file in embedded {
                scratch.embed_file_with_options(file.clone())?;
            }
            if let Some(info) = info {
                scratch.set_info(info)?;
            }
            let added = scratch.merge_from_bytes(&incoming.bytes)?;
            let fresh = DocumentEditor::from_bytes(scratch.save_to_bytes()?)?;

            Ok((added, fresh))
        })?;

        let count = every_page.len();
        let expected = count + incoming.pages.len();
        let got = fresh.current_page_count();
        if added != incoming.pages.len() || got != expected {
            return Err(MergeError::Miscount { expected, got });
        }

        // A backstop, should the written root ever gain resources the source's lacked.
        if let Some(page) = takes_resources {
            if root_declares_resources(fresh.source()) {
                return Err(MergeError::TakesDestinationResources { page });
            }
        }

        Ok((added, fresh))
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

    // Validate before mutation: rebuilding the mirror requires unique indices,
    // and unreadable pages must not be silently omitted.
    pub(crate) fn check_selection(&self, pages: &[usize]) -> Result<(), PageError> {
        if pages.is_empty() {
            return Err(PageError::BadSelection);
        }

        let count = self.pages.len();
        let mut seen = HashSet::with_capacity(pages.len());
        for &index in pages {
            if index >= count {
                return Err(OutOfRange { index, count }.into());
            }
            if !seen.insert(index) {
                return Err(PageError::BadSelection);
            }
        }

        self.check_readable(pages.iter().copied())
    }

    // `check_selection` for the inclusive `first..=last`, without materializing
    // it: the bounds must be known before a caller-sized range is allocated.
    // Inclusive so a range ending at `usize::MAX` needs no `+ 1` to reach here.
    pub(crate) fn check_span(&self, first: usize, last: usize) -> Result<(), PageError> {
        if last < first {
            return Err(PageError::BadSelection);
        }

        let count = self.pages.len();
        if last >= count {
            return Err(OutOfRange {
                index: first.max(count),
                count,
            }
            .into());
        }

        self.check_readable(first..=last)
    }

    fn check_readable(&self, indices: impl Iterator<Item = usize>) -> Result<(), PageError> {
        for index in indices {
            self.editor.source().get_page(self.pages[index].source)?;
        }

        Ok(())
    }

    // Keep the upstream page order and binding mirror in one operation.
    pub(crate) fn keep_pages(&mut self, pages: &[usize]) -> Result<(), PageError> {
        self.check_selection(pages)?;
        self.editor.select_pages(pages)?;

        // Dropping a page leaves the same gap between output and source
        // indices a deletion does, which whole-document marks must re-map.
        if pages.len() < self.pages.len() {
            self.pages_deleted = true;
        }

        let mut entries: Vec<Option<PageEdits>> = std::mem::take(&mut self.pages)
            .into_iter()
            .map(Some)
            .collect();
        self.pages = pages
            .iter()
            .filter_map(|&index| entries[index].take())
            .collect();

        Ok(())
    }

    // Re-supply state that a full write drains or omits before every extraction.
    // Callers validate first, with `check_selection` or `check_span`, so a bad
    // selection is reported before the rewrite refusals they check in between; a
    // repeated index would reach upstream, which writes the page twice.
    pub(crate) fn extract_pages(&mut self, pages: &[usize]) -> Result<Vec<u8>, PageError> {
        self.resupply_embedded()?;
        self.resupply_info()?;

        Ok(self.editor.extract_pages_to_bytes(pages)?)
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
            if let Some(pass) = &mut self.applied {
                pass.queued_since.insert(page.source);
            }
        }
        self.mark(Marked::Redactions);

        Ok(())
    }

    pub(crate) fn queued_redactions(&self) -> &HashSet<usize> {
        &self.redaction_regions
    }

    // Visible pages carrying a queued region or a redaction mark no pass has
    // applied, as `(output, source, queued)`. The mark predicate scans
    // `page_order` per page, so that sweep is gated on the category ever having
    // been marked.
    pub(crate) fn pages_pending_redaction(&self) -> Vec<(usize, usize, bool)> {
        self.pages
            .iter()
            .enumerate()
            .filter_map(|(output, page)| {
                let queued = match &self.applied {
                    None => self.redaction_regions.contains(&page.source),
                    Some(pass) => pass.queued_since.contains(&page.source),
                };
                let marked = self.redactions_marked
                    && self.editor.is_page_marked_for_redaction(output)
                    && self
                        .applied
                        .as_ref()
                        .is_none_or(|pass| !pass.marked.contains(&page.source));

                (queued || marked).then_some((output, page.source, queued))
            })
            .collect()
    }

    pub(crate) fn applied_redactions(&self) -> bool {
        self.applied.is_some()
    }

    // Arm before applying: an error can leave pages rewritten.
    pub(crate) fn arm_redaction(&mut self) {
        let marked = self
            .pages
            .iter()
            .enumerate()
            .filter(|&(output, _)| {
                self.redactions_marked && self.editor.is_page_marked_for_redaction(output)
            })
            .map(|(_, page)| page.source)
            .collect();

        self.redacted = true;
        self.applied = Some(AppliedPass {
            marked,
            queued_since: HashSet::new(),
            completed: false,
        });
    }

    pub(crate) fn complete_redaction(&mut self) {
        if let Some(pass) = &mut self.applied {
            pass.completed = true;
        }
    }

    pub(crate) fn failed_redaction(&self) -> bool {
        self.applied.as_ref().is_some_and(|pass| !pass.completed)
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
            self.xmp_scrubbed = true;
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

    pub(crate) fn xmp_scrubbed(&self) -> bool {
        self.xmp_scrubbed
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

// Materialize inherited attributes that the destination would change. Use the
// media box to cancel a crop box newly inherited from the destination.
struct PageFix {
    rotation: Option<i32>,
    media_box: Option<[f32; 4]>,
    crop_box: Option<[f32; 4]>,
}

fn inheritance_fixes(
    merged: &PdfDocument,
    first: usize,
    wanted: &[PageAttrs],
) -> Vec<(usize, PageFix)> {
    let mut fixes = Vec::new();

    for (offset, want) in wanted.iter().enumerate() {
        let index = first + offset;
        let rotation = merged.get_page_rotation(index).ok();
        let media_box = merged
            .get_page_media_box(index)
            .ok()
            .map(|(llx, lly, urx, ury)| [llx, lly, urx, ury]);
        let crop_box = read_crop_box(merged, index).ok();

        let fix = PageFix {
            rotation: (rotation != Some(want.rotation)).then_some(want.rotation),
            media_box: (media_box != Some(want.media_box)).then_some(want.media_box),
            crop_box: (crop_box != Some(want.crop_box))
                .then_some(want.crop_box.unwrap_or(want.media_box)),
        };

        if fix.rotation.is_some() || fix.media_box.is_some() || fix.crop_box.is_some() {
            fixes.push((index, fix));
        }
    }

    fixes
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
    fn a_selection_reorders_the_mirror_and_reports_what_it_dropped() {
        let mut editor = open("sample.pdf");
        editor.write_rotation(0, 90).expect("rotation written");

        editor.keep_pages(&[2, 0]).expect("pages kept");

        assert_eq!(editor.source_pages(), [2, 0]);
        assert_eq!(editor.effective_rotation(1).ok(), Some(90));
        assert!(editor.pages_deleted());
        assert_eq!(
            editor.dropped_by_an_incremental_save(),
            ["page deletions", "page moves", "page rotations"]
        );
    }

    #[test]
    fn selecting_every_page_in_order_leaves_nothing_to_report() {
        let mut editor = open("sample.pdf");

        editor.keep_pages(&[0, 1, 2]).expect("pages kept");

        assert!(!editor.pages_deleted());
        assert!(editor.dropped_by_an_incremental_save().is_empty());
    }

    #[test]
    fn a_repeated_or_empty_selection_is_refused_before_upstream_runs() {
        let mut editor = open("sample.pdf");

        assert!(matches!(
            editor.keep_pages(&[1, 1]),
            Err(PageError::BadSelection)
        ));
        assert!(matches!(
            editor.keep_pages(&[]),
            Err(PageError::BadSelection)
        ));
        assert!(matches!(
            editor.keep_pages(&[0, 3]),
            Err(PageError::OutOfRange(OutOfRange { index: 3, count: 3 }))
        ));
        assert_eq!(editor.source_pages(), [0, 1, 2]);
        assert!(!editor.is_modified());
    }

    #[test]
    fn a_span_is_bounded_without_being_materialized() {
        let editor = open("sample.pdf");

        assert!(editor.check_span(1, 2).is_ok());
        assert!(editor.check_span(2, 2).is_ok());
        assert!(matches!(
            editor.check_span(2, 1),
            Err(PageError::BadSelection)
        ));
        assert!(matches!(
            editor.check_span(0, usize::MAX),
            Err(PageError::OutOfRange(OutOfRange { index: 3, count: 3 }))
        ));
        assert!(matches!(
            editor.check_span(5, 9),
            Err(PageError::OutOfRange(OutOfRange { index: 5, count: 3 }))
        ));
    }

    #[test]
    fn a_page_the_source_cannot_resolve_is_refused() {
        let mut editor = open("broken_page.pdf");

        assert!(matches!(
            editor.keep_pages(&[0, 2]),
            Err(PageError::Upstream(_))
        ));
        assert_eq!(editor.source_pages(), [0, 1, 2]);
        assert!(editor.check_selection(&[1, 0]).is_ok());
    }

    // No fixture fails a merge after its snapshot, so the incoming bytes are
    // ones `prepare` would never accept.
    #[test]
    fn a_merge_failing_after_its_snapshot_discards_the_snapshot_flatten_warnings() {
        let mut editor = open("flatten_root_resources.pdf");
        editor.flatten_forms().expect("forms marked");
        let incoming = Incoming {
            bytes: b"not a pdf".to_vec(),
            pages: vec![PageAttrs {
                rotation: 0,
                media_box: [0.0, 0.0, 612.0, 792.0],
                crop_box: None,
                owns_resources: true,
            }],
            tagged_page: None,
        };

        assert!(editor.merge(&incoming).is_err());
        assert!(editor.all_flatten_warnings().is_empty());

        editor.save_to_bytes().expect("editor writes");
        assert_eq!(editor.all_flatten_warnings().len(), 1);
    }

    #[test]
    fn page_properties_and_erases_are_reported_by_visible_page() {
        let mut editor = open("sample.pdf");
        editor.write_rotation(0, 90).expect("rotation written");
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
