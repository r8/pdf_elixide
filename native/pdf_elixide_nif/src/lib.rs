use std::sync::{atomic::AtomicBool, Arc, Mutex, OnceLock, RwLock};

use pdf_oxide::{
    editor::DocumentEditor, extractors::PdfImage, fonts::FontInfo,
    structure::table_extractor::Table, writer::EmbeddedFile, PdfDocument,
};

use crate::{editor::PageRotation, form_tree::Resolved, resource::Closable};

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
mod optional_content;
mod outline;
mod paths;
mod resource;
mod search;
mod signatures;
mod span;
mod table;
mod text_line;
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
    // Cacheable while no bound operation mutates the source document or fields.
    resolved_fields: OnceLock<Resolved>,
    // Set after a deletion so whole-document flattens re-mark surviving pages
    // through the mapped per-page methods.
    pages_deleted: AtomicBool,
    // Visible pages in output order, including pending rotations.
    pages: Mutex<Vec<PageRotation>>,
    // Re-supplied after full writes drain the editor's pending list.
    embedded: RwLock<Vec<EmbeddedFile>>,
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
