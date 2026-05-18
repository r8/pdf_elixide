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

rustler::init!("Elixir.PdfElixide.Native");
