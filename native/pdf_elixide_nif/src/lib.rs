use std::sync::Mutex;

use pdf_oxide::PdfDocument;

mod document;
mod error;
mod form;

// Atoms ------------------------------------------------------------------------------------------

pub(crate) mod atoms {
    rustler::atoms! {
        ok, error,
        button, text, choice, signature, unknown
    }
}

// Resources --------------------------------------------------------------------------------------

struct DocumentResource {
    doc: Mutex<PdfDocument>,
}

#[rustler::resource_impl]
impl rustler::Resource for DocumentResource {}

// ------------------------------------------------------------------------------------------------

rustler::init!("Elixir.PdfElixide.Native");
