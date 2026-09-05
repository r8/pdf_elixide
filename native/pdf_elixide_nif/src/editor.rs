use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex, MutexGuard, OnceLock, RwLock, RwLockReadGuard, RwLockWriteGuard,
};

use pdf_oxide::{
    editor::{
        DocumentEditor, EditableDocument, EncryptionAlgorithm, EncryptionConfig, Permissions,
        SaveOptions,
    },
    writer::EmbeddedFile,
};
use rustler::{Atom, Binary, Env, NifMap, NifResult, NifUnitEnum, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    embedded_files::{
        embedded_file, ensure_no_name_tree, pending_to_nif, read_embedded_files, EmbeddedFileNif,
        RelationshipNif,
    },
    error::{tagged_err, to_form_err, to_nif_err},
    form::{
        editor_form_field_to_nif, export_bytes, export_form_field, is_exportable,
        set_value_from_nif, FieldNif, FieldValueNif, FormDataFormatNif,
    },
    form_tree::{self, Resolved},
    fs_path::path_arg,
    resource::Closable,
    EditorResource,
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

// Return the handle and its cached version atomically.
type OpenedEditor = (ResourceArc<EditorResource>, (u8, u8));

// Read after constructing `Closable` so the cached value is panic-contained.
fn cached_version(resource: &EditorResource) -> NifResult<(u8, u8)> {
    resource.editor.with_read(|editor| Ok(editor.version()))
}

// A visible page's source identity and optional pending rotation.
pub struct PageRotation {
    source: usize,
    set: Option<i32>,
}

// Recover poisoning like `Closable`; a contained panic must not prevent close.
fn page_rotations(resource: &EditorResource) -> MutexGuard<'_, Vec<PageRotation>> {
    resource.pages.lock().unwrap_or_else(|e| e.into_inner())
}

// The editor guard provides exclusion; this lock provides interior mutability
// and recovers poisoning like `page_rotations`.
fn embedded_files(resource: &EditorResource) -> RwLockReadGuard<'_, Vec<EmbeddedFile>> {
    resource.embedded.read().unwrap_or_else(|e| e.into_inner())
}

// The write half of `embedded_files`, reached only under the exclusive lock.
fn embedded_files_mut(resource: &EditorResource) -> RwLockWriteGuard<'_, Vec<EmbeddedFile>> {
    resource.embedded.write().unwrap_or_else(|e| e.into_inner())
}

// At open, visible and source page indices are identical.
fn seed_pages(resource: &EditorResource) -> NifResult<()> {
    resource.editor.with_read(|editor| {
        *page_rotations(resource) = (0..editor.current_page_count())
            .map(|source| PageRotation { source, set: None })
            .collect();

        Ok(())
    })
}

// Upstream's writer copies stream payloads out through `load_object` without
// decrypting them, so a save would emit ciphertext under a `/Filter` dict, omit
// `/Encrypt`, and report success. Nothing upstream guards it:
// `require_authenticated` is never called from `src/editor/`.
fn ensure_not_encrypted(editor: &DocumentEditor) -> NifResult<()> {
    if editor.source().is_encrypted() {
        return Err(tagged_err(
            atoms::encrypted(),
            "This document is encrypted. The editor cannot decrypt it, and saving it \
             would write unreadable content streams. Read it with PdfElixide.Document, \
             which takes a password.",
        ));
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyIo")]
fn editor_open(path: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::open(path_arg(path)?).map_err(to_nif_err)?;
    ensure_not_encrypted(&editor)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
        resolved_fields: OnceLock::new(),
        pages_deleted: AtomicBool::new(false),
        pages: Mutex::new(Vec::new()),
        embedded: RwLock::new(Vec::new()),
    });
    seed_pages(&resource)?;
    let version = cached_version(&resource)?;

    Ok((resource, version))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_bytes(bytes: Binary) -> NifResult<OpenedEditor> {
    let editor = DocumentEditor::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;
    ensure_not_encrypted(&editor)?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", editor),
        resolved_fields: OnceLock::new(),
        pages_deleted: AtomicBool::new(false),
        pages: Mutex::new(Vec::new()),
        embedded: RwLock::new(Vec::new()),
    });
    seed_pages(&resource)?;
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
    // Close first so no later call can observe the cleared mirror.
    resource.editor.close();
    page_rotations(&resource).clear();
    embedded_files_mut(&resource).clear();

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

