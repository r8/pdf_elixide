use std::sync::Mutex;

use pdf_oxide::PdfDocument;
use rustler::{Binary, Error, NifResult, ResourceArc};

// Atoms ------------------------------------------------------------------------------------------

mod atoms {
    rustler::atoms! {
        ok, error
    }
}

// Resources --------------------------------------------------------------------------------------

struct PdfDocumentResource {
    doc: Mutex<PdfDocument>,
}

#[rustler::resource_impl]
impl rustler::Resource for PdfDocumentResource {}

// Helpers ----------------------------------------------------------------------------------------

/// Converts any `Display` value into a Rustler `Error::Term`.
fn to_nif_err(e: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(e.to_string()))
}

/// Creates a standard "Lock is poisoned" error for poisoned mutexes.
fn lock_err() -> Error {
    Error::Term(Box::new("Lock is poisoned".to_string()))
}

// PdfDocument operations -------------------------------------------------------------------------

/// Opens a PDF document from the specified file path.
#[rustler::nif(schedule = "DirtyIo")]
fn open(path: String) -> NifResult<ResourceArc<PdfDocumentResource>> {
    let doc = PdfDocument::open(path).map_err(to_nif_err)?;

    Ok(ResourceArc::new(PdfDocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Opens a PDF document from the given binary data.
#[rustler::nif(schedule = "DirtyCpu")]
fn from_bytes(bytes: Binary) -> NifResult<ResourceArc<PdfDocumentResource>> {
    let doc = PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;

    Ok(ResourceArc::new(PdfDocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Returns the number of pages in the PDF document.
#[rustler::nif]
fn page_count(resource: ResourceArc<PdfDocumentResource>) -> NifResult<usize> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.page_count().map_err(to_nif_err)?)
}

/// Returns the PDF specification version as a `(major, minor)` tuple.
#[rustler::nif]
fn version(resource: ResourceArc<PdfDocumentResource>) -> NifResult<(u8, u8)> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.version())
}

rustler::init!("Elixir.PdfElixide.Native");
