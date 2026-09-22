use std::collections::HashSet;

use pdf_oxide::{
    annotation_types::AnnotationSubtype,
    editor::{
        DocumentEditor, EditableDocument, EncryptionAlgorithm, EncryptionConfig, Permissions,
        SaveOptions,
    },
    object::Object,
    writer::EmbeddedFile,
    Error as PdfError, PdfDocument,
};
use rustler::{Atom, Binary, Env, NifMap, NifResult, NifUnitEnum, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    document::OpenOptionsNif,
    embedded_files::{
        embedded_file, ensure_no_name_tree, pending_to_nif, read_embedded_files, EmbeddedFileNif,
        RelationshipNif,
    },
    error::{tagged_err, to_form_err, to_nif_err},
    form::{
        editor_form_field_to_nif, export_bytes, export_form_field, fillable, is_exportable,
        set_value_from_nif, FieldNif, FieldValueNif, FormDataFormatNif,
    },
    form_tree::Resolved,
    fs_path::path_arg,
    geometry::{rect_from_corners, rect_from_nif, RectNif},
    metadata::{normalize_text, read_metadata, MetadataNif},
    open_editor::{Marked, OpenEditor, OutOfRange, PageError},
    resource::Closable,
    signatures::well_formed_pdf_date_len,
    warnings, EditorResource,
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

fn needs_password_err() -> rustler::Error {
    tagged_err(
        atoms::encrypted(),
        "This document is encrypted. Supply the :password option to open it for \
         editing.",
    )
}

fn authenticate_source(editor: &DocumentEditor, options: OpenOptionsNif<'_>) -> NifResult<()> {
    if !editor.source().is_encrypted() {
        return Ok(());
    }

    options.apply(editor.source())?;

    if !editor.source().is_authenticated() {
        return Err(needs_password_err());
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyIo")]
fn editor_open(path: Binary, options: OpenOptionsNif<'_>) -> NifResult<OpenedEditor> {
    let path = path_arg(path)?;
    let editor = warnings::drained(|| match DocumentEditor::open(&path) {
        // Keep `source_path`; `from_document` clears it and breaks incremental saves.
        Ok(editor) => {
            authenticate_source(&editor, options)?;

            Ok(editor)
        }
        // Preserve the authentication by handing this document to the editor.
        Err(PdfError::EncryptedPdf) if options.password.is_some() => {
            let doc = PdfDocument::open(&path).map_err(to_nif_err)?;
            options.apply(&doc)?;

            DocumentEditor::from_document(doc).map_err(to_nif_err)
        }
        Err(PdfError::EncryptedPdf) => Err(needs_password_err()),
        Err(e) => Err(to_nif_err(e)),
    })?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", OpenEditor::new(editor)),
    });
    let version = cached_version(&resource)?;

    Ok((resource, version))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_bytes(bytes: Binary, options: OpenOptionsNif<'_>) -> NifResult<OpenedEditor> {
    // The same two routes as `editor_open`, for the same reason; see there.
    let editor =
        warnings::drained(
            || match DocumentEditor::from_bytes(bytes.as_slice().to_vec()) {
                Ok(editor) => {
                    authenticate_source(&editor, options)?;

                    Ok(editor)
                }
                Err(PdfError::EncryptedPdf) if options.password.is_some() => {
                    let doc =
                        PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;
                    options.apply(&doc)?;

                    DocumentEditor::from_document(doc).map_err(to_nif_err)
                }
                Err(PdfError::EncryptedPdf) => Err(needs_password_err()),
                Err(e) => Err(to_nif_err(e)),
            },
        )?;

    let resource = ResourceArc::new(EditorResource {
        editor: Closable::new("Editor", OpenEditor::new(editor)),
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

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_form_fields(resource: ResourceArc<EditorResource>) -> NifResult<Vec<FieldNif>> {
    resource.editor.with_lock(|editor| {
        // By name, because a `FormFieldWrapper` carries no `object_ref`. The
        // document path resolves the same names, so the two sources agree.
        let (resolved, upstream) = editor.resolved_fields()?;
        let fields = upstream.get_form_fields().map_err(to_nif_err)?;

        Ok(fields
            .into_iter()
            .filter(|field| fillable(resolved, field))
            .filter_map(|field| {
                let attrs = resolved.attrs(field.name());
                let on_states = resolved.on_states(field.name());

                editor_form_field_to_nif(field, attrs, on_states)
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
        let (resolved, upstream) = editor.resolved_fields()?;
        let fields = upstream.get_form_fields().map_err(to_nif_err)?;

        let fields = fields
            .into_iter()
            .filter_map(export_form_field)
            .filter(|field| is_exportable(field, resolved))
            .collect();

        owned_binary(&export_bytes(fields, format, file_spec)?, "form data")
    })
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
        ensure_no_name_tree(editor.source(), &editor.scrubbed_name_tree_entries())?;

        let file = embedded_file(name, data.as_slice().to_vec(), description, relationship);
        editor.attach_file(file).map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

// Shared: it reads only `source()` and the attachment mirror.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_embedded_files<'a>(
    env: Env<'a>,
    resource: ResourceArc<EditorResource>,
) -> NifResult<Vec<EmbeddedFileNif<'a>>> {
    resource.editor.with_read(|editor| {
        // The source and pending halves cannot both be populated. A sanitize
        // removes the source's name tree from the *output* only, so once it has
        // run the source half is no longer what the written document carries.
        let mut files = if editor.embedded_scrubbed() {
            Vec::new()
        } else {
            read_embedded_files(env, editor.source())?
        };

        // Match the name order a full write will produce.
        let mut pending: Vec<&EmbeddedFile> = editor.embedded_files().iter().collect();
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
        // Incremental output upstream refuses on its own; this one it does not.
        ensure_scrub_survives_save(editor, &options)?;
        ensure_metadata_survives_save(editor)?;

        // Incremental output is refused below before writing, so resupplying
        // for it would only move the modified flag.
        if !options.incremental {
            editor.resupply_embedded().map_err(to_nif_err)?;
            editor.resupply_info().map_err(to_nif_err)?;
        }

        let bytes = editor
            .save_to_bytes_with_options(options.into())
            .map_err(to_nif_err)?;

        owned_binary(&bytes, "editor")
    })
}

// Incremental output copies the original bytes, retaining removed content.
fn ensure_redaction_survives_save(editor: &OpenEditor, options: &SaveOptionsNif) -> NifResult<()> {
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

    editor
        .source()
        .catalog()
        .ok()
        .and_then(|catalog| catalog.as_dict().map(|dict| dict.contains_key("Metadata")))
        .unwrap_or(false)
}

// An absent or unreadable `/EncryptMetadata` takes its default value, `true`.
fn declares_cleartext_metadata(doc: &PdfDocument) -> bool {
    let Some(trailer) = doc.trailer().as_dict() else {
        return false;
    };

    let encrypt = match trailer.get("Encrypt") {
        Some(Object::Reference(r)) => match doc.load_object(*r) {
            Ok(object) => object,
            Err(_) => return false,
        },
        Some(direct) => direct.clone(),
        None => return false,
    };

    let Some(flag) = encrypt
        .as_dict()
        .and_then(|dict| dict.get("EncryptMetadata"))
    else {
        return false;
    };

    // The flag may be indirect; treating that shape as absent would lose XMP.
    let flag = match flag {
        Object::Reference(r) => match doc.load_object(*r) {
            Ok(object) => object,
            Err(_) => return false,
        },
        direct => direct.clone(),
    };

    matches!(flag, Object::Boolean(false))
}

fn ensure_metadata_survives_save(editor: &OpenEditor) -> NifResult<()> {
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
fn ensure_scrub_survives_save(editor: &OpenEditor, options: &SaveOptionsNif) -> NifResult<()> {
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
fn ensure_incremental_is_not_encrypted(
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

// The encryption guard above removes the other case with an empty source path.
fn ensure_incremental_has_a_source(
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

// The incremental writer silently omits changes outside field values and /Info.
fn ensure_edits_survive_save(editor: &OpenEditor, options: &SaveOptionsNif) -> NifResult<()> {
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
        ensure_redaction_survives_save(editor, &options)?;
        ensure_scrub_survives_save(editor, &options)?;
        ensure_metadata_survives_save(editor)?;
        ensure_incremental_is_not_encrypted(editor, &options)?;
        ensure_incremental_has_a_source(editor, &options)?;
        // Report destructive edits and a missing source before omitted changes.
        ensure_edits_survive_save(editor, &options)?;

        if !options.incremental {
            editor.resupply_embedded().map_err(to_nif_err)?;
        }
        editor.resupply_info().map_err(to_nif_err)?;

        editor
            .save_with_options(&path, options.into())
            .map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

#[derive(NifUnitEnum, Clone, Copy, Debug)]
pub enum InfoFieldNif {
    Title,
    Author,
    Subject,
    Keywords,
    Creator,
    Producer,
    CreationDate,
    ModDate,
}

fn info_slot(info: &mut MetadataNif, field: InfoFieldNif) -> &mut Option<String> {
    match field {
        InfoFieldNif::Title => &mut info.title,
        InfoFieldNif::Author => &mut info.author,
        InfoFieldNif::Subject => &mut info.subject,
        InfoFieldNif::Keywords => &mut info.keywords,
        InfoFieldNif::Creator => &mut info.creator,
        InfoFieldNif::Producer => &mut info.producer,
        InfoFieldNif::CreationDate => &mut info.creation_date,
        InfoFieldNif::ModDate => &mut info.mod_date,
    }
}

// The shared grammar is prefix-lenient for the signature reader's sake; a
// write must match in full so nothing unvalidated reaches the file.
fn writable_pdf_date(date: &str) -> bool {
    well_formed_pdf_date_len(date) == Some(date.len())
}

// A short, lock-free check does not warrant dirty scheduling.
#[rustler::nif]
fn pdf_date_writable(date: String) -> bool {
    writable_pdf_date(&date)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_info_field(
    resource: ResourceArc<EditorResource>,
    field: InfoFieldNif,
    value: Option<String>,
) -> NifResult<Atom> {
    if matches!(field, InfoFieldNif::CreationDate | InfoFieldNif::ModDate) {
        if let Some(date) = value.as_deref().filter(|date| !writable_pdf_date(date)) {
            return Err(tagged_err(
                atoms::other(),
                format!("invalid {field:?}, expected a PDF date string: {date:?}"),
            ));
        }
    }

    resource.editor.with_lock(|editor| {
        let mut info = editor.seeded_info();
        *info_slot(&mut info, field) = value;

        editor.write_info(info).map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

// Shared because it reaches only `source()` and the mirror. Pending values are
// normalized the way `read_metadata` normalizes, so the answer predicts what a
// reader gets from the written file.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_info(resource: ResourceArc<EditorResource>) -> NifResult<MetadataNif> {
    resource.editor.with_read(|editor| {
        let pending = editor.info().cloned();

        Ok(match pending {
            Some(info) => MetadataNif {
                title: normalize_text(info.title),
                author: normalize_text(info.author),
                subject: normalize_text(info.subject),
                keywords: normalize_text(info.keywords),
                creator: normalize_text(info.creator),
                producer: normalize_text(info.producer),
                creation_date: normalize_text(info.creation_date),
                mod_date: normalize_text(info.mod_date),
                trapped: info.trapped,
            },
            None => read_metadata(editor.source()),
        })
    })
}

fn field_not_found(name: &str) -> rustler::Error {
    tagged_err(atoms::not_found(), format!("Form field not found: {name}"))
}

// Guard the write itself: hiding signatures from reads does not stop a caller
// naming one directly, and any value would replace its `/V` dictionary.
fn ensure_not_signature(resolved: &Resolved, name: &str) -> NifResult<()> {
    if resolved.is_signature(name) {
        return Err(field_not_found(name));
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
        let (resolved, upstream) = editor.resolved_fields()?;
        ensure_not_signature(resolved, &name)?;

        upstream
            .set_form_field_value(&name, set_value_from_nif(value))
            .map_err(to_form_err)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_form_field_values(
    resource: ResourceArc<EditorResource>,
    pairs: Vec<(String, Option<FieldValueNif>)>,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Preflight every name so an unknown field cannot partially apply the batch.
        let (resolved, upstream) = editor.resolved_fields()?;
        let fields = upstream.get_form_fields().map_err(to_nif_err)?;
        let known: HashSet<&str> = fields
            .iter()
            .filter(|field| fillable(resolved, field))
            .map(|field| field.name())
            .collect();

        for (name, _value) in &pairs {
            if !known.contains(name.as_str()) {
                return Err(field_not_found(name));
            }
        }

        for (name, value) in pairs {
            upstream
                .set_form_field_value(&name, set_value_from_nif(value))
                .map_err(to_form_err)?;
        }

        Ok(atoms::ok())
    })
}

fn out_of_range(page_index: usize, count: usize) -> rustler::Error {
    tagged_err(
        atoms::out_of_range(),
        format!("Page index {page_index} out of range (editor has {count} pages)"),
    )
}

// The mirror reports a bad index as data; the atom is built here, at the boundary.
impl From<OutOfRange> for rustler::Error {
    fn from(e: OutOfRange) -> Self {
        out_of_range(e.index, e.count)
    }
}

impl From<PageError> for rustler::Error {
    fn from(e: PageError) -> Self {
        match e {
            PageError::OutOfRange(e) => e.into(),
            PageError::Upstream(e) => to_nif_err(e),
        }
    }
}

// Upstream bounds-checks every page-taking method but reports a bad index as a
// generic `InvalidPdf`, so the check is repeated here to reach `:out_of_range`.
// The editor's count is live rather than cached, so it must be read per call.
pub fn ensure_editor_page_in_range(editor: &DocumentEditor, page_index: usize) -> NifResult<()> {
    let count = editor.current_page_count();
    if page_index >= count {
        return Err(out_of_range(page_index, count));
    }

    Ok(())
}

// The object a source page's `/Contents` reference resolves to, or `None` when
// the entry is absent or already direct. Use the mirror to reach the source page
// after moves or deletions.
fn indirect_contents_target(editor: &OpenEditor, page_index: usize) -> NifResult<Option<Object>> {
    let source = editor.source_page(page_index)?;

    let page = editor.source().get_page(source).map_err(to_nif_err)?;
    let contents = page.as_dict().and_then(|dict| dict.get("Contents"));

    let Some(Object::Reference(reference)) = contents else {
        return Ok(None);
    };

    editor
        .source()
        .load_object(*reference)
        .map(Some)
        .map_err(to_nif_err)
}

// Whether the source page's `/Contents` is a reference to an *array* object.
// Every overlay splice wraps such a reference without resolving it, nesting an
// array in an array and losing the page content.
fn contents_is_indirect_array(editor: &OpenEditor, page_index: usize) -> NifResult<bool> {
    Ok(indirect_contents_target(editor, page_index)?
        .is_some_and(|target| target.as_array().is_some()))
}

// Reject indirect content arrays before recording an erase.
fn ensure_contents_spliceable(editor: &OpenEditor, page_index: usize) -> NifResult<()> {
    if contents_is_indirect_array(editor, page_index)? {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "Page {page_index} stores its content streams as an indirect array, \
                 which an erase overlay cannot be appended to without corrupting \
                 the page. The page can still be saved unchanged."
            ),
        ));
    }

    Ok(())
}

// How a source page's `/Contents` is unusable to a redaction, or `None` when it
// is absent, direct, or an indirect stream. Wider than the erase splice's
// array-only test: a destructive pass decodes the *unresolved* `/Contents`, so
// every indirect non-stream object fails.
fn unusable_contents_shape(
    editor: &OpenEditor,
    page_index: usize,
) -> NifResult<Option<&'static str>> {
    let Some(target) = indirect_contents_target(editor, page_index)? else {
        return Ok(None);
    };

    if matches!(target, Object::Stream { .. }) {
        return Ok(None);
    }

    // Name the array where it is one: it is the shape a producer actually emits,
    // and the only one the erase splice refuses.
    Ok(Some(if target.as_array().is_some() {
        "an indirect array"
    } else {
        "an indirect object that is not a content stream"
    }))
}

// Authentication does not decrypt streams consumed by edit-time readers.
pub fn ensure_source_is_not_encrypted(editor: &OpenEditor, operation: &str) -> NifResult<()> {
    if !editor.source().is_encrypted() {
        return Ok(());
    }

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "{operation} is unsupported for an encrypted source. Nothing has \
             changed. Write a full rewrite, reopen it, and retry."
        ),
    ))
}

// The refusal for a *queued* region, and unconditional where the mark's is not:
// a region only ever reaches the destructive pass, and cannot be withdrawn once
// added, so accepting one the pass could never apply strands the editor.
pub fn ensure_contents_redactable(editor: &OpenEditor, page_index: usize) -> NifResult<()> {
    let Some(shape) = unusable_contents_shape(editor, page_index)? else {
        return Ok(());
    };

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "Page {page_index} stores its content streams as {shape}, \
             which a destructive redaction cannot read, so a region queued here \
             could never be applied. The page can still be saved unchanged."
        ),
    ))
}

// Whether a source page contributes any region of its own to a redaction: a
// `/Redact` annotation carrying a `/Rect`, the condition upstream filters on.
// It is the difference between a page a mark puts in the destructive set and a
// page that set actually rewrites.
pub fn draws_redactions(editor: &DocumentEditor, source: usize) -> NifResult<bool> {
    let annotations = editor
        .source()
        .get_annotations(source)
        .map_err(to_nif_err)?;

    Ok(annotations
        .iter()
        .any(|a| a.subtype_enum == AnnotationSubtype::Redact && a.rect.is_some()))
}

// The same refusal for a redaction mark, but only where the mark has an effect:
// with no region of its own a page produces no overlay and rewrites nothing, so
// marking it is harmless whatever its `/Contents`.
pub fn ensure_redaction_spliceable(editor: &OpenEditor, page_index: usize) -> NifResult<()> {
    // The annotation check first: reading a page's `/Contents` clones the whole
    // stream while `get_annotations` is cheap, and `editor_mark_all_redactions`
    // runs this over every page.
    let source = editor.source_page(page_index)?;

    if !draws_redactions(editor, source)? {
        return Ok(());
    }

    let Some(shape) = unusable_contents_shape(editor, page_index)? else {
        return Ok(());
    };

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "Page {page_index} stores its content streams as {shape}, which a \
             redaction overlay cannot be appended to without corrupting the page, \
             and which a destructive redaction cannot read. The page can still be \
             saved unchanged."
        ),
    ))
}

// Does `obj` reach an indirect object, at any depth within its own structure?
fn holds_reference(obj: &Object) -> bool {
    match obj {
        Object::Reference(_) => true,
        Object::Array(a) => a.iter().any(holds_reference),
        Object::Dictionary(d) => d.values().any(holds_reference),
        Object::Stream { dict, .. } => dict.values().any(holds_reference),
        _ => false,
    }
}

// A scrub drops the `/Info` dictionary's own object id and not its children, so
// an indirect value is written out with the secret intact. Nothing public can
// orphan it in turn, so the structure is refused rather than reported scrubbed.
pub fn ensure_info_is_direct(editor: &DocumentEditor) -> NifResult<()> {
    let source = editor.source();
    let Some(info_ref) = source
        .trailer()
        .as_dict()
        .and_then(|d| d.get("Info"))
        .and_then(|v| v.as_reference())
    else {
        return Ok(());
    };
    // An `/Info` that cannot be read or is not a dictionary carries nothing to
    // leave behind, so it is allowed through rather than refused.
    let Ok(info) = source.load_object(info_ref) else {
        return Ok(());
    };
    let Some(dict) = info.as_dict() else {
        return Ok(());
    };

    if dict.values().any(holds_reference) {
        return Err(tagged_err(
            atoms::unsupported(),
            "This document stores an /Info value as an indirect object, which a \
             scrub replaces without removing: the value keeps its own object and \
             is written out. Sanitize with scrub_metadata: false to strip the rest, \
             or rewrite the document's metadata before sanitizing.",
        ));
    }

    Ok(())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_delete_page(resource: ResourceArc<EditorResource>, page_index: usize) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Inside the guard so the check and the removal cannot straddle a writer
        // that changes the page count.
        ensure_editor_page_in_range(editor, page_index)?;

        editor.delete_page(page_index).map_err(to_nif_err)?;

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

        Ok(atoms::ok())
    })
}