// Use the merged view so unsaved field edits reach the export; obtaining it
// requires the exclusive lock.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_export_form_data(
    resource: ResourceArc<EditorResource>,
    format: FormDataFormatNif,
    file_spec: Option<String>,
) -> NifResult<OwnedBinary> {
    resource.editor.with_lock(|editor| {
        let resolved = resolved_fields(&resource, editor)?;
        let fields = editor.get_form_fields().map_err(to_nif_err)?;

        let fields = fields
            .into_iter()
            .filter_map(export_form_field)
            .filter(|field| is_exportable(field, resolved))
            .collect();

        owned_binary(&export_bytes(fields, format, file_spec)?, "form data")
    })
}

// Full writes drain pending attachments, so restore the mirror before repeats.
fn resupply_embedded(resource: &EditorResource, editor: &mut DocumentEditor) -> NifResult<()> {
    let mirror = embedded_files(resource);
    if editor.pending_embedded_files().len() == mirror.len() {
        return Ok(());
    }

    editor.clear_embedded_files();
    for file in mirror.iter() {
        editor
            .embed_file_with_options(file.clone())
            .map_err(to_nif_err)?;
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_embed_file(
    resource: ResourceArc<EditorResource>,
    name: String,
    data: Binary,
    description: Option<String>,
    relationship: Option<RelationshipNif>,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Inside the guard so the check and the push cannot straddle a writer.
        ensure_no_name_tree(editor.source())?;

        let file = embedded_file(name, data.as_slice().to_vec(), description, relationship);

        // Upstream first: it owns `is_modified`, and the mirror must not record
        // an attachment the editor rejected.
        editor
            .embed_file_with_options(file.clone())
            .map_err(to_nif_err)?;
        embedded_files_mut(&resource).push(file);

        Ok(atoms::ok())
    })
}

