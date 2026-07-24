use std::sync::Arc;

use pdf_oxide::{editor::DocumentEditor, extractors::PdfImage, fonts::FontInfo, PdfDocument};

use crate::resource::Closable;

mod annotations;
mod char;
mod color;
mod document;
mod editor;
mod error;
mod fonts;
mod form;
mod geometry;
mod images;
mod metadata;
mod outline;
mod paths;
mod resource;
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
        // Font encoding tags (see fonts.rs / PdfElixide.Document.Font)
        standard, custom, identity,
        // Error reason tags (see error.rs / PdfElixide.Error)
        encrypted, wrong_password, invalid_pdf, unsupported,
        not_found, out_of_range, io, lock_poisoned, closed, other
    }
}

// Resources --------------------------------------------------------------------------------------
//
// Every resource wraps its value in a `Closable`, which owns the locking and
// supports releasing the value early (see resource.rs and the `*_close` NIFs).

struct DocumentResource {
    doc: Closable<PdfDocument>,
}

#[rustler::resource_impl]
impl rustler::Resource for DocumentResource {}

struct EditorResource {
    editor: Closable<DocumentEditor>,
}

#[rustler::resource_impl]
impl rustler::Resource for EditorResource {}

struct ImageResource {
    image: Closable<PdfImage>,
}

#[rustler::resource_impl]
impl rustler::Resource for ImageResource {}

struct FontResource {
    font: Closable<Arc<FontInfo>>,
}

#[rustler::resource_impl]
impl rustler::Resource for FontResource {}

// ------------------------------------------------------------------------------------------------

rustler::init!("Elixir.PdfElixide.Native");