// Treat a non-quadrant base as zero, as the reader does rather than as upstream does.
// Reduce before adding to avoid overflow; a quadrant for every input is what makes
// `editor_rotate_all_pages_by`'s write pass infallible.
fn round_to_quadrant(current: i32, degrees: i32) -> i32 {
    let base = match current.rem_euclid(360) {
        quadrant @ (0 | 90 | 180 | 270) => quadrant,
        _ => 0,
    };

    match (base + degrees.rem_euclid(360)).rem_euclid(360) {
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
        .with_read(|editor| Ok(editor.effective_rotation(page_index)?))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_page_rotation(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    degrees: i32,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        editor.write_rotation(page_index, degrees)?;

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
        let current = editor.effective_rotation(page_index)?;
        let rotation = round_to_quadrant(current, degrees);

        editor.write_rotation(page_index, rotation)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_rotate_all_pages_by(
    resource: ResourceArc<EditorResource>,
    degrees: i32,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        // Resolve bases first so a read failure leaves the editor unchanged.
        let rotations = (0..editor.visible_page_count())
            .map(|page_index| {
                let current = editor.effective_rotation(page_index)?;

                Ok(round_to_quadrant(current, degrees))
            })
            .collect::<NifResult<Vec<_>>>()?;

        for (page_index, rotation) in rotations.into_iter().enumerate() {
            editor.write_rotation(page_index, rotation)?;
        }

        Ok(atoms::ok())
    })
}

// Check sums as well as fields: upstream writes non-finite corners unchecked.
// Return the offending rect so atom construction stays at the NIF boundary.
fn corners(nif: RectNif) -> Result<[f32; 4], RectNif> {
    let r = rect_from_nif(nif);
    let corners = [r.x, r.y, r.x + r.width, r.y + r.height];
    if corners.iter().all(|c| c.is_finite()) {
        Ok(corners)
    } else {
        Err(nif)
    }
}

fn erase_corners(rects: Vec<RectNif>) -> Result<Vec<[f32; 4]>, RectNif> {
    rects.into_iter().map(corners).collect()
}

// The single-rectangle form, for `add_redaction`. Same guard, same message.
pub fn redaction_corners(rect: RectNif) -> NifResult<[f32; 4]> {
    corners(rect).map_err(unrepresentable)
}

fn unrepresentable(rect: RectNif) -> rustler::Error {
    tagged_err(
        atoms::other(),
        format!("invalid region {rect:?}: its corners must fit a 32-bit float"),
    )
}

#[derive(NifMap, Debug, Clone, Copy)]
pub struct MarginsNif {
    pub left: f32,
    pub right: f32,
    pub top: f32,
    pub bottom: f32,
}

#[derive(Debug, PartialEq)]
enum CropRefusal {
    NotFinite,
    Empty,
}

// Normalize first so margins always inset a corner-reversed media box. Not
// through `rect_from_corners`: that clamps for encoding, and an extent past
// f32 must overflow here so the finiteness check below can refuse it.
fn crop_from_margins(media_box: [f32; 4], margins: MarginsNif) -> Result<[f32; 4], CropRefusal> {
    let [llx, lly, urx, ury] = media_box;
    let (x, y) = (llx.min(urx), lly.min(ury));
    let (width, height) = ((urx - llx).abs(), (ury - lly).abs());
    let crop = [
        x + margins.left,
        y + margins.bottom,
        x + width - margins.right,
        y + height - margins.top,
    ];

    if !crop.iter().all(|c| c.is_finite()) {
        return Err(CropRefusal::NotFinite);
    }
    if crop[0] >= crop[2] || crop[1] >= crop[3] {
        return Err(CropRefusal::Empty);
    }

    Ok(crop)
}

// Shared for the same reason as `editor_page_rotation`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_page_media_box(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<RectNif> {
    resource.editor.with_read(|editor| {
        let [llx, lly, urx, ury] = editor.effective_media_box(page_index)?;

        Ok(rect_from_corners(
            llx.into(),
            lly.into(),
            urx.into(),
            ury.into(),
        ))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_page_crop_box(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<Option<RectNif>> {
    resource.editor.with_read(|editor| {
        Ok(editor
            .effective_crop_box(page_index)?
            .map(|[llx, lly, urx, ury]| {
                rect_from_corners(llx.into(), lly.into(), urx.into(), ury.into())
            }))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_page_media_box(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    rect: RectNif,
) -> NifResult<Atom> {
    let corners = corners(rect).map_err(unrepresentable)?;

    resource.editor.with_lock(|editor| {
        editor.write_media_box(page_index, corners)?;

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_set_page_crop_box(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    rect: RectNif,
) -> NifResult<Atom> {
    let corners = corners(rect).map_err(unrepresentable)?;

    resource.editor.with_lock(|editor| {
        editor.write_crop_box(page_index, corners)?;

        Ok(atoms::ok())
    })
}

// Resolve every crop before writing so a failure leaves all pages unchanged.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_crop_margins(
    resource: ResourceArc<EditorResource>,
    margins: MarginsNif,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        let crops = (0..editor.visible_page_count())
            .map(|page_index| {
                let media_box = editor.effective_media_box(page_index)?;

                crop_from_margins(media_box, margins).map_err(|refusal| {
                    let why = match refusal {
                        CropRefusal::NotFinite => "the corners must fit a 32-bit float",
                        CropRefusal::Empty => "the margins leave no area",
                    };
                    tagged_err(
                        atoms::other(),
                        format!("page {page_index}: {why} inside its media box {media_box:?}"),
                    )
                })
            })
            .collect::<NifResult<Vec<_>>>()?;

        for (page_index, crop) in crops.into_iter().enumerate() {
            editor.write_crop_box(page_index, crop)?;
        }

        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_erase_regions(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
    rects: Vec<RectNif>,
) -> NifResult<Atom> {
    let corners = erase_corners(rects).map_err(unrepresentable)?;

    resource.editor.with_lock(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;
        ensure_contents_spliceable(editor, page_index)?;

        editor.erase(page_index, &corners).map_err(to_nif_err)?;

        Ok(atoms::ok())
    })
}

// Upstream does not bounds-check this one, so the check here is the only one.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_clear_erase_regions(
    resource: ResourceArc<EditorResource>,
    page_index: usize,
) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        ensure_editor_page_in_range(editor, page_index)?;

        editor.clear_erase(page_index);

        Ok(atoms::ok())
    })
}

// The bulk call owns the `/AcroForm` side effect. After a deletion its raw page
// indices miss survivors, so re-mark them through the mapped per-page method.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_forms(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        ensure_source_is_not_encrypted(editor, "Flattening form fields")?;

        editor.flatten_forms().map_err(to_nif_err)?;
        editor.mark(Marked::Forms);

        if editor.pages_deleted() {
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
        ensure_source_is_not_encrypted(editor, "Flattening form fields")?;

        editor
            .flatten_forms_on_page(page_index)
            .map_err(to_nif_err)?;
        editor.mark(Marked::Forms);

        Ok(atoms::ok())
    })
}

// The bulk call marks a page-less editor modified; the loop fixes its page
// mapping after deletion for the same reason as `editor_flatten_forms`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_flatten_all_annotations(resource: ResourceArc<EditorResource>) -> NifResult<Atom> {
    resource.editor.with_lock(|editor| {
        ensure_source_is_not_encrypted(editor, "Flattening annotations")?;

        editor.flatten_all_annotations().map_err(to_nif_err)?;
        editor.mark(Marked::Annotations);

        if editor.pages_deleted() {
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
        ensure_source_is_not_encrypted(editor, "Flattening annotations")?;

        editor
            .flatten_page_annotations(page_index)
            .map_err(to_nif_err)?;
        editor.mark(Marked::Annotations);

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
        editor::{form_fields::FormFieldValue, DocumentInfo},
        encryption::{Algorithm, EncryptionWriteHandler},
        extractors::FormExtractor,
        PdfDocument,
    };

    use super::*;
    use crate::document::read_crop_box;

    #[test]
    fn writable_pdf_date_holds_the_shared_grammar_to_the_whole_input() {
        for date in [
            "D:2024",
            "D:20240115120000",
            "D:20240115120000Z",
            "D:20240115120000+03",
            "D:20240115120000+03'",
            "D:20240115120000+0300",
            "D:20240115120000+03'00",
            "D:20240115120000-05'00'",
        ] {
            assert!(writable_pdf_date(date), "{date}");
        }
        for date in [
            "D:20240115120000Zgarbage",
            "D:20240421120000Z00'00'",
            "D:20240115120000+03'00'x",
            "D:20240115120000+03x",
            "D:20240115120000Zжж",
            "2024-01-15",
            "D:20240231000000Z",
            "",
        ] {
            assert!(!writable_pdf_date(date), "{date}");
        }
    }

    // Justifies `encode_pdf_text_string`: upstream writes a `String`'s bytes
    // raw, which a conforming reader takes for PDFDocEncoding.
    #[test]
    fn upstream_still_writes_info_text_strings_without_a_bom() {
        let object = DocumentInfo::new().title("Título").to_object();
        let bytes = object
            .as_dict()
            .and_then(|dict| dict.get("Title"))
            .and_then(|title| title.as_string())
            .expect("a /Title string");

        assert!(
            !bytes.starts_with(b"\xEF\xBB\xBF") && !bytes.starts_with(b"\xFE\xFF"),
            "upstream now encodes /Info text strings"
        );
        assert_eq!(bytes, "Título".as_bytes());
    }

    // The three below justify `read_metadata` over `get_info`. Unusually, no
    // single red deletes it: `editor_info` is a shared read and `get_info`
    // takes `&mut self`.
    #[test]
    fn upstream_still_ignores_a_direct_info_dictionary() {
        let mut editor = DocumentEditor::open(fixture("direct_info.pdf")).expect("fixture opens");
        let ours = read_metadata(editor.source());
        let theirs = editor.get_info().expect("info");

        assert_eq!(ours.title.as_deref(), Some("Direct"));
        assert_eq!(ours.author.as_deref(), Some("Ada"));
        assert_eq!(
            (theirs.title.as_deref(), theirs.author.as_deref()),
            (None, None),
            "upstream now reads an /Info dictionary written directly in the trailer"
        );
    }

    #[test]
    fn upstream_still_drops_an_indirect_info_field() {
        let mut editor =
            DocumentEditor::open(fixture("sanitize_indirect_info.pdf")).expect("fixture opens");
        let ours = read_metadata(editor.source());
        let theirs = editor.get_info().expect("info");

        // Non-vacuity: the direct sibling proves the dictionary was read.
        assert_eq!(ours.author.as_deref(), Some("Ada"));
        assert_eq!(theirs.author.as_deref(), Some("Ada"));

        assert_eq!(ours.title.as_deref(), Some("INDIRECT SECRET"));
        assert_eq!(
            theirs.title.as_deref(),
            None,
            "upstream now resolves an indirect /Info field value"
        );
    }

    #[test]
    fn upstream_still_reads_info_values_unnormalized() {
        let mut editor =
            DocumentEditor::open(fixture("metadata_encodings.pdf")).expect("fixture opens");
        let ours = read_metadata(editor.source());
        let theirs = editor.get_info().expect("info");

        // Control: both readers decode UTF-16BE identically.
        assert_eq!(ours.title.as_deref(), Some("Título 🙂"));
        assert_eq!(
            theirs.title.as_deref(),
            Some("Título 🙂"),
            "upstream stopped decoding /Info text strings again"
        );

        assert_eq!(ours.producer.as_deref(), Some("pdf_elixide ✓"));
        assert_eq!(
            theirs.producer.as_deref(),
            Some("\u{FEFF}pdf_elixide ✓"),
            "upstream now strips PDF 2.0's UTF-8 BOM from /Info"
        );

        assert_eq!(ours.mod_date, None);
        assert_eq!(
            theirs.mod_date.as_deref(),
            Some("   "),
            "upstream now normalizes a whitespace-only /Info value"
        );
    }

    // Justifies `resupply_info`.
    #[test]
    fn upstream_still_drops_info_on_an_untouched_full_rewrite() {
        let mut editor = DocumentEditor::open(fixture("metadata.pdf")).expect("fixture opens");
        assert_eq!(
            read_metadata(editor.source()).title.as_deref(),
            Some("Test Title")
        );

        let bytes = editor.save_to_bytes().expect("full rewrite");
        let written = PdfDocument::from_bytes(bytes).expect("output opens");

        assert!(
            read_metadata(&written).title.is_none(),
            "upstream now carries /Info across a full rewrite"
        );
    }

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
        for degrees in [90, -90, 450] {
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
    fn the_quadrant_backstop_never_yields_a_non_quadrant() {
        assert_eq!(round_to_quadrant(45, 0), 0);
        assert_eq!(round_to_quadrant(45, 90), 90);

        assert_eq!(round_to_quadrant(-90, 90), 0);

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

    fn authenticated(name: &str) -> DocumentEditor {
        let editor = DocumentEditor::open(fixture(name)).expect("fixture opens");
        assert!(
            editor
                .source()
                .authenticate(b"secret")
                .expect("the fixture authenticates"),
            "the fixture's password is still `secret`"
        );
        editor
    }

    // A decrypted control prevents fixture drift from passing the canary.
    fn decrypted_twin(name: &str) -> DocumentEditor {
        let bytes = authenticated(name)
            .save_to_bytes_with_options(SaveOptions::full_rewrite())
            .expect("a full rewrite decrypts");

        DocumentEditor::from_bytes(bytes).expect("the rewritten bytes open")
    }

    // Uncompressed, so an appearance that reached the page is greppable.
    fn flattened(mut editor: DocumentEditor, forms: bool) -> Vec<u8> {
        if forms {
            editor.flatten_forms().expect("every page is marked");
        } else {
            editor
                .flatten_all_annotations()
                .expect("every page is marked");
        }

        editor
            .save_to_bytes_with_options(SaveOptions {
                compress: false,
                ..SaveOptions::full_rewrite()
            })
            .expect("full rewrite")
    }

    fn holds(bytes: &[u8], needle: &str) -> bool {
        bytes
            .windows(needle.len())
            .any(|window| window == needle.as_bytes())
    }

    fn xmp_title(bytes: Vec<u8>) -> Option<String> {
        let doc = PdfDocument::from_bytes(bytes).expect("the rewritten bytes open");

        pdf_oxide::extractors::xmp::XmpExtractor::extract(&doc)
            .ok()
            .flatten()
            .and_then(|xmp| xmp.dc_title)
    }

    fn rewritten(mut editor: DocumentEditor) -> Vec<u8> {
        editor
            .save_to_bytes_with_options(SaveOptions::full_rewrite())
            .expect("full rewrite")
    }

    #[test]
    fn upstream_still_drops_unencrypted_metadata_on_a_rewrite() {
        let encrypted_metadata = {
            let mut plain = DocumentEditor::open(fixture("metadata.pdf")).expect("fixture opens");
            plain
                .save_to_bytes_with_options(SaveOptions::with_encryption(encryption_config(
                    EncryptionAlgorithm::Aes128,
                )))
                .expect("an encrypted write")
        };
        let twin = DocumentEditor::from_bytes(encrypted_metadata).expect("the twin opens");
        assert!(twin
            .source()
            .authenticate(b"secret")
            .expect("the twin authenticates"));

        assert_eq!(
            xmp_title(rewritten(twin)).as_deref(),
            Some("Test Title"),
            "the control lost its metadata too; the canary proves nothing"
        );

        assert_eq!(
            xmp_title(rewritten(authenticated("encrypted_cleartext_metadata.pdf"))),
            None,
            "upstream now carries an unencrypted /Metadata stream through a rewrite"
        );
    }

    #[test]
    fn upstream_still_drops_annotation_appearances_from_an_encrypted_source() {
        assert!(
            holds(
                &flattened(decrypted_twin("encrypted_flatten.pdf"), false),
                "SQUAREAP"
            ),
            "the fixture's /Square no longer flattens; fix it before reading the canary"
        );

        assert!(
            !holds(
                &flattened(authenticated("encrypted_flatten.pdf"), false),
                "SQUAREAP"
            ),
            "upstream now decrypts the appearance streams an annotation flatten reads"
        );
    }

    #[test]
    fn upstream_still_drops_widget_appearances_from_an_encrypted_source() {
        assert!(
            holds(
                &flattened(decrypted_twin("encrypted_flatten.pdf"), true),
                "WIDGETAP"
            ),
            "the fixture's widget no longer flattens; fix it before reading the canary"
        );

        assert!(
            !holds(
                &flattened(authenticated("encrypted_flatten.pdf"), true),
                "WIDGETAP"
            ),
            "upstream now decrypts the appearance streams a form flatten reads"
        );
    }

    #[test]
    fn upstream_still_refuses_an_incremental_save_of_an_encrypted_source() {
        let path = temp_path("incremental_encrypted");
        let mut editor = authenticated("encrypted.pdf");

        let result = editor.save_with_options(
            &path,
            SaveOptions {
                incremental: true,
                ..SaveOptions::full_rewrite()
            },
        );

        let _ = std::fs::remove_file(&path);
        assert!(
            result.is_err(),
            "upstream now writes an incremental update for an encrypted source"
        );
    }

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "pdf_elixide_drift_{name}_{}.pdf",
            std::process::id()
        ))
    }

    #[test]
    fn upstream_still_omits_perms_from_an_aes256_encrypt_dict() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        let bytes = editor
            .save_to_bytes_with_options(SaveOptions::with_encryption(encryption_config(
                EncryptionAlgorithm::Aes256,
            )))
            .expect("full rewrite");

        // Pin the algorithm so a different write cannot satisfy the refutation.
        assert!(
            bytes.windows(4).any(|w| w == b"/V 5"),
            "the write is no longer AES-256, so the check below proves nothing"
        );
        assert!(
            bytes.windows(4).any(|w| w == b"/R 6"),
            "the write is no longer revision 6, so the check below proves nothing"
        );

        assert!(
            !bytes.windows(6).any(|w| w == b"/Perms"),
            "upstream now writes /Perms for R6 — re-run the qpdf interop check \
             and lift the :aes256 refusal if it passes"
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

    const REVERSED: usize = 1;
    const INHERITED_BOX: usize = 2;
    const MISSING_BOX: usize = 5;
    const LETTER: [f32; 4] = [0.0, 0.0, 612.0, 792.0];

    #[test]
    fn upstream_still_reads_a_media_box_off_the_leaf_dictionary() {
        let mut editor = DocumentEditor::open(fixture("media_box.pdf")).expect("fixture opens");
        let doc = PdfDocument::open(fixture("media_box.pdf")).expect("fixture opens");

        assert_eq!(
            doc.get_page_media_box(INHERITED_BOX)
                .expect("the document reads"),
            (0.0, 0.0, 300.0, 500.0)
        );
        assert!(doc.get_page_media_box(MISSING_BOX).is_err());

        assert_eq!(
            editor
                .get_page_media_box(INHERITED_BOX)
                .expect("the editor reads"),
            LETTER,
            "the editor now resolves an inherited /MediaBox"
        );
        assert_eq!(
            editor
                .get_page_media_box(MISSING_BOX)
                .expect("the editor reads"),
            LETTER,
            "the editor now reports a missing /MediaBox instead of substituting Letter"
        );
    }

    #[test]
    fn upstream_still_reads_a_crop_box_off_the_leaf_dictionary() {
        let mut editor = DocumentEditor::open(fixture("crop_box.pdf")).expect("fixture opens");
        let doc = PdfDocument::open(fixture("crop_box.pdf")).expect("fixture opens");

        assert_eq!(
            read_crop_box(&doc, 1).expect("reads"),
            Some([50.0, 50.0, 300.0, 400.0])
        );
        assert_eq!(
            read_crop_box(&doc, 2).expect("reads"),
            Some([0.0, 0.0, 100.0, 100.0])
        );

        assert_eq!(
            (
                editor.get_page_crop_box(1).expect("reads"),
                editor.get_page_crop_box(2).expect("reads")
            ),
            (None, None),
            "the editor now resolves an inherited or indirect /CropBox"
        );
    }

    #[test]
    fn upstream_still_crops_a_reversed_box_outward() {
        let mut editor = DocumentEditor::open(fixture("media_box.pdf")).expect("fixture opens");

        editor.crop_margins(10.0, 10.0, 10.0, 10.0).expect("crops");

        assert_eq!(
            editor.get_page_crop_box(REVERSED).expect("reads"),
            Some([622.0, 802.0, -10.0, -10.0]),
            "upstream now normalizes the media box before measuring margins"
        );
    }

    #[test]
    fn upstream_still_crops_earlier_pages_before_failing() {
        let mut editor = DocumentEditor::open(fixture("broken_page.pdf")).expect("fixture opens");

        assert!(
            editor.crop_margins(10.0, 10.0, 10.0, 10.0).is_err(),
            "the unreadable page no longer fails the loop, so nothing below is tested"
        );
        assert!(
            editor.get_page_crop_box(0).expect("reads").is_some(),
            "upstream now reads every page before cropping any"
        );
    }

    #[test]
    fn crop_from_margins_measures_from_the_normalized_box() {
        let margins = MarginsNif {
            left: 10.0,
            right: 20.0,
            top: 30.0,
            bottom: 40.0,
        };

        assert_eq!(
            crop_from_margins([0.0, 0.0, 612.0, 792.0], margins),
            Ok([10.0, 40.0, 592.0, 762.0])
        );
        assert_eq!(
            crop_from_margins([612.0, 792.0, 0.0, 0.0], margins),
            Ok([10.0, 40.0, 592.0, 762.0])
        );
        assert_eq!(
            crop_from_margins([10.0, 20.0, 622.0, 812.0], margins),
            Ok([20.0, 60.0, 602.0, 782.0])
        );
    }

    #[test]
    fn crop_from_margins_refuses_an_empty_or_unrepresentable_crop() {
        let all = |m| MarginsNif {
            left: m,
            right: m,
            top: m,
            bottom: m,
        };

        assert_eq!(
            crop_from_margins([0.0, 0.0, 100.0, 100.0], all(50.0)),
            Err(CropRefusal::Empty)
        );
        assert_eq!(
            crop_from_margins([0.0, 0.0, 100.0, 300.0], all(50.0)),
            Err(CropRefusal::Empty)
        );
        assert_eq!(
            crop_from_margins([0.0, 0.0, 100.0, 100.0], all(49.0)),
            Ok([49.0, 49.0, 51.0, 51.0])
        );
        assert_eq!(
            crop_from_margins([-3.0e38, 0.0, 3.0e38, 10.0], all(0.0)),
            Err(CropRefusal::NotFinite)
        );
    }

    #[test]
    fn erase_corners_refuses_a_sum_that_overflows() {
        let rect = |x, y, width, height| RectNif {
            x,
            y,
            width,
            height,
        };

        assert_eq!(
            erase_corners(vec![rect(1.0, 2.0, 3.0, 4.0)]),
            Ok(vec![[1.0, 2.0, 4.0, 6.0]])
        );
        assert!(erase_corners(vec![rect(2.0e38, 0.0, 2.0e38, 10.0)]).is_err());
        assert!(erase_corners(vec![rect(0.0, -2.0e38, 10.0, -2.0e38)]).is_err());
    }

    #[test]
    fn upstream_still_nests_an_indirect_content_array() {
        let mut editor =
            DocumentEditor::open(fixture("contents_indirect_array.pdf")).expect("fixture opens");

        assert!(
            editor
                .source()
                .extract_text(0)
                .expect("reads the source")
                .contains("Indirect"),
            "the source page no longer reads, so the write below proves nothing"
        );

        editor
            .erase_regions(0, &[[0.0, 0.0, 10.0, 10.0]])
            .expect("records the region");
        let written = editor.save_to_bytes().expect("full rewrite");
        let reopened = PdfDocument::from_bytes(written).expect("reopens");

        let page = reopened.get_page(0).expect("page 0");
        let contents = page
            .as_dict()
            .and_then(|dict| dict.get("Contents"))
            .and_then(|contents| contents.as_array())
            .expect("the overlay splice rebuilds /Contents as an array");
        let first = contents[0]
            .as_reference()
            .and_then(|reference| reopened.load_object(reference).ok())
            .expect("the first entry is still a reference to a live object");

        assert!(
            first.as_array().is_some(),
            "upstream now resolves an indirect /Contents array before splicing"
        );
    }

    fn saved_incrementally(editor: &mut DocumentEditor, name: &str) -> PdfDocument {
        let path = temp_path(name);
        editor
            .save_with_options(
                &path,
                SaveOptions {
                    incremental: true,
                    ..SaveOptions::full_rewrite()
                },
            )
            .expect("incremental save");

        let doc = PdfDocument::open(&path).expect("output opens");
        let _ = std::fs::remove_file(&path);

        doc
    }

    #[test]
    fn upstream_still_drops_page_order_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        editor.remove_page(1).expect("page removed");
        editor.move_page(1, 0).expect("page moved");
        assert_eq!(editor.current_page_count(), 2);

        let doc = saved_incrementally(&mut editor, "page_order");

        assert_eq!(
            doc.page_count().expect("page count"),
            3,
            "upstream now carries the page tree into an incremental update"
        );

        let text: Vec<String> = (0..3)
            .map(|page| {
                doc.extract_text(page)
                    .unwrap_or_default()
                    .trim()
                    .to_string()
            })
            .collect();
        assert_eq!(text, ["Page One", "Page Two", "Page Three"]);
    }

    #[test]
    fn upstream_still_drops_a_pending_attachment_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        editor
            .embed_file("data.csv", b"a,b\n".to_vec())
            .expect("file embedded");

        let path = temp_path("attachment");
        editor
            .save_with_options(
                &path,
                SaveOptions {
                    incremental: true,
                    ..SaveOptions::full_rewrite()
                },
            )
            .expect("incremental save");
        let bytes = std::fs::read(&path).expect("reads back");
        let _ = std::fs::remove_file(&path);

        assert!(
            !bytes.windows(8).any(|w| w == b"data.csv"),
            "upstream now writes pending attachments into an incremental update"
        );
    }

    #[test]
    fn upstream_still_drops_a_page_rotation_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("rotation.pdf")).expect("fixture opens");
        editor.rotate_all_pages(90).expect("pages rotated");

        let doc = saved_incrementally(&mut editor, "rotation");
        let rotations: Vec<i32> = (0..4)
            .map(|page| doc.get_page_rotation(page).expect("rotation"))
            .collect();

        assert_eq!(
            rotations,
            [90, 180, 270, 0],
            "upstream now carries page properties into an incremental update"
        );
    }

    #[test]
    fn upstream_still_drops_a_page_box_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        editor
            .set_page_media_box(0, [0.0, 0.0, 100.0, 50.0])
            .expect("media box set");
        editor
            .set_page_crop_box(1, [0.0, 0.0, 100.0, 50.0])
            .expect("crop box set");

        let doc = saved_incrementally(&mut editor, "boxes");

        assert_eq!(
            doc.get_page_media_box(0).expect("media box"),
            (0.0, 0.0, 612.0, 792.0),
            "upstream now carries page properties into an incremental update"
        );
        assert_eq!(read_crop_box(&doc, 1).expect("crop box"), None);
    }

    #[test]
    fn upstream_still_drops_an_erase_overlay_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("sample.pdf")).expect("fixture opens");
        editor
            .erase_regions(0, &[[0.0, 0.0, 612.0, 792.0]])
            .expect("region erased");

        let doc = saved_incrementally(&mut editor, "erase");

        assert!(
            doc.extract_rects(0).expect("rects").is_empty(),
            "upstream now carries erase overlays into an incremental update"
        );
    }

    #[test]
    fn upstream_still_drops_a_redaction_mark_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("redact.pdf")).expect("fixture opens");
        editor.apply_page_redactions(0).expect("page marked");

        let doc = saved_incrementally(&mut editor, "redaction");

        assert!(
            doc.extract_rects(0).expect("rects").is_empty(),
            "upstream now carries redaction overlays into an incremental update"
        );
        assert_eq!(
            doc.get_annotations(0).expect("annotations").len(),
            3,
            "upstream now drops the annotations in an incremental update too"
        );
    }

    #[test]
    fn upstream_still_drops_flatten_marks_from_an_incremental_save() {
        let mut editor = DocumentEditor::open(fixture("flatten.pdf")).expect("fixture opens");
        editor.flatten_forms().expect("forms marked");

        let doc = saved_incrementally(&mut editor, "flatten");
        let names: Vec<String> = FormExtractor::extract_fields(&doc)
            .expect("fields extract")
            .into_iter()
            .map(|field| field.name)
            .collect();

        assert_eq!(
            names,
            ["full_name", "comments"],
            "upstream now honours the flatten marks in an incremental update"
        );
        assert!(editor.flatten_warnings().is_empty());
    }

    #[test]
    fn spell_out_of_nothing_is_empty() {
        assert_eq!(spell_out(&[]), "");
    }
}