// Both reads are shared; mirror writes always hold the exclusive editor guard.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_embedded_files<'a>(
    env: Env<'a>,
    resource: ResourceArc<EditorResource>,
) -> NifResult<Vec<EmbeddedFileNif<'a>>> {
    resource.editor.with_read(|editor| {
        // The source and pending halves cannot both be populated.
        let mut files = read_embedded_files(env, editor.source())?;

        // Match the name order a full write will produce.
        let mirror = embedded_files(&resource);
        let mut pending: Vec<&EmbeddedFile> = mirror.iter().collect();
        pending.sort_by(|a, b| a.name.cmp(&b.name));

        for file in pending {
            files.push(pending_to_nif(env, file)?);
        }

        Ok(files)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_to_bytes(
    resource: ResourceArc<EditorResource>,
    options: SaveOptionsNif,
) -> NifResult<OwnedBinary> {
    resource.editor.with_lock(|editor| {
        if !options.incremental {
            resupply_embedded(&resource, editor)?;
        }

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
        if !options.incremental {
            resupply_embedded(&resource, editor)?;
        }

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

fn out_of_range(page_index: usize, count: usize) -> rustler::Error {
    tagged_err(
        atoms::out_of_range(),
        format!("Page index {page_index} out of range (editor has {count} pages)"),
    )
}

// Upstream bounds-checks every page-taking method but reports a bad index as a
// generic `InvalidPdf`, so the check is repeated here to reach `:out_of_range`.
// The editor's count is live rather than cached, so it must be read per call.
fn ensure_editor_page_in_range(editor: &DocumentEditor, page_index: usize) -> NifResult<()> {
    let count = editor.current_page_count();
    if page_index >= count {
        return Err(out_of_range(page_index, count));
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_delete_page(resource: ResourceArc<EditorResource>, page_index: usize) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Inside the guard so the check and the removal cannot straddle a writer
        // that changes the page count.
        ensure_editor_page_in_range(editor, page_index)?;

        editor.remove_page(page_index).map_err(to_nif_err)?;

        // Relaxed because the flatten NIFs load it under the same exclusive
        // guard, so the lock already orders this against every reader.
        resource.pages_deleted.store(true, Ordering::Relaxed);
        page_rotations(&resource).remove(page_index);

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_move_page(
    resource: ResourceArc<EditorResource>,
    from: usize,
    to: usize,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Both indices, `from` first: upstream rejects the pair with one message
        // naming neither, so checking here is the only way to say which is bad.
        ensure_editor_page_in_range(editor, from)?;
        ensure_editor_page_in_range(editor, to)?;

        editor.move_page(from, to).map_err(to_nif_err)?;

        // The mirror is indexed by visible position, so it takes the same
        // permutation the editor just took.
        let mut pages = page_rotations(&resource);
        let page = pages.remove(from);
        pages.insert(to, page);

        Ok(atoms::ok())
    })
}

// `source()` is the pre-edit document, so an unchanged rotation must be read at
// the recorded source index rather than at the visible one.
fn effective_rotation(
    resource: &EditorResource,
    editor: &DocumentEditor,
    page_index: usize,
) -> NifResult<i32> {
    // Drop the mirror guard before source lookup so shared reads stay concurrent.
    let (source, set) = {
        let pages = page_rotations(resource);
        let count = pages.len();
        let page = pages
            .get(page_index)
            .ok_or_else(|| out_of_range(page_index, count))?;

        (page.source, page.set)
    };

    match set {
        Some(rotation) => Ok(rotation),
        None => editor
            .source()
            .get_page_rotation(source)
            .map_err(to_nif_err),
    }
}

// Update the mirror only after the upstream write succeeds.
fn write_rotation(
    resource: &EditorResource,
    editor: &mut DocumentEditor,
    page_index: usize,
    degrees: i32,
) -> NifResult<()> {
    let mut pages = page_rotations(resource);
    let count = pages.len();
    let page = pages
        .get_mut(page_index)
        .ok_or_else(|| out_of_range(page_index, count))?;

    editor
        .set_page_rotation(page_index, degrees)
        .map_err(to_nif_err)?;
    page.set = Some(degrees);

    Ok(())
}

// Reduce before adding to avoid i32 overflow; keep upstream's quadrant buckets.
fn round_to_quadrant(current: i32, degrees: i32) -> i32 {
    match ((current % 360 + degrees % 360) % 360 + 360) % 360 {
        0..=44 => 0,
        45..=134 => 90,
        135..=224 => 180,
        225..=314 => 270,
        _ => 0,
    }
}

// Shared because it reaches the source document rather than the pending edits.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_page_rotation(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<i32> {
    resource
        .editor
        .with_read(|editor| effective_rotation(&resource, editor, page_index))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_page_rotation(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    degrees: i32,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        write_rotation(&resource, editor, page_index, degrees)?;

        Ok(atoms::ok())
    })
}

// Avoid upstream's relative getter; it can use the wrong base after page edits.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_rotate_page_by(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    degrees: i32,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        let current = effective_rotation(&resource, editor, page_index)?;
        let rotation = round_to_quadrant(current, degrees);

        write_rotation(&resource, editor, page_index, rotation)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_rotate_all_pages_by(
    resource: ResourceArc<EditorResource>,
    degrees: i32,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // The mirror's length, not `current_page_count`: every write below is
        // bounded by the mirror.
        let count = page_rotations(&resource).len();

        // Resolve bases first so a read failure leaves the editor unchanged.
        let rotations = (0..count)
            .map(|page_index| {
                let current = effective_rotation(&resource, editor, page_index)?;

                Ok(round_to_quadrant(current, degrees))
            })
            .collect::<NifResult<Vec<_>>>()?;

        for (page_index, rotation) in rotations.into_iter().enumerate() {
            write_rotation(&resource, editor, page_index, rotation)?;
        }

        Ok(atoms::ok())
    })
}

// The bulk call owns the `/AcroForm` side effect. After a deletion its raw page
// indices miss survivors, so re-mark them through the mapped per-page method.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_forms(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        editor.flatten_forms().map_err(to_nif_err)?;

        if resource.pages_deleted.load(Ordering::Relaxed) {
            for page in 0..editor.current_page_count() {
                editor.flatten_forms_on_page(page).map_err(to_nif_err)?;
            }
        }

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

// The bulk call marks a page-less editor modified; the loop fixes its page
// mapping after deletion for the same reason as `editor_flatten_forms`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_all_annotations(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        editor.flatten_all_annotations().map_err(to_nif_err)?;

        if resource.pages_deleted.load(Ordering::Relaxed) {
            for page in 0..editor.current_page_count() {
                editor.flatten_page_annotations(page).map_err(to_nif_err)?;
            }
        }

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
    use pdf_oxide::{
        editor::form_fields::FormFieldValue,
        encryption::{Algorithm, EncryptionWriteHandler},
        PdfDocument,
    };

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
    fn upstream_still_duplicates_a_page_by_reference() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");

        let copy = editor.duplicate_page(0).expect("duplicate");
        let bytes = editor.save_to_bytes().expect("full rewrite");

        let doc = PdfDocument::from_bytes(bytes).expect("reopens");

        assert_eq!(doc.page_count().expect("counts pages"), 4);
        assert!(
            doc.extract_text(copy).is_err(),
            "the duplicated page is readable, so upstream now writes a real copy"
        );
    }

    #[test]
    fn upstream_still_drains_pending_embedded_files_on_a_full_write() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");

        editor
            .embed_file("data.csv", b"a,b".to_vec())
            .expect("embeds");
        editor.save_to_bytes().expect("full rewrite");

        assert!(
            editor.pending_embedded_files().is_empty(),
            "the full writer no longer drains pending embedded files"
        );
    }

    #[test]
    fn upstream_still_replaces_an_indirect_name_tree() {
        let mut editor = DocumentEditor::open(fixture("attachments.pdf")).expect("fixture opens");

        let before = PdfDocument::open(fixture("attachments.pdf")).expect("fixture opens");
        assert!(
            !before
                .extract_embedded_files()
                .expect("reads attachments")
                .is_empty(),
            "the fixture must start with an attachment for the loss to be visible"
        );

        assert!(
            names_key(&before, "Dests").is_some(),
            "the fixture must start with a destination for the loss to be visible"
        );

        editor
            .embed_file("added.txt", b"added".to_vec())
            .expect("embeds");
        let bytes = editor.save_to_bytes().expect("full rewrite");
        let after = PdfDocument::from_bytes(bytes).expect("reopens");

        assert_eq!(
            after
                .extract_embedded_files()
                .expect("reads attachments")
                .len(),
            1,
            "embedding preserved the document's existing attachments"
        );
        assert!(
            names_key(&after, "Dests").is_none(),
            "embedding preserved the rest of the name tree"
        );
    }

    fn names_key(doc: &PdfDocument, key: &str) -> Option<pdf_oxide::object::Object> {
        let catalog = doc.catalog().ok()?;
        let names = doc.resolve_object(catalog.as_dict()?.get("Names")?).ok()?;

        doc.resolve_object(names.as_dict()?.get(key)?).ok()
    }

    #[test]
    fn upstream_still_mangles_an_embedded_file_name() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");

        editor
            .embed_file("r\u{e9}sum\u{e9}.txt", b"body".to_vec())
            .expect("embeds");
        let bytes = editor.save_to_bytes().expect("full rewrite");
        let doc = PdfDocument::from_bytes(bytes).expect("reopens");

        let names: Vec<String> = doc
            .extract_embedded_files()
            .expect("reads attachments")
            .into_iter()
            .map(|(name, _)| name)
            .collect();

        assert!(
            !names.contains(&"r\u{e9}sum\u{e9}.txt".to_string()),
            "upstream now decodes its UTF-16BE /UF correctly: {names:?}"
        );
    }

    #[test]
    fn upstream_still_double_escapes_an_embedded_file_mime_type() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");

        editor
            .embed_file_with_options(
                pdf_oxide::writer::EmbeddedFile::new("data.csv", b"a,b".to_vec())
                    .with_mime_type("text/csv"),
            )
            .expect("embeds");
        let bytes = editor.save_to_bytes().expect("full rewrite");

        assert!(
            !String::from_utf8_lossy(&bytes).contains("/Subtype /text#2Fcsv"),
            "upstream now serializes the embedded-file media type correctly"
        );
    }

    #[test]
    fn upstream_still_marks_bulk_flattens_by_output_index() {
        let mut editor = DocumentEditor::open(fixture("flatten.pdf")).expect("fixture opens");

        // The fixture's second page is the one that survives, so a correctly
        // mapped mark would land on output page 0.
        editor.remove_page(0).expect("removes the first page");

        editor.flatten_all_annotations().expect("marks every page");
        editor.flatten_forms().expect("marks every page");

        assert!(
            !editor.is_page_marked_for_flatten(0),
            "the bulk annotation flatten now maps its marks through the page order"
        );
        assert!(
            !editor.is_page_marked_for_form_flatten(0),
            "the bulk form flatten now maps its marks through the page order"
        );
    }

    #[test]
    fn upstream_still_marks_every_page_without_a_deletion() {
        let mut editor = DocumentEditor::open(fixture("flatten.pdf")).expect("fixture opens");

        editor.move_page(0, 1).expect("reorders the pages");

        editor.flatten_all_annotations().expect("marks every page");
        editor.flatten_forms().expect("marks every page");

        for page in 0..editor.current_page_count() {
            assert!(
                editor.is_page_marked_for_flatten(page),
                "the bulk annotation flatten missed output page {page} with nothing deleted"
            );
            assert!(
                editor.is_page_marked_for_form_flatten(page),
                "the bulk form flatten missed output page {page} with nothing deleted"
            );
        }
    }

    // In `rotation.pdf`, by /Rotate: 90 on the leaf, 180 inherited from an
    // intermediate /Pages node, -90 and the invalid 45.
    const INHERITED: usize = 1;
    const NEGATIVE: usize = 2;
    const INVALID: usize = 3;

    #[test]
    fn upstream_still_reads_page_rotation_off_the_leaf_dictionary() {
        let mut editor = DocumentEditor::open(fixture("rotation.pdf")).expect("fixture opens");
        let doc = PdfDocument::open(fixture("rotation.pdf")).expect("fixture opens");

        let mut editor_says = |page| editor.get_page_rotation(page).expect("the editor reads");

        assert_eq!(
            (
                editor_says(INHERITED),
                editor_says(NEGATIVE),
                editor_says(INVALID)
            ),
            (0, -90, 45),
            "the editor now resolves an inherited /Rotate, or normalizes the value"
        );

        let doc_says = |page| doc.get_page_rotation(page).expect("the document reads");

        assert_eq!(
            (doc_says(INHERITED), doc_says(NEGATIVE), doc_says(INVALID)),
            (180, 270, 0)
        );
    }

    #[test]
    fn upstream_still_reads_rotation_from_the_wrong_page_after_a_deletion() {
        let mut editor = DocumentEditor::open(fixture("rotation.pdf")).expect("fixture opens");

        editor.remove_page(0).expect("removes the first page");

        assert_eq!(
            editor.get_page_rotation(0).expect("reads"),
            90,
            "the getter now maps its read through the page order"
        );
    }

    #[test]
    fn upstream_still_reads_rotation_from_the_wrong_page_after_a_move() {
        let mut editor = DocumentEditor::open(fixture("rotation.pdf")).expect("fixture opens");

        editor.move_page(0, 3).expect("moves the first page last");

        assert_eq!(
            editor.get_page_rotation(0).expect("reads"),
            90,
            "the getter now maps its read through the page order"
        );
    }

    #[test]
    fn upstream_still_launders_an_invalid_rotation_through_rotate_page_by() {
        let mut editor = DocumentEditor::open(fixture("rotation.pdf")).expect("fixture opens");

        editor
            .rotate_page_by(INVALID, 0)
            .expect("rotates by nothing");

        assert_eq!(
            editor.get_page_rotation(INVALID).expect("reads"),
            90,
            "rotating by nothing is now an identity, so 45 is no longer rounded up"
        );
    }

    #[test]
    fn upstream_still_rotates_all_pages_from_the_wrong_base_after_a_deletion() {
        let mut editor = DocumentEditor::open(fixture("rotation.pdf")).expect("fixture opens");

        editor.remove_page(0).expect("removes the first page");
        editor.rotate_all_pages(90).expect("rotates every page");

        assert_eq!(
            editor.get_page_rotation(0).expect("reads"),
            180,
            "the bulk rotation now reads its base through the page order"
        );
    }

    #[test]
    fn round_to_quadrant_still_matches_upstreams_rotate_page_by() {
        // `sample.pdf` has no /Rotate and keeps source order in this test.
        for degrees in [45, 90, -90, 134, 135, 315, 450] {
            let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");

            editor.rotate_page_by(0, degrees).expect("rotates");

            assert_eq!(
                editor.get_page_rotation(0).expect("reads"),
                round_to_quadrant(0, degrees),
                "upstream retuned its rounding for a delta of {degrees}"
            );
        }
    }

    #[test]
    fn rounds_a_rotation_to_the_nearest_quadrant() {
        assert_eq!(round_to_quadrant(0, 44), 0);
        assert_eq!(round_to_quadrant(0, 45), 90);
        assert_eq!(round_to_quadrant(0, 134), 90);
        assert_eq!(round_to_quadrant(0, 135), 180);
        assert_eq!(round_to_quadrant(0, 224), 180);
        assert_eq!(round_to_quadrant(0, 225), 270);
        assert_eq!(round_to_quadrant(0, 314), 270);
        assert_eq!(round_to_quadrant(0, 315), 0);
        assert_eq!(round_to_quadrant(270, 90), 0);
        assert_eq!(round_to_quadrant(0, -90), 270);
        assert_eq!(round_to_quadrant(0, 450), 90);

        assert_eq!(
            round_to_quadrant(270, i32::MAX),
            round_to_quadrant(270, i32::MAX % 360),
            "the reduction before the sum is what keeps the addition from overflowing"
        );
    }

    #[test]
    fn upstream_still_ignores_the_linearize_save_option() {
        let linearized = saved_with(true);

        assert!(!linearized.is_empty(), "the fixture writes something");
        assert_eq!(linearized, saved_with(false));
    }

    #[test]
    fn upstream_still_exports_the_editors_source_values() {
        let mut editor = DocumentEditor::open(fixture("form.pdf")).expect("fixture opens");
        editor
            .set_form_field_value("full_name", FormFieldValue::Text(String::from("Jane Roe")))
            .expect("field is writable");

        // Confirm the write landed before checking that upstream omits it.
        let merged = editor.get_form_fields().expect("fields extract");
        let merged = merged
            .iter()
            .find(|field| field.name() == "full_name")
            .expect("field is reported");
        assert_eq!(
            merged.value(),
            FormFieldValue::Text(String::from("Jane Roe"))
        );

        let path = std::env::temp_dir().join(format!(
            "pdf_elixide_export_drift_{}.fdf",
            std::process::id()
        ));
        editor.export_form_data_fdf(&path).expect("export writes");
        // Lossy because an FDF opens with a high-bit binary marker.
        let fdf = std::fs::read(&path).expect("export reads back");
        let fdf = String::from_utf8_lossy(&fdf);
        let _ = std::fs::remove_file(&path);

        assert!(fdf.contains("/V (John Doe)"), "{fdf}");
        assert!(
            !fdf.contains("Jane Roe"),
            "upstream's editor export now sees pending edits: {fdf}"
        );
    }

    fn encryption_config(algorithm: EncryptionAlgorithm) -> EncryptionConfig {
        EncryptionConfig::new("secret", "owner").with_algorithm(algorithm)
    }

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "pdf_elixide_encryption_drift_{name}_{}.pdf",
            std::process::id()
        ))
    }

    #[test]
    fn upstream_still_encrypts_aes256_with_a_key_it_does_not_publish() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        let bytes = editor
            .save_to_bytes_with_options(SaveOptions::with_encryption(encryption_config(
                EncryptionAlgorithm::Aes256,
            )))
            .expect("full rewrite");

        let doc = PdfDocument::from_bytes(bytes).expect("reopens");
        assert!(
            doc.authenticate(b"secret").expect("authenticates"),
            "the /U hash is self-consistent even though the body key is not"
        );

        let text = doc.extract_text(0).unwrap_or_default();
        assert!(
            !text.contains("Page One"),
            "upstream now encrypts an AES-256 body with the key it publishes: {text:?}"
        );
    }

    #[test]
    fn upstream_still_ignores_encryption_on_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        let path = temp_path("incremental");

        editor
            .save_with_options(
                &path,
                SaveOptions {
                    incremental: true,
                    ..SaveOptions::with_encryption(encryption_config(EncryptionAlgorithm::Aes128))
                },
            )
            .expect("incremental save");

        let bytes = std::fs::read(&path).expect("reads back");
        let _ = std::fs::remove_file(&path);

        assert!(
            !bytes.windows(8).any(|w| w == b"/Encrypt"),
            "upstream now carries encryption into an incremental update"
        );
    }

    // `sample.pdf` declares PDF 1.4, below AESV2's PDF 1.6 requirement.
    #[test]
    fn upstream_still_writes_the_source_version_when_encrypting() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        let bytes = editor
            .save_to_bytes_with_options(SaveOptions::with_encryption(encryption_config(
                EncryptionAlgorithm::Aes128,
            )))
            .expect("full rewrite");

        assert!(
            bytes.starts_with(b"%PDF-1.4"),
            "upstream now raises the header version when encrypting"
        );
        assert!(
            bytes.windows(11).any(|w| w == b"/CFM /AESV2"),
            "the write really did use the PDF 1.6 crypt filter"
        );
        assert!(
            !bytes.windows(8).any(|w| w == b"/Version"),
            "upstream now writes a catalog /Version override"
        );
    }

    // A short base key forces an AES failure without replacing the process-global
    // crypto provider. Normal saves always derive a valid-length key.
    #[test]
    fn upstream_still_returns_plaintext_when_an_object_cannot_be_encrypted() {
        const PROBE: &[u8] = b"the quick brown fox jumps over it";

        let broken = EncryptionWriteHandler::from_key(vec![0u8; 4], Algorithm::Aes128, true);

        assert_eq!(
            broken.encrypt_stream(PROBE, 1, 0),
            PROBE,
            "upstream now reports a failed stream encryption instead of \
             returning the plaintext"
        );
        assert_eq!(
            broken.encrypt_string(PROBE, 1, 0),
            PROBE,
            "upstream now reports a failed string encryption instead of \
             returning the plaintext"
        );

        // A valid-key control prevents a no-op cipher from passing this test.
        let working = EncryptionWriteHandler::from_key(vec![0u8; 16], Algorithm::Aes128, true);

        assert_ne!(
            working.encrypt_stream(PROBE, 1, 0),
            PROBE,
            "a correct-length key no longer encrypts, so the assertions above prove nothing"
        );
    }

    // `Aes128` is set explicitly: `EncryptionConfig`'s `Default` is `Aes256`, whose
    // body key is never published, so a default-built config would measure that
    // defect instead of this one.
    #[test]
    fn upstream_still_writes_ciphertext_from_an_encrypted_source() {
        let mut source = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        let locked = source
            .save_to_bytes_with_options(SaveOptions::with_encryption(encryption_config(
                EncryptionAlgorithm::Aes128,
            )))
            .expect("encrypts");

        let mut editor = DocumentEditor::from_bytes(locked).expect("reopens for editing");
        assert!(
            editor
                .source()
                .authenticate(b"secret")
                .expect("authenticates"),
            "the password no longer opens the document, so the read below proves nothing"
        );

        // Without this the assertion beneath it passes whenever authentication
        // silently failed, which is the same observable as the defect.
        assert!(
            editor
                .source()
                .extract_text(0)
                .expect("reads the source")
                .contains("Page One"),
            "an authenticated source no longer reads, so the write below is untested"
        );

        let written = editor
            .save_to_bytes_with_options(SaveOptions::full_rewrite())
            .expect("full rewrite");
        let reopened = PdfDocument::from_bytes(written).expect("reopens");

        assert!(
            !reopened
                .extract_text(0)
                .unwrap_or_default()
                .contains("Page One"),
            "upstream now decrypts stream payloads on the write path: bind a password \
             option through DocumentEditor::from_document and drop ensure_not_encrypted"
        );
    }
}
