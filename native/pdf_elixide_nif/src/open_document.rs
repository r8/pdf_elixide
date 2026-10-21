// The document handle's value: the parsed document with the state that lives
// as long as it does.

use std::ops::{Deref, DerefMut};

use pdf_oxide::{extractors::warnings::Warning, PdfDocument};
use rustler::{Binary, NifMap, NifResult};

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
    search::SearchRuns,
    warnings::{collect_global, Buffer},
};

// PDF passwords are raw bytes and may not be valid UTF-8. Do not derive `Debug`
// for a type that contains one.
#[derive(NifMap)]
pub(crate) struct OpenOptionsNif<'a> {
    pub(crate) password: Option<Binary<'a>>,
}

impl OpenOptionsNif<'_> {
    // A rejected password is `Ok(false)`, so synthesize the reason atom here.
    pub(crate) fn apply(self, doc: &PdfDocument) -> NifResult<()> {
        if let Some(pw) = self.password {
            let ok = doc.authenticate(pw.as_slice()).map_err(to_nif_err)?;
            if !ok {
                return Err(tagged_err(
                    atoms::wrong_password(),
                    "Authentication failed: wrong password",
                ));
            }
        }
        Ok(())
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
