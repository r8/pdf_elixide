use std::sync::OnceLock;

use pdf_oxide::editor::{DocumentEditor, EditableDocument, SaveOptions};
use rustler::{Atom, Binary, NifMap, NifResult, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    error::{tagged_err, to_form_err, to_nif_err},
    form::{editor_form_field_to_nif, set_value_from_nif, FieldNif, FieldValueNif},
    form_tree::{self, Resolved},
    fs_path::path_arg,
    resource::Closable,
    EditorResource,
};

#[derive(NifMap, Debug)]
pub struct SaveOptionsNif {
    pub incremental: bool,
    pub compress: bool,
    pub garbage_collect: bool,
}

impl From<SaveOptionsNif> for SaveOptions {
    fn from(o: SaveOptionsNif) -> Self {
        SaveOptions {
            incremental: o.incremental,
            compress: o.compress,
            // Upstream reads this nowhere; spelled out so the literal stays exhaustive.
            linearize: false,
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
        resolved_fields: OnceLock::new(),
    });
    let version = cached_version(&resource)?;

    Ok((resource, version))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_bytes(bytes: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
        resolved_fields: OnceLock::new(),
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
fn resolved_fields<'a>(
    resource: &'a EditorResource,
    editor: &DocumentEditor,
) -> NifResult<&'a Resolved> {
    if let Some(resolved) = resource.resolved_fields.get() {
        return Ok(resolved);
    }

    let resolved = form_tree::resolved(editor.source())?;

    Ok(resource.resolved_fields.get_or_init(|| resolved))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_form_fields(resource: ResourceArc<EditorResource>) -> NifResult<Vec<FieldNif>> {
    resource.editor.with_lock(|editor| {
        // By name, because a `FormFieldWrapper` carries no `object_ref`. The
        // document path resolves the same names, so the two sources agree.
        let resolved = resolved_fields(&resource, editor)?;
        let fields = editor.get_form_fields().map_err(to_nif_err)?;

        Ok(fields
            .into_iter()
            .filter(|field| !resolved.is_signature(field.name()))
            .filter_map(|field| {
                let attrs = resolved.attrs(field.name());

                editor_form_field_to_nif(field, attrs)
            })
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
fn ensure_not_signature(resolved: &Resolved, name: &str) -> NifResult<()> {
    if resolved.is_signature(name) {
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
        ensure_not_signature(resolved_fields(&resource, editor)?, &name)?;

        editor
            .set_form_field_value(&name, set_value_from_nif(value))
            .map_err(to_form_err)?;

        Ok(atoms::ok())
    })
}

// Upstream bounds-checks both per-page flattens but reports a bad index as a
// generic `InvalidPdf`, so the check is repeated here to reach `:out_of_range`.
// The editor's count is live rather than cached, so it must be read per call.
fn ensure_editor_page_in_range(editor: &DocumentEditor, page_index: usize) -> NifResult<()> {
    let count = editor.current_page_count();
    if page_index >= count {
        return Err(tagged_err(
            atoms::out_of_range(),
            format!("Page index {page_index} out of range (editor has {count} pages)"),
        ));
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_forms(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        editor.flatten_forms().map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_forms_on_page(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Inside the guard so the check and the mark cannot straddle a writer
        // that changes the page count.
        ensure_editor_page_in_range(editor, page_index)?;

        editor
            .flatten_forms_on_page(page_index)
            .map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_all_annotations(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        editor.flatten_all_annotations().map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_page_annotations(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;

        editor
            .flatten_page_annotations(page_index)
            .map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

// Shared because upstream's accessor takes `&self`; the slice must be cloned
// since the guard drops at the closure boundary.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_warnings(resource: ResourceArc<EditorResource>) -> NifResult<Vec<String>> {
    resource
        .editor
        .with_read(|editor| Ok(editor.flatten_warnings().to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    fn saved_with(linearize: bool) -> Vec<u8> {
        let mut editor = DocumentEditor::open(fixture("form.pdf")).expect("fixture opens");

        editor
            .save_to_bytes_with_options(SaveOptions {
                linearize,
                ..SaveOptions::full_rewrite()
            })
            .expect("full rewrite")
    }

    #[test]
    fn upstream_still_ignores_the_linearize_save_option() {
        let linearized = saved_with(true);

        assert!(!linearized.is_empty(), "the fixture writes something");
        assert_eq!(linearized, saved_with(false));
    }
}
