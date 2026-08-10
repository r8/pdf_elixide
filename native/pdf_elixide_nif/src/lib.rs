use std::sync::{Arc, OnceLock};

use pdf_oxide::{
    editor::DocumentEditor, extractors::PdfImage, fonts::FontInfo,
    structure::table_extractor::Table, PdfDocument,
};

use crate::{form_tree::SignatureNames, resource::Closable};

mod annotations;
mod binary;
mod char;
mod color;
mod document;
mod editor;
mod error;
mod extract_options;
mod fonts;
mod form;
mod form_tree;
mod fs_path;
mod geometry;
mod images;
mod metadata;
mod optional_content;
mod outline;
mod paths;
mod resource;
mod search;
mod span;
mod table;
mod text_line;
mod word;

// Atoms ------------------------------------------------------------------------------------------

pub(crate) mod atoms {
    rustler::atoms! {
        ok, error,
        // Path operation tags (see paths.rs / PdfElixide.Document.Path)
        move_to, line_to, curve_to, rectangle, close_path,
        // Raw image data tags (see images.rs / PdfElixide.Document.Image.data/1)
        jpeg, raw,
        // Font encoding tags (see fonts.rs / PdfElixide.Document.Font)
        standard, custom, identity,
        // Error reason tags (see error.rs / PdfElixide.Error)
        encrypted, wrong_password, invalid_pdf, invalid_pattern, unsupported,
        not_found, out_of_range, io, lock_poisoned, panic, closed, other
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
    /// The signature names of the editor's *source* document, built on first use
    /// (see `signature_names` in editor.rs).
    ///
    /// Cacheable only because nothing bound touches `DocumentEditor::source`. A
    /// NIF that edits the source document, or adds or removes a form field,
    /// invalidates this and must clear it.
    signature_names: OnceLock<SignatureNames>,
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

struct TableResource {
    table: Closable<Table>,
}

#[rustler::resource_impl]
impl rustler::Resource for TableResource {}

// ------------------------------------------------------------------------------------------------

rustler::init!("Elixir.PdfElixide.Native");
