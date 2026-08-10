use std::sync::OnceLock;

use pdf_oxide::editor::{DocumentEditor, EditableDocument, SaveOptions};
use rustler::{Atom, Binary, NifMap, NifResult, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    error::{tagged_err, to_form_err, to_nif_err},
    form::{editor_form_field_to_nif, set_value_from_nif, FieldNif, FieldValueNif},
    form_tree::{self, SignatureNames},
    fs_path::path_arg,
    resource::Closable,
    EditorResource,
};

#[derive(NifMap, Debug)]
pub struct SaveOptionsNif {
    pub incremental: bool,
    pub compress: bool,
    pub linearize: bool,
    pub garbage_collect: bool,
}

impl From<SaveOptionsNif> for SaveOptions {
    fn from(o: SaveOptionsNif) -> Self {
        SaveOptions {
            incremental: o.incremental,
            compress: o.compress,
            linearize: o.linearize,
            garbage_collect: o.garbage_collect,
            encryption: None,
        }
    }
}

/// What both open NIFs hand back: the handle, plus the one field
/// `%PdfElixide.Editor{}` caches at open, in one call. Same shape and same
/// reasoning as `OpenedDocument` (`document.rs`), including when it should
/// become a `NifMap`.
type OpenedEditor = (ResourceArc<EditorResource>, (u8, u8));

/// Reads the field `%PdfElixide.Editor{}` caches at open.
///
/// The read goes through `with_read` rather than reading the `DocumentEditor`
/// before it is moved into the `Closable`, so it stays inside `contain_panic`.
/// Nothing is swallowed the way `cached_fields` swallows an unreadable page
/// count: `version()` is infallible upstream, so the only failure reachable here
/// is a panic, and failing the open is the honest answer to that.
fn cached_version(resource: &EditorResource) -> NifResult<(u8, u8)> {
    resource.editor.with_read(|editor| Ok(editor.version()))
}

/// Opens an editor over the PDF at the given file path.
#[rustler::nif(schedule = "DirtyIo")]
fn editor_open(path: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::open(path_arg(path)?).map_err(to_nif_err)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
        signature_names: OnceLock::new(),
    });
    let version = cached_version(&resource)?;

    Ok((resource, version))
}

/// Opens an editor over the given PDF bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_bytes(bytes: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
        signature_names: OnceLock::new(),
    });
    let version = cached_version(&resource)?;

    Ok((resource, version))
}

/// Shared where every mutating editor NIF is exclusive: upstream's
/// `current_page_count` takes `&self`, so nothing here needs to exclude a
/// concurrent reader. Deliberately not cached on the Elixir struct the way the
/// version is — upstream recomputes it on every call, and the page-mutating
/// methods that would move it are not bound here yet.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_page_count(resource: ResourceArc<EditorResource>) -> NifResult<usize> {
    // `EditableDocument::page_count` would take `&mut self` and return a
    // `Result` for trait-shape reasons alone, delegating straight to this.
    resource
        .editor
        .with_read(|editor| Ok(editor.current_page_count()))
}

/// Shared for the same reason as `editor_page_count`: upstream's `is_modified`
/// takes `&self`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_is_modified(resource: ResourceArc<EditorResource>) -> NifResult<bool> {
    resource.editor.with_read(|editor| Ok(editor.is_modified()))
}

/// Releases the editor's native memory now, rather than waiting for the BEAM to
/// garbage-collect the handle. Idempotent; later calls on the handle fail with
/// `:closed`, and any unsaved edits are discarded. Takes the editor lock, so it
/// waits for an in-flight call on the same handle to return rather than
/// interrupting it — see [`Closable::close`](crate::resource::Closable::close).
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_close(resource: ResourceArc<EditorResource>) -> Atom {
    resource.editor.close();

    atoms::ok()
}

/// Returns whether the editor has been released with `editor_close`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_closed(resource: ResourceArc<EditorResource>) -> bool {
    resource.editor.is_closed()
}

