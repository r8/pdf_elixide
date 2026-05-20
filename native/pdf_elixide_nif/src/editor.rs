use std::sync::Mutex;

use pdf_oxide::editor::DocumentEditor;
use rustler::{Binary, NifResult, ResourceArc};

use crate::{
    error::{lock_err, to_nif_err},
    form::{editor_form_field_to_nif, FieldNif},
    EditorResource,
};

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
