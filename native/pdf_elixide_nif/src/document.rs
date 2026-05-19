use std::sync::Mutex;

use pdf_oxide::PdfDocument;
use rustler::{Binary, NifResult, ResourceArc};

use crate::{
    error::{lock_err, to_nif_err},
    DocumentResource,
};

/// Opens a PDF document from the specified file path.
#[rustler::nif(schedule = "DirtyIo")]
fn document_open(path: String) -> NifResult<ResourceArc<DocumentResource>> {
    let doc = PdfDocument::open(path).map_err(to_nif_err)?;

    Ok(ResourceArc::new(DocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Opens a PDF document from the given binary data.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_from_bytes(bytes: Binary) -> NifResult<ResourceArc<DocumentResource>> {
    let doc = PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;

    Ok(ResourceArc::new(DocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Returns the number of pages in the PDF document.
#[rustler::nif]
fn document_page_count(resource: ResourceArc<DocumentResource>) -> NifResult<usize> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.page_count().map_err(to_nif_err)?)
}

/// Returns the PDF specification version as a `(major, minor)` tuple.
#[rustler::nif]
fn document_version(resource: ResourceArc<DocumentResource>) -> NifResult<(u8, u8)> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.version())
}

/// Extracts text content from a single page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_text(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<String> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    doc.extract_text(page_index).map_err(to_nif_err)
}