/// The signature names of the editor's source document, built once per handle —
/// see the `EditorResource` field in `lib.rs` for what makes one build enough.
///
/// A failed build is not cached, so a malformed field tree reports the same
/// verdict on every call rather than a remembered one.
fn signature_names<'a>(
    resource: &'a EditorResource,
    editor: &DocumentEditor,
) -> NifResult<&'a SignatureNames> {
    if let Some(names) = resource.signature_names.get() {
        return Ok(names);
    }

    let names = form_tree::signature_names(editor.source())?;

    Ok(resource.signature_names.get_or_init(|| names))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_form_fields(resource: ResourceArc<EditorResource>) -> NifResult<Vec<FieldNif>> {
    resource.editor.with_lock(|editor| {
        // By name, because a `FormFieldWrapper` carries no `object_ref`. The
        // document path filters the same names, so the two sources agree.
        let signatures = signature_names(&resource, editor)?;
        let fields = editor.get_form_fields().map_err(to_nif_err)?;

        Ok(fields
            .into_iter()
            .filter(|field| !signatures.contains(field.name()))
            .filter_map(editor_form_field_to_nif)
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_to_bytes(
    resource: ResourceArc<EditorResource>,
    options: SaveOptionsNif,
) -> NifResult<OwnedBinary> {
    resource.editor.with_lock(|editor| {
        let bytes = editor
            .save_to_bytes_with_options(options.into())
            .map_err(to_nif_err)?;

        owned_binary(&bytes, "editor")
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn editor_save(
    resource: ResourceArc<EditorResource>,
    path: Binary,
    options: SaveOptionsNif,
) -> NifResult<Atom> {
    // Decoded before the lock: rejecting a path needs no editor, and an
    // exclusive guard serializes every other call on the handle.
    let path = path_arg(path)?;

    resource.editor.with_lock(|editor| {
        editor
            .save_with_options(&path, options.into())
            .map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

/// Refuses a write to a `/Sig` field, which would destroy the signature.
///
/// **Not redundant with `field_nif` dropping signature fields from
/// `Form.fields/1`.** Upstream matches `set_form_field_value` on the full name
/// whatever the extractor reported, so a caller naming one directly still
/// reaches the write.
///
/// **Every write is destructive, not just a `nil`**, so don't narrow this to one:
/// upstream reads a signature dictionary `/V` as no value at all and then inserts
/// `/V` unconditionally, so any value replaces the dictionary just as thoroughly.
///
/// The names come from the source document, which is the list the write matches
/// against, and cover a `/Sig` typed only on an ancestor — see `form_tree.rs`,
/// which also resolves a duplicated name the way the write resolves it: first
/// match wins.
///
/// It reports `:not_found` so all four public functions tell one story.
fn ensure_not_signature(signatures: &SignatureNames, name: &str) -> NifResult<()> {
    if signatures.contains(name) {
        // Upstream's own spelling carries an "Invalid PDF: " prefix its `Display`
        // prepends; this matches what `Form.field/2` builds in Elixir instead.
        // The two `:not_found` messages already differ across the read side, so
        // the atom is the whole of the contract.
        return Err(tagged_err(
            atoms::not_found(),
            format!("Form field not found: {name}"),
        ));
    }

    Ok(())
}

/// The `Option` is what makes a malformed value an `ArgumentError`: rustler's
/// `Option<T>` decoder discards `T`'s own error and answers `BadArg` for every
/// non-`nil` term, so an unrecognized shape raises rather than reaching Elixir
/// as an `%Error{}`. Removing it — splitting out a clears-the-field variant,
/// say — would silently change the exception type callers see. That decoding
/// runs before the body, so a bad value on a signature field still raises rather
/// than reaching `ensure_not_signature`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_form_field_value(
    resource: ResourceArc<EditorResource>,
    name: String,
    value: Option<FieldValueNif>,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Inside the guard, so check and write cannot straddle another writer.
        ensure_not_signature(signature_names(&resource, editor)?, &name)?;

        editor
            .set_form_field_value(&name, set_value_from_nif(value))
            .map_err(to_form_err)?;

        Ok(atoms::ok())
    })
}
