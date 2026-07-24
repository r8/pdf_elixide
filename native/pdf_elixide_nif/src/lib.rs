use std::sync::Mutex;

use pdf_oxide::{editor::DocumentEditor, extractors::PdfImage, PdfDocument};

mod char;
mod color;
mod document;
mod editor;
mod error;
mod form;
mod geometry;
mod images;
mod outline;
mod paths;
mod span;
mod table;
mod text_line;
mod word;

// Atoms ------------------------------------------------------------------------------------------

pub(crate) mod atoms {
    rustler::atoms! {
        ok, error,
        button, text, choice, signature, unknown,
        // Path operation tags (see paths.rs / PdfElixide.Document.Path)
        move_to, line_to, curve_to, rectangle, close_path,
        // Raw image data tags (see images.rs / PdfElixide.Document.Image.data/1)
        jpeg, raw,
        // Error reason tags (see error.rs / PdfElixide.Error)
        encrypted, wrong_password, invalid_pdf, unsupported,
        not_found, out_of_range, io, lock_poisoned, other
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

struct ImageResource {
    image: PdfImage,
}

#[rustler::resource_impl]
impl rustler::Resource for ImageResource {}

// ------------------------------------------------------------------------------------------------

rustler::init!("Elixir.PdfElixide.Native");
