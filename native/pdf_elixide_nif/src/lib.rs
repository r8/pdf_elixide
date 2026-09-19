use std::sync::Arc;

use pdf_oxide::{extractors::PdfImage, fonts::FontInfo, structure::table_extractor::Table};

use crate::{open_editor::OpenEditor, resource::Closable, warnings::OpenDocument};

mod annotations;
mod binary;
mod char;
mod color;
mod document;
mod editor;
mod embedded_files;
mod error;
mod extract_options;
mod fonts;
mod form;
mod form_tree;
mod fs_path;
mod geometry;
mod images;
mod logging;
mod metadata;
mod open_editor;
mod optional_content;
mod outline;
mod paths;
mod redaction;
mod rendering;
mod resource;
mod ring;
mod search;
mod signatures;
mod span;
mod structured;
mod table;
mod text_line;
mod text_state;
mod warnings;
mod word;

pub(crate) mod atoms {
    rustler::atoms! {
        ok, error,
        // Log levels (see logging.rs / PdfElixide.Logging)
        off, warn, info, debug, trace,
        // Path operation tags (see paths.rs / PdfElixide.Document.Path)
        move_to, line_to, curve_to, rectangle, close_path,
        // Raw image data tags (see images.rs / PdfElixide.Document.Image.data/1)
        jpeg, raw,
        // Font encoding tags (see fonts.rs / PdfElixide.Document.Font)
        standard, custom, identity,
        // Signature verdict tags (see signatures.rs / PdfElixide.Signature.verify/2)
        valid, invalid, unknown,
        // PAdES baseline levels (see signatures.rs / PdfElixide.Signature.pades_level/2)
        b_b, b_t, b_lt,
        // Timestamp hash algorithms (see signatures.rs / PdfElixide.Signature.Timestamp)
        sha1, sha256, sha384, sha512,
        // Error reason tags (see error.rs / PdfElixide.Error)
        encrypted, wrong_password, invalid_pdf, invalid_pattern, unsupported,
        not_found, out_of_range, io, lock_poisoned, panic, closed, other
    }
}

// Every resource wraps its value in a `Closable`, which owns the locking and
// supports releasing the value early (see resource.rs and the `*_close` NIFs).

struct DocumentResource {
    doc: Closable<OpenDocument>,
}

#[rustler::resource_impl]
impl rustler::Resource for DocumentResource {}

struct EditorResource {
    editor: Closable<OpenEditor>,
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

rustler::init!("Elixir.PdfElixide.Native");
