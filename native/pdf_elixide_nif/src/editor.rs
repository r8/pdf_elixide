use std::sync::Mutex;

use pdf_oxide::editor::{DocumentEditor, EditableDocument, SaveOptions};
use rustler::{Atom, Binary, NifMap, NifResult, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    error::{lock_err, to_nif_err},
    form::{editor_field_value_from_nif, editor_form_field_to_nif, FieldNif, FieldValueNif},
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

/// Opens a PDF document from the specified file path.
#[rustler::nif(schedule = "DirtyIo")]
fn editor_open(path: String) -> NifResult<ResourceArc<EditorResource>> {
    let editor = DocumentEditor::open(path).map_err(to_nif_err)?;

    Ok(ResourceArc::new(EditorResource {
        editor: Mutex::new(editor),
    }))
}

/// Opens a PDF document from the given binary data.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_bytes(bytes: Binary) -> NifResult<ResourceArc<EditorResource>> {
    let editor = DocumentEditor::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;

    Ok(ResourceArc::new(EditorResource {
        editor: Mutex::new(editor),
    }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_form_fields(resource: ResourceArc<EditorResource>) -> NifResult<Vec<FieldNif>> {
    let mut editor = resource.editor.lock().map_err(|_| lock_err())?;

    let fields = editor.get_form_fields().map_err(to_nif_err)?;
    Ok(fields.into_iter().map(editor_form_field_to_nif).collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_to_bytes(
    resource: ResourceArc<EditorResource>,
    options: SaveOptionsNif,
) -> NifResult<OwnedBinary> {
    let mut editor = resource.editor.lock().map_err(|_| lock_err())?;

    let bytes = editor
        .save_to_bytes_with_options(options.into())
        .map_err(to_nif_err)?;

    let mut bin = OwnedBinary::new(bytes.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("failed to allocate binary")))?;
    bin.as_mut_slice().copy_from_slice(&bytes);
    Ok(bin)
}

#[rustler::nif(schedule = "DirtyIo")]
fn editor_save(
    resource: ResourceArc<EditorResource>,
    path: String,
    options: SaveOptionsNif,
) -> NifResult<Atom> {
    let mut editor = resource.editor.lock().map_err(|_| lock_err())?;

    editor
        .save_with_options(path, options.into())
        .map_err(to_nif_err)?;

    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_form_field_value(
    resource: ResourceArc<EditorResource>,
    name: String,
    value: Option<FieldValueNif>,
) -> NifResult<Atom> {
    let mut editor = resource.editor.lock().map_err(|_| lock_err())?;

    editor
        .set_form_field_value(&name, editor_field_value_from_nif(value))
        .map_err(to_nif_err)?;

    Ok(atoms::ok())
}
