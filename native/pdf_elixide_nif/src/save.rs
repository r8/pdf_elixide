// What a write is given, and what it must refuse rather than write a file
// that ignores a setting or the editor's state.

use pdf_oxide::{
    compliance::PdfAPart,
    editor::{DocumentEditor, EncryptionAlgorithm, EncryptionConfig, Permissions, SaveOptions},
    object::Object,
    PdfDocument,
};
use rustler::{Atom, NifMap, NifResult, NifUnitEnum};

use crate::{
    atoms,
    error::tagged_err,
    open_editor::{OpenEditor, Rebuild},
};

// Variant spelling determines the public atom: `Rc4_128` yields `:rc4_128`.
#[allow(non_camel_case_types)]
#[derive(NifUnitEnum, Debug)]
pub enum EncryptionAlgorithmNif {
    Rc4_128,
    Aes128,
}

impl From<EncryptionAlgorithmNif> for EncryptionAlgorithm {
    fn from(a: EncryptionAlgorithmNif) -> Self {
        match a {
            EncryptionAlgorithmNif::Rc4_128 => EncryptionAlgorithm::Rc4_128,
            EncryptionAlgorithmNif::Aes128 => EncryptionAlgorithm::Aes128,
        }
    }
}

// The two print fields are renamed: upstream's bare `print` is the low-res bit,
// which the public names say and its own do not.
#[derive(NifMap, Debug)]
pub struct PermissionFlagsNif {
    pub print_low_res: bool,
    pub print_high_res: bool,
    pub modify: bool,
    pub copy: bool,
    pub annotate: bool,
    pub fill_forms: bool,
    pub accessibility: bool,
    pub assemble: bool,
}

impl From<PermissionFlagsNif> for Permissions {
    fn from(p: PermissionFlagsNif) -> Self {
        Permissions {
            print: p.print_low_res,
            print_high_quality: p.print_high_res,
            modify: p.modify,
            copy: p.copy,
            annotate: p.annotate,
            fill_forms: p.fill_forms,
            accessibility: p.accessibility,
            assemble: p.assemble,
        }
    }
}

// Do not derive `Debug` for this or containing types: they hold passwords.
#[derive(NifMap)]
pub struct EncryptionNif {
    pub user_password: String,
    pub owner_password: String,
    pub algorithm: EncryptionAlgorithmNif,
    pub permissions: PermissionFlagsNif,
}

impl From<EncryptionNif> for EncryptionConfig {
    fn from(e: EncryptionNif) -> Self {
        EncryptionConfig {
            user_password: e.user_password,
            owner_password: e.owner_password,
            algorithm: e.algorithm.into(),
            permissions: e.permissions.into(),
        }
    }
}

// No `Debug`: this is a containing type in the sense of `EncryptionNif` above.
#[derive(NifMap)]
pub struct SaveOptionsNif {
    pub incremental: bool,
    pub compress: bool,
    pub garbage_collect: bool,
    pub encryption: Option<EncryptionNif>,
}

impl From<SaveOptionsNif> for SaveOptions {
    fn from(o: SaveOptionsNif) -> Self {
        SaveOptions {
            incremental: o.incremental,
            compress: o.compress,
            // Upstream reads this nowhere; spelled out so the literal stays exhaustive.
            linearize: false,
            garbage_collect: o.garbage_collect,
            encryption: o.encryption.map(Into::into),
        }
    }
}

// Rustler argument decoding performs the validation.
#[rustler::nif]
fn save_options_valid(_options: SaveOptionsNif) -> Atom {
    atoms::ok()
}

// Incremental output copies the original bytes, retaining removed content.
pub(crate) fn ensure_redaction_survives_save(
    editor: &OpenEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    if options.incremental && editor.redacted() {
        return Err(tagged_err(
            atoms::unsupported(),
            "This editor has applied a destructive redaction or sanitization, which an \
             incremental save does not carry: the update would append to the original \
             bytes and leave the removed content readable. Save a full rewrite instead.",
        ));
    }

    Ok(())
}

// Refuse a rewrite that would drop cleartext XMP and leave a dangling catalog entry.
fn carries_unencryptable_metadata(editor: &OpenEditor) -> bool {
    if !editor.source().is_encrypted() || editor.xmp_scrubbed() {
        return false;
    }

    if !declares_cleartext_metadata(editor.source()) {
        return false;
    }

    carries_metadata_stream(editor.source())
}

// `/Metadata null` is absent (ISO 32000 §7.3.9), so the entry is resolved rather
// than counted: only a stream reaches the writer's decrypt-on-copy and is dropped.
fn carries_metadata_stream(doc: &PdfDocument) -> bool {
    let Ok(catalog) = doc.catalog() else {
        return false;
    };

    let Some(entry) = catalog.as_dict().and_then(|dict| dict.get("Metadata")) else {
        return false;
    };

    match doc.resolve_object(entry) {
        Ok(resolved) => matches!(resolved, Object::Stream { .. }),
        // An entry the reader cannot load is the loss this refusal is for.
        Err(_) => true,
    }
}

// An absent or unreadable `/EncryptMetadata` takes its default value, `true`.
// Either spelling may be indirect; treating that shape as absent would lose XMP.
fn declares_cleartext_metadata(doc: &PdfDocument) -> bool {
    let Some(encrypt) = doc.trailer().as_dict().and_then(|dict| dict.get("Encrypt")) else {
        return false;
    };

    let Ok(encrypt) = doc.resolve_object(encrypt) else {
        return false;
    };

    let flag = encrypt
        .as_dict()
        .and_then(|dict| dict.get("EncryptMetadata"))
        .and_then(|flag| doc.resolve_object(flag).ok());

    matches!(flag, Some(Object::Boolean(false)))
}

