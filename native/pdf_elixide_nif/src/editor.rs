use pdf_oxide::editor::{DocumentEditor, EditableDocument, SaveOptions};
use rustler::{Atom, Binary, NifMap, NifResult, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    error::{to_form_err, to_nif_err},
    form::{editor_field_value_from_nif, editor_form_field_to_nif, FieldNif, FieldValueNif},
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

/// Opens a PDF document from the specified file path.
#[rustler::nif(schedule = "DirtyIo")]
fn editor_open(path: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::open(path_arg(path)?).map_err(to_nif_err)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
    });
    let version = cached_version(&resource)?;

    Ok((resource, version))
}

/// Opens a PDF document from the given binary data.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_bytes(bytes: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
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

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_form_fields(resource: ResourceArc<EditorResource>) -> NifResult<Vec<FieldNif>> {
    resource.editor.with_lock(|editor| {
        let fields = editor.get_form_fields().map_err(to_nif_err)?;
        Ok(fields.into_iter().map(editor_form_field_to_nif).collect())
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

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_form_field_value(
    resource: ResourceArc<EditorResource>,
    name: String,
    value: Option<FieldValueNif>,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        editor
            .set_form_field_value(&name, editor_field_value_from_nif(value))
            .map_err(to_form_err)?;

        Ok(atoms::ok())
    })
}
