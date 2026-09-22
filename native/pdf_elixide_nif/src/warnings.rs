// Bounded per-document and process-wide structured warning buffers.

use std::{
    ops::{Deref, DerefMut},
    sync::{Mutex, MutexGuard},
};

use pdf_oxide::{
    extractors::warnings::{drain_global_warnings, Warning, WarningCategory},
    PdfDocument,
};
use rustler::{NifMap, NifResult, NifUnitEnum};

use crate::{ring::Ring, search::SearchRuns};

#[derive(NifUnitEnum, Debug)]
enum WarningCategoryNif {
    SpecViolation,
    ToUnicodeMissing,
    XrefRecovery,
    OperatorCapExceeded,
    Type3Font,
    EofPremature,
    Encryption,
    Font,
    Layout,
    GlyphDropped,
    NoTextLayer,
    ImageSuppressed,
    Unknown,
}

impl From<WarningCategory> for WarningCategoryNif {
    fn from(category: WarningCategory) -> Self {
        match category {
            WarningCategory::SpecViolation => Self::SpecViolation,
            WarningCategory::ToUnicodeMissing => Self::ToUnicodeMissing,
            WarningCategory::XrefRecovery => Self::XrefRecovery,
            WarningCategory::OperatorCapExceeded => Self::OperatorCapExceeded,
            WarningCategory::Type3Font => Self::Type3Font,
            WarningCategory::EofPremature => Self::EofPremature,
            WarningCategory::Encryption => Self::Encryption,
            WarningCategory::Font => Self::Font,
            WarningCategory::Layout => Self::Layout,
            WarningCategory::GlyphDropped => Self::GlyphDropped,
            WarningCategory::NoTextLayer => Self::NoTextLayer,
            WarningCategory::ImageSuppressed => Self::ImageSuppressed,
            // `#[non_exhaustive]` upstream: an unmodelled category reaches a
            // caller as `:unknown` rather than as one it is not.
            _ => Self::Unknown,
        }
    }
}

#[derive(NifMap, Debug)]
pub(crate) struct WarningNif {
    category: WarningCategoryNif,
    page: Option<usize>,
    message: String,
    spec_section: Option<String>,
}

impl From<Warning> for WarningNif {
    fn from(warning: Warning) -> Self {
        Self {
            category: warning.category.into(),
            page: warning.page,
            message: warning.message,
            spec_section: warning.spec_section.map(str::to_string),
        }
    }
}

// A bounded, poison-tolerant store, used both process-wide and per document
// handle. Nothing in it may panic: it runs after every native call.
pub(crate) struct Buffer(Mutex<Ring<Warning>>);

impl Buffer {
    pub(crate) const fn new() -> Self {
        Self(Mutex::new(Ring::new()))
    }

    fn lock(&self) -> MutexGuard<'_, Ring<Warning>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    // Drain and append atomically to preserve batch order.
    // Lock order: this buffer, then the source; sources must not call back.
    pub(crate) fn absorb(&self, fetch: impl FnOnce() -> Vec<Warning>) {
        let mut ring = self.lock();
        for warning in fetch() {
            ring.push(warning);
        }
    }

    // Absorbs and snapshots under the one lock, and reports the entries
    // discarded since the previous listing, so each drop is reported once.
    pub(crate) fn collect(&self, fetch: impl FnOnce() -> Vec<Warning>) -> (Vec<Warning>, usize) {
        let mut ring = self.lock();
        for warning in fetch() {
            ring.push(warning);
        }
        let dropped = ring.take_dropped();

        (ring.iter().cloned().collect(), dropped)
    }

    pub(crate) fn snapshot(&self) -> Vec<Warning> {
        self.lock().iter().cloned().collect()
    }

    pub(crate) fn take(&self) -> (Vec<Warning>, usize) {
        self.lock().take()
    }
}

// The warning mirror shares the document lifetime and is filled after each access.
pub(crate) struct OpenDocument {
    pub(crate) doc: PdfDocument,
    pub(crate) warnings: Buffer,
    pub(crate) search_runs: SearchRuns,
}

impl OpenDocument {
    pub(crate) fn new(doc: PdfDocument) -> Self {
        Self {
            doc,
            warnings: Buffer::new(),
            search_runs: SearchRuns::new(),
        }
    }

