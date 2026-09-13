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

use crate::ring::Ring;

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
}

impl OpenDocument {
    pub(crate) fn new(doc: PdfDocument) -> Self {
        Self {
            doc,
            warnings: Buffer::new(),
        }
    }

    pub(crate) fn drain(&self) {
        self.warnings.absorb(|| self.doc.take_structured_warnings());
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
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../test/fixtures/warnings_header_at_eof.pdf");
        let open = OpenDocument::new(PdfDocument::open(fixture).expect("fixture opens"));
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
