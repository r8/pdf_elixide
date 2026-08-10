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

// Return the handle and its cached version atomically.
type OpenedEditor = (ResourceArc<EditorResource>, (u8, u8));

// Read after constructing `Closable` so the cached value is panic-contained.
fn cached_version(resource: &EditorResource) -> NifResult<(u8, u8)> {
    resource.editor.with_read(|editor| Ok(editor.version()))
}

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

// Shared and live because the native call takes `&self` and may change over time.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_page_count(resource: ResourceArc<EditorResource>) -> NifResult<usize> {
    resource
        .editor
        .with_read(|editor| Ok(editor.current_page_count()))
}

// Shared for the same reason as `editor_page_count`: upstream's `is_modified`
// takes `&self`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_is_modified(resource: ResourceArc<EditorResource>) -> NifResult<bool> {
    resource.editor.with_read(|editor| Ok(editor.is_modified()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_close(resource: ResourceArc<EditorResource>) -> Atom {
    resource.editor.close();

    atoms::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_closed(resource: ResourceArc<EditorResource>) -> bool {
    resource.editor.is_closed()
}

// Failed builds are not cached, so malformed trees fail consistently.
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

// Guard the write itself: hiding signatures from reads does not stop a caller
// naming one directly, and any value would replace its `/V` dictionary.
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

// `Option<T>` preserves the public `ArgumentError` contract for malformed
// non-nil values while allowing nil to clear a field.
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