    // Every per-document read below claims the process-wide sink first, because
    // upstream's take drains that sink into whichever document is asked. The
    // claim stays outside `Buffer::absorb`, which holds the mirror's lock while
    // `fetch` runs.
    pub(crate) fn drain(&self) {
        collect_global();
        self.warnings.absorb(|| self.doc.take_structured_warnings());
    }

    // Listing: claims first, per `drain` above.
    pub(crate) fn collect(&self) -> (Vec<Warning>, usize) {
        collect_global();

        self.warnings
            .collect(|| self.doc.take_structured_warnings())
    }

    // Re-authentication: claims first, per `drain` above. Old sink then the
    // re-parse's, so the mirror keeps the order they were raised in.
    pub(crate) fn absorb_reparse(&self, fresh: &PdfDocument) {
        collect_global();
        self.warnings.absorb(|| self.doc.take_structured_warnings());
        self.warnings.absorb(|| fresh.take_structured_warnings());
    }
}

impl Deref for OpenDocument {
    type Target = PdfDocument;

    fn deref(&self) -> &Self::Target {
        &self.doc
    }
}

impl DerefMut for OpenDocument {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.doc
    }
}

static GLOBAL: Buffer = Buffer::new();

// Drain after every `Closable` access, even when warnings are never listed.
pub(crate) fn collect_global() {
    GLOBAL.absorb(drain_global_warnings);
}

// Drain on both success and error for calls without a `Closable`.
pub(crate) fn drained<R>(f: impl FnOnce() -> NifResult<R>) -> NifResult<R> {
    let result = f();
    collect_global();

    result
}

pub(crate) fn to_nif(warnings: Vec<Warning>) -> Vec<WarningNif> {
    warnings.into_iter().map(WarningNif::from).collect()
}