pub(crate) fn ensure_metadata_survives_save(
    editor: &OpenEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    // An incremental update never reaches the decrypt-on-copy, so nothing is
    // lost; encryption owns that refusal (`ensure_incremental_is_not_encrypted`).
    if options.incremental {
        return Ok(());
    }

    ensure_rewrite_keeps_metadata(editor)
}

pub(crate) fn ensure_rewrite_keeps_metadata(editor: &OpenEditor) -> NifResult<()> {
    if !carries_unencryptable_metadata(editor) {
        return Ok(());
    }

    Err(tagged_err(
        atoms::unsupported(),
        "This encrypted source stores its XMP metadata unencrypted, which cannot \
         be preserved by a rewrite. Nothing has been written. Remove the metadata \
         with sanitize(editor, scrub_metadata: true, remove_javascript: false, \
         remove_embedded_files: false), then retry.",
    ))
}

// GC must drop orphaned /ObjStm containers or their scrubbed values survive.
pub(crate) fn ensure_scrub_survives_save(
    editor: &OpenEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    if !options.garbage_collect && editor.sanitized() {
        return Err(tagged_err(
            atoms::unsupported(),
            "This editor has sanitized the document, which a write with \
             garbage_collect: false does not carry: every object the source holds \
             is copied out, including the object stream that carried the scrubbed \
             /Info, JavaScript or embedded file. Write with garbage collection \
             instead.",
        ));
    }

    Ok(())
}

// Keep this before source and pending-edit checks so encryption owns the reason.
pub(crate) fn ensure_incremental_is_not_encrypted(
    editor: &DocumentEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    if options.incremental && editor.source().is_encrypted() {
        return Err(tagged_err(
            atoms::unsupported(),
            "This encrypted source cannot be saved incrementally. Nothing has been \
             written. Save a full rewrite instead.",
        ));
    }

    Ok(())
}

// Unreachable for an encrypted source only because the encryption guard runs
// first: `editor_open`'s `EncryptedPdf` route builds through `from_document`,
// which clears the source path while Elixir keeps it, so this message would
// contradict `Editor.source_path/1` on that handle.
pub(crate) fn ensure_incremental_has_a_source(
    editor: &DocumentEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    if options.incremental && editor.source_path().is_empty() {
        return Err(tagged_err(
            atoms::unsupported(),
            "This editor was built from a binary, which an incremental save cannot \
             append to: the update is written after a verbatim copy of the file the \
             editor was opened from, and this editor has no such file. Nothing has \
             been written. Save a full rewrite instead.",
        ));
    }

    Ok(())
}

// Before `ensure_incremental_has_a_source`, whose message would otherwise call a
// path-opened editor binary-built: a merge or conversion rebuilds it from bytes.
pub(crate) fn ensure_incremental_has_no_rebuild(
    editor: &OpenEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    if !options.incremental {
        return Ok(());
    }

    let done = match editor.rebuilt() {
        None => return Ok(()),
        Some(Rebuild::Merge) => "merged another document",
        Some(Rebuild::Conversion(_)) => "been converted to PDF/A",
    };

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "This editor has {done}, which an incremental save cannot carry: the \
             update is appended to a verbatim copy of the original file. Nothing has \
             been written. Save a full rewrite instead."
        ),
    ))
}

// Preserve the constraints declared by conversion unless XMP was scrubbed.
pub(crate) fn ensure_write_keeps_conversion(
    editor: &OpenEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    let Some(level) = editor.pdf_a() else {
        return Ok(());
    };

    if options.encryption.is_some() {
        return Err(tagged_err(
            atoms::unsupported(),
            "This editor has been converted to PDF/A, which forbids encryption: the \
             written file would declare PDF/A and fail it. Nothing has been written. \
             Write without :encryption.",
        ));
    }

    // PDF/A-1 metadata streams must remain unfiltered.
    if options.compress && !options.incremental && level.part() == PdfAPart::Part1 {
        return Err(tagged_err(
            atoms::unsupported(),
            "This editor has been converted to PDF/A-1, which forbids compressing the \
             document's XMP metadata: the written file would declare PDF/A-1 and fail \
             it. Nothing has been written. Write with compress: false.",
        ));
    }

    Ok(())
}

// The incremental writer silently omits changes outside field values and /Info.
pub(crate) fn ensure_edits_survive_save(
    editor: &OpenEditor,
    options: &SaveOptionsNif,
) -> NifResult<()> {
    if !options.incremental {
        return Ok(());
    }

    let dropped = editor.dropped_by_an_incremental_save();
    if dropped.is_empty() {
        return Ok(());
    }

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "This editor holds {}, which an incremental save does not carry: the \
             update is appended to a verbatim copy of the original file, and only \
             form field values and document information reach it. Nothing has been \
             written. Save a full rewrite instead.",
            spell_out(&dropped)
        ),
    ))
}

fn spell_out(categories: &[&str]) -> String {
    match categories {
        [] => String::new(),
        [only] => (*only).to_string(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spell_out_of_nothing_is_empty() {
        assert_eq!(spell_out(&[]), "");
    }
}
