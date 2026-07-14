use std::sync::Mutex;

use pdf_oxide::{editor::DocumentEditor, PdfDocument};

mod document;
mod editor;
mod error;
mod form;
mod word;

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

struct EditorResource {
    editor: Mutex<DocumentEditor>,
}

#[rustler::resource_impl]
impl rustler::Resource for EditorResource {}

// ------------------------------------------------------------------------------------------------

rustler::init!("Elixir.PdfElixide.Native");
