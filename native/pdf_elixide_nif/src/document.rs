use std::sync::Mutex;

use pdf_oxide::{extractors::forms::FormExtractor, PdfDocument};
use rustler::{Binary, NifMap, NifResult, ResourceArc};

use crate::{
    error::{lock_err, to_nif_err},
    form::{document_form_field_to_nif, FieldNif},
    DocumentResource,
};

#[derive(NifMap, Debug)]
pub struct OpenOptionsNif {
    pub password: Option<String>,
}

impl OpenOptionsNif {
    fn apply(self, doc: &PdfDocument) -> NifResult<()> {
        if let Some(pw) = self.password {
            let ok = doc.authenticate(pw.as_bytes()).map_err(to_nif_err)?;
            if !ok {
                return Err(rustler::Error::Term(Box::new(
                    "Authentication failed: wrong password".to_string(),
                )));
            }
        }
        Ok(())
    }
}

/// Opens a PDF document from the specified file path.
#[rustler::nif(schedule = "DirtyIo")]
fn document_open(
    path: String,
    options: OpenOptionsNif,
) -> NifResult<ResourceArc<DocumentResource>> {
    let doc = PdfDocument::open(path).map_err(to_nif_err)?;
    options.apply(&doc)?;

    Ok(ResourceArc::new(DocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Opens a PDF document from the given binary data.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_from_bytes(
    bytes: Binary,
    options: OpenOptionsNif,
) -> NifResult<ResourceArc<DocumentResource>> {
    let doc = PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;
    options.apply(&doc)?;

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

/// Extracts form fields from the PDF document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_form_fields(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<FieldNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let fields = FormExtractor::extract_fields(&doc).map_err(to_nif_err)?;
    Ok(fields.into_iter().map(document_form_field_to_nif).collect())
}

/// Returns whether the PDF document is encrypted.
#[rustler::nif]
fn document_is_encrypted(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.is_encrypted())
}

/// Authenticates against the document's encryption with the given password.
/// Returns `Ok(true)` on success (or if the PDF is not encrypted),
/// `Ok(false)` if the password was invalid.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_authenticate(
    resource: ResourceArc<DocumentResource>,
    password: Binary,
) -> NifResult<bool> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    doc.authenticate(password.as_slice()).map_err(to_nif_err)
}
