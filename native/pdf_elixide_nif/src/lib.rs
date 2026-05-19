use std::sync::Mutex;

use pdf_oxide::PdfDocument;

mod document;
mod error;

// Atoms ------------------------------------------------------------------------------------------

mod atoms {
    rustler::atoms! {
        ok, error
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
