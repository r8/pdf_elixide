mod annotations;
mod barcode;
mod base14;
mod binary;
mod builder;
mod certificate_files;
mod char;
mod color;
mod compliance;
mod create;
mod document;
mod editor;
mod embedded_files;
mod error;
mod extract_options;
mod flow;
mod fonts;
mod form;
mod form_tree;
mod fs_path;
mod geometry;
mod images;
mod logging;
mod merge;
mod metadata;
mod office;
mod open_document;
mod open_editor;
mod optional_content;
mod outline;
mod page_label;
mod pages;
mod paths;
mod redaction;
mod rendering;
mod resource;
mod ring;
mod running_regions;
mod save;
mod search;
mod signatures;
mod span;
mod split;
mod structured;
mod table;
mod text_line;
mod text_state;
mod text_string;
mod warnings;
mod word;

pub(crate) mod atoms {
    rustler::atoms! {
        ok,
        // Log levels (see logging.rs / PdfElixide.Logging)
        off, error, warn, info, debug, trace,
        // Path operation tags (see paths.rs / PdfElixide.Document.Path)
        move_to, line_to, curve_to, rectangle, close_path,
        // Raw image data tags (see images.rs / PdfElixide.Document.Image.data/1)
        jpeg, raw,
        // Font encoding tags (see fonts.rs / PdfElixide.Document.Font)
        standard, custom, identity,
        // Verdict tags (see signatures.rs / PdfElixide.Signature.verify/2 and the
        // timestamp checks)
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

rustler::init!("Elixir.PdfElixide.Native");