// Dirty for the bulk clone and encode of up to `MAX_BUFFERED` entries of
// unbounded message length; takes no resource lock.
#[rustler::nif(schedule = "DirtyCpu")]
fn warnings_snapshot() -> Vec<WarningNif> {
    to_nif(GLOBAL.snapshot())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn warnings_take() -> (Vec<WarningNif>, usize) {
    let (warnings, dropped) = GLOBAL.take();

    (to_nif(warnings), dropped)
}

#[cfg(test)]
mod tests {
    use pdf_oxide::extractors::warnings::push_global_warning;

    use super::*;
    use crate::ring::MAX_BUFFERED;

    fn warning(message: &str) -> Warning {
        Warning {
            category: WarningCategory::Font,
            page: None,
            message: message.to_string(),
            spec_section: None,
        }
    }

    fn messages(warnings: &[Warning]) -> Vec<&str> {
        warnings.iter().map(|w| w.message.as_str()).collect()
    }

    fn fixture(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../test/fixtures")
            .join(name)
    }

    // The right column is what `NifUnitEnum` derives from our own variant
    // names, so one table pins both spellings. A failure is a decision, not a
    // deletion: following upstream renames a documented atom.
    #[test]
    fn upstream_still_spells_every_category_the_way_our_atoms_do() {
        for (category, atom) in [
            (WarningCategory::SpecViolation, "spec_violation"),
            (WarningCategory::ToUnicodeMissing, "to_unicode_missing"),
            (WarningCategory::XrefRecovery, "xref_recovery"),
            (
                WarningCategory::OperatorCapExceeded,
                "operator_cap_exceeded",
            ),
            (WarningCategory::Type3Font, "type3_font"),
            (WarningCategory::EofPremature, "eof_premature"),
            (WarningCategory::Encryption, "encryption"),
            (WarningCategory::Font, "font"),
            (WarningCategory::Layout, "layout"),
            (WarningCategory::GlyphDropped, "glyph_dropped"),
            (WarningCategory::NoTextLayer, "no_text_layer"),
            (WarningCategory::ImageSuppressed, "image_suppressed"),
        ] {
            assert_eq!(
                category.as_str(),
                atom,
                "upstream renamed a category string every binding shares"
            );
        }
    }

    #[test]
    fn collect_absorbs_then_snapshots_and_snapshot_does_not_drain() {
        let buffer = Buffer::new();
        buffer.absorb(|| vec![warning("first")]);

        let (seen, dropped) = buffer.collect(|| vec![warning("second")]);
        assert_eq!(messages(&seen), ["first", "second"]);
        assert_eq!(dropped, 0);

        let (again, _) = buffer.collect(Vec::new);
        assert_eq!(messages(&again), ["first", "second"]);
        assert_eq!(messages(&buffer.snapshot()), ["first", "second"]);
    }

    #[test]
    fn collect_reports_each_drop_once() {
        let buffer = Buffer::new();
        buffer.absorb(|| {
            (0..MAX_BUFFERED + 3)
                .map(|i| warning(&format!("warning {i}")))
                .collect()
        });

        let (seen, dropped) = buffer.collect(Vec::new);
        assert_eq!(seen.len(), MAX_BUFFERED);
        assert_eq!(dropped, 3);

        let (again, dropped) = buffer.collect(|| vec![warning("late")]);
        assert_eq!(again.len(), MAX_BUFFERED);
        assert_eq!(again.last().map(|w| w.message.as_str()), Some("late"));
        assert_eq!(dropped, 1);
    }

    #[test]
    fn fetch_runs_while_the_buffer_lock_is_held() {
        let buffer = Buffer::new();

        buffer.absorb(|| {
            assert!(
                matches!(
                    buffer.0.try_lock(),
                    Err(std::sync::TryLockError::WouldBlock)
                ),
                "the buffer was unlocked while fetch ran"
            );
            vec![warning("fetched")]
        });

        assert_eq!(messages(&buffer.snapshot()), ["fetched"]);
    }

    #[test]
    fn drain_moves_the_document_sink_into_the_mirror() {
        let open = OpenDocument::new(
            PdfDocument::open(fixture("warnings_header_at_eof.pdf")).expect("fixture opens"),
        );
        assert!(open
            .load_object(pdf_oxide::object::ObjectRef { id: 5, gen: 0 })
            .is_err());
        assert!(!open.doc.take_structured_warnings().is_empty());

        assert!(open
            .load_object(pdf_oxide::object::ObjectRef { id: 5, gen: 0 })
            .is_err());
        open.drain();

        assert!(open.doc.take_structured_warnings().is_empty());
        let mirrored = open.warnings.snapshot();
        assert!(!mirrored.is_empty());
        assert!(mirrored
            .iter()
            .all(|w| w.category == WarningCategory::EofPremature));
    }

    // Use BadArg: building an atom without a BEAM aborts the test process.
    #[test]
    fn drained_collects_on_the_error_path() {
        push_global_warning(warning("sentinel for drained"));

        let result = drained(|| Err::<(), _>(rustler::Error::BadArg));

        assert!(result.is_err());
        assert!(messages(&GLOBAL.snapshot()).contains(&"sentinel for drained"));
    }

    // The claim in `OpenDocument` goes when this fails, not the assertion.
    #[test]
    fn upstream_still_merges_the_global_sink_into_a_document_read() {
        let doc = PdfDocument::open(fixture("sample.pdf")).expect("fixture opens");
        push_global_warning(warning("sentinel for the merge canary"));

        let taken = doc.take_structured_warnings();

        assert!(
            messages(&taken).contains(&"sentinel for the merge canary"),
            "upstream stopped merging the process-wide sink into a document read"
        );
    }

    #[test]
    fn drain_leaves_a_process_wide_entry_to_global() {
        let open =
            OpenDocument::new(PdfDocument::open(fixture("sample.pdf")).expect("fixture opens"));
        push_global_warning(warning("sentinel for the split"));

        open.drain();

        assert!(messages(&GLOBAL.snapshot()).contains(&"sentinel for the split"));
        assert!(!messages(&open.warnings.snapshot()).contains(&"sentinel for the split"));
    }

    // Other tests may append to the process-wide sinks concurrently.
    #[test]
    fn collect_global_moves_upstream_entries_into_the_buffer() {
        push_global_warning(warning("sentinel for collect_global"));

        collect_global();

        assert!(messages(&GLOBAL.snapshot()).contains(&"sentinel for collect_global"));
        assert!(
            !messages(&pdf_oxide::extractors::warnings::snapshot_global_warnings())
                .contains(&"sentinel for collect_global")
        );
    }
}
