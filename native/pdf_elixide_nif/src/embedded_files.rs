// File attachments — the catalog's `/Names /EmbeddedFiles` name tree, read
// locally and written through upstream's editor.

use pdf_oxide::{
    object::{Object, ObjectRef},
    writer::{AFRelationship, EmbeddedFile},
    PdfDocument,
};
use rustler::{Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};

use crate::{
    atoms,
    binary::binary_term,
    error::{tagged_err, to_nif_err},
    metadata::decode_pdf_text_string,
    DocumentResource,
};

// PDF 2.0 associated-file relationships (ISO 32000-2 table 43).
#[derive(NifUnitEnum, Debug, Clone, Copy, PartialEq)]
pub enum RelationshipNif {
    Source,
    Data,
    Alternative,
    Supplement,
    EncryptedPayload,
    FormData,
    Schema,
    Unspecified,
}

impl From<RelationshipNif> for AFRelationship {
    fn from(r: RelationshipNif) -> Self {
        match r {
            RelationshipNif::Source => AFRelationship::Source,
            RelationshipNif::Data => AFRelationship::Data,
            RelationshipNif::Alternative => AFRelationship::Alternative,
            RelationshipNif::Supplement => AFRelationship::Supplement,
            RelationshipNif::EncryptedPayload => AFRelationship::EncryptedPayload,
            RelationshipNif::FormData => AFRelationship::FormData,
            RelationshipNif::Schema => AFRelationship::Schema,
            RelationshipNif::Unspecified => AFRelationship::Unspecified,
        }
    }
}

fn relationship_to_nif(relationship: AFRelationship) -> RelationshipNif {
    match relationship {
        AFRelationship::Source => RelationshipNif::Source,
        AFRelationship::Data => RelationshipNif::Data,
        AFRelationship::Alternative => RelationshipNif::Alternative,
        AFRelationship::Supplement => RelationshipNif::Supplement,
        AFRelationship::EncryptedPayload => RelationshipNif::EncryptedPayload,
        AFRelationship::FormData => RelationshipNif::FormData,
        AFRelationship::Schema => RelationshipNif::Schema,
        AFRelationship::Unspecified => RelationshipNif::Unspecified,
    }
}

fn relationship_from_name(name: &str) -> Option<RelationshipNif> {
    match name {
        "Source" => Some(RelationshipNif::Source),
        "Data" => Some(RelationshipNif::Data),
        "Alternative" => Some(RelationshipNif::Alternative),
        "Supplement" => Some(RelationshipNif::Supplement),
        "EncryptedPayload" => Some(RelationshipNif::EncryptedPayload),
        "FormData" => Some(RelationshipNif::FormData),
        "Schema" => Some(RelationshipNif::Schema),
        "Unspecified" => Some(RelationshipNif::Unspecified),
        _ => None,
    }
}

// The plain upstream constructor cannot carry the optional fields.
pub fn embedded_file(
    name: String,
    data: Vec<u8>,
    description: Option<String>,
    relationship: Option<RelationshipNif>,
) -> EmbeddedFile {
    let mut file = EmbeddedFile::new(name, data);
    file.description = description;
    file.af_relationship = relationship.map(AFRelationship::from);

    file
}

// Reject populated name trees because the writer replaces rather than merges
// them.
pub fn ensure_no_name_tree(doc: &PdfDocument) -> NifResult<()> {
    let catalog = doc.catalog().map_err(to_nif_err)?;
    let Some(names) = catalog.as_dict().and_then(|dict| dict.get("Names")) else {
        return Ok(());
    };

    let mut keys = match doc.resolve_object(names) {
        Ok(resolved) => match resolved.as_dict() {
            Some(dict) if dict.is_empty() => return Ok(()),
            Some(dict) => dict.keys().map(String::from).collect(),
            None => return Ok(()),
        },
        // Unreadable is not the same as absent: a tree that cannot be inspected
        // is one whose loss cannot be ruled out.
        Err(_) => Vec::new(),
    };
    keys.sort_unstable();

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "Embedding a file rebuilds this document's /Names dictionary and would drop \
             its existing entries ({}). Write the pages and data you want to a new \
             document instead.",
            if keys.is_empty() {
                "unreadable".to_string()
            } else {
                keys.join(", ")
            }
        ),
    ))
}

// Refuse rather than silently truncate excessively deep trees.
const MAX_NAME_TREE_DEPTH: u8 = 32;

// A depth cap alone does not bound repeated expansion of a shared child.
const MAX_NAME_TREE_NODES: usize = 100_000;

// Keep the walk BEAM-independent; build the reason atom outside.
#[derive(Debug)]
enum Refused {
    Cycle,
    TooDeep,
    TooLarge,
}

fn refused_err(refused: Refused) -> rustler::Error {
    match refused {
        // A cycle is a malformed document; the caps are this binding declining.
        Refused::Cycle => tagged_err(
            atoms::invalid_pdf(),
            "Embedded-file name tree contains a /Kids cycle",
        ),
        Refused::TooDeep => tagged_err(
            atoms::unsupported(),
            format!(
                "Embedded-file name tree nesting exceeds the supported depth of \
                 {MAX_NAME_TREE_DEPTH}"
            ),
        ),
        Refused::TooLarge => tagged_err(
            atoms::unsupported(),
            format!(
                "Embedded-file name tree exceeds the supported size of \
                 {MAX_NAME_TREE_NODES} nodes"
            ),
        ),
    }
}

// One attachment's metadata, in the order upstream's own walk yields it.
struct FileSpec {
    name: String,
    description: Option<String>,
    mime_type: Option<String>,
    relationship: Option<RelationshipNif>,
    size: Option<i64>,
    checksum: Option<Vec<u8>>,
    created: Option<String>,
    modified: Option<String>,
}

#[derive(NifMap)]
pub struct EmbeddedFileNif<'a> {
    name: String,
    data: Term<'a>,
    description: Option<String>,
    mime_type: Option<String>,
    relationship: Option<RelationshipNif>,
    size: Option<i64>,
    checksum: Option<Term<'a>>,
    created: Option<String>,
    modified: Option<String>,
}

fn text(doc: &PdfDocument, value: Option<&Object>) -> Option<String> {
    let resolved = doc.resolve_object(value?).ok()?;

    resolved.as_string().map(decode_pdf_text_string)
}

// The byte sibling of `text`: `as_string` borrows the resolved object, so the
// copy has to happen before it is dropped.
fn bytes(doc: &PdfDocument, value: Option<&Object>) -> Option<Vec<u8>> {
    let resolved = doc.resolve_object(value?).ok()?;

    resolved.as_string().map(<[u8]>::to_vec)
}

struct Walker<'a> {
    doc: &'a PdfDocument,
    // Track ancestors so valid DAG reuse remains possible; the budget bounds
    // repeated expansion.
    path: Vec<ObjectRef>,
    budget: usize,
    out: Vec<FileSpec>,
}

impl Walker<'_> {
    // Preserve the decoder's leaf-before-children order for positional pairing.
    fn node(&mut self, node: &Object, depth: u8) -> Result<(), Refused> {
        if depth > MAX_NAME_TREE_DEPTH {
            return Err(Refused::TooDeep);
        }
        self.budget = self.budget.checked_sub(1).ok_or(Refused::TooLarge)?;

        let node_ref = node.as_reference();
        if let Some(node_ref) = node_ref {
            if self.path.contains(&node_ref) {
                return Err(Refused::Cycle);
            }

            self.path.push(node_ref);
        }

        let walked = self.walk(node, depth);

        if node_ref.is_some() {
            self.path.pop();
        }

        walked
    }

    fn walk(&mut self, node: &Object, depth: u8) -> Result<(), Refused> {
        let Ok(node) = self.doc.resolve_object(node) else {
            return Ok(());
        };
        let Some(dict) = node.as_dict() else {
            return Ok(());
        };

        if let Some(names) = dict
            .get("Names")
            .and_then(|n| self.doc.resolve_object(n).ok())
        {
            if let Some(array) = names.as_array() {
                for entry in array.iter().skip(1).step_by(2) {
                    // A filespec costs as much to read as an interior node, so
                    // the budget has to cover the leaves too.
                    self.budget = self.budget.checked_sub(1).ok_or(Refused::TooLarge)?;

                    let Ok(spec) = self.doc.resolve_object(entry) else {
                        continue;
                    };
                    if let Some(spec) = file_spec(self.doc, &spec) {
                        self.out.push(spec);
                    }
                }
            }
        }

        if let Some(kids) = dict
            .get("Kids")
            .and_then(|k| self.doc.resolve_object(k).ok())
        {
            if let Some(array) = kids.as_array() {
                for kid in array {
                    self.node(kid, depth + 1)?;
                }
            }
        }

        Ok(())
    }
}

// Match the decoder's skipped filespecs so metadata and bytes stay aligned.
fn file_spec(doc: &PdfDocument, spec: &Object) -> Option<FileSpec> {
    let dict = spec.as_dict()?;

    // Prefer the Unicode name, falling back when it is unreadable.
    let name = text(doc, dict.get("UF"))
        .or_else(|| text(doc, dict.get("F")))
        .unwrap_or_else(|| "attachment".to_string());

    let ef = doc.resolve_object(dict.get("EF")?).ok()?;
    let ef = ef.as_dict()?;
    let stream_ref: ObjectRef = ef
        .get("F")
        .or_else(|| ef.get("UF"))
        .and_then(|r| r.as_reference())?;
    let stream = doc.load_object(stream_ref).ok()?;

    // `/Subtype` and `/Params` sit on the embedded-file stream, not the filespec.
    let stream_dict = stream.as_dict();
    let mime_type = stream_dict
        .and_then(|d| d.get("Subtype"))
        .and_then(|s| doc.resolve_object(s).ok())
        .and_then(|s| s.as_name().map(str::to_string));
    let params = stream_dict
        .and_then(|d| d.get("Params"))
        .and_then(|p| doc.resolve_object(p).ok());
    let params = params.as_ref().and_then(|p| p.as_dict());

    Some(FileSpec {
        name,
        description: text(doc, dict.get("Desc")),
        mime_type,
        relationship: dict
            .get("AFRelationship")
            .and_then(|r| doc.resolve_object(r).ok())
            .and_then(|r| r.as_name().and_then(relationship_from_name)),
        // A negative declared size is malformed, and `non_neg_integer()` is what
        // the struct promises, so report it as absent rather than as a value.
        size: params
            .and_then(|p| p.get("Size"))
            .and_then(|s| doc.resolve_object(s).ok())
            .and_then(|s| s.as_integer())
            .filter(|size| *size >= 0),
        checksum: params.and_then(|p| bytes(doc, p.get("CheckSum"))),
        created: params.and_then(|p| text(doc, p.get("CreationDate"))),
        modified: params.and_then(|p| text(doc, p.get("ModDate"))),
    })
}

// Writer-generated metadata is absent until the attachment is serialized.
pub fn pending_to_nif<'a>(env: Env<'a>, file: &EmbeddedFile) -> NifResult<EmbeddedFileNif<'a>> {
    Ok(EmbeddedFileNif {
        name: file.name.clone(),
        data: binary_term(env, &file.data, "embedded file")?,
        description: file.description.clone(),
        mime_type: file.mime_type.clone(),
        relationship: file.af_relationship.map(relationship_to_nif),
        size: None,
        checksum: None,
        created: None,
        modified: None,
    })
}

pub fn read_embedded_files<'a>(
    env: Env<'a>,
    doc: &PdfDocument,
) -> NifResult<Vec<EmbeddedFileNif<'a>>> {
    let catalog = doc.catalog().map_err(to_nif_err)?;
    let root = catalog
        .as_dict()
        .and_then(|dict| dict.get("Names"))
        .and_then(|names| doc.resolve_object(names).ok())
        .and_then(|names| {
            names
                .as_dict()
                .and_then(|d| d.get("EmbeddedFiles"))
                .cloned()
        });

    let mut walker = Walker {
        doc,
        path: Vec::new(),
        budget: MAX_NAME_TREE_NODES,
        out: Vec::new(),
    };
    if let Some(root) = root {
        // Enforce the bounds before calling the unbounded decoder walk.
        walker.node(&root, 0).map_err(refused_err)?;
    }
    let specs = walker.out;

    // Stream decoding is private upstream, so metadata and bytes need two walks.
    let decoded = doc.extract_embedded_files().map_err(to_nif_err)?;
    if decoded.len() != specs.len() {
        // A skipped decode cannot be paired safely with positional metadata.
        return Err(tagged_err(
            atoms::invalid_pdf(),
            format!(
                "Document declares {} embedded files but {} could be decoded",
                specs.len(),
                decoded.len()
            ),
        ));
    }

    specs
        .into_iter()
        .zip(decoded)
        .map(|(spec, (_name, data))| {
            Ok(EmbeddedFileNif {
                name: spec.name,
                data: binary_term(env, &data, "embedded file")?,
                description: spec.description,
                mime_type: spec.mime_type,
                relationship: spec.relationship,
                size: spec.size,
                checksum: spec
                    .checksum
                    .map(|bytes| binary_term(env, &bytes, "embedded file checksum"))
                    .transpose()?,
                created: spec.created,
                modified: spec.modified,
            })
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_embedded_files<'a>(
    env: Env<'a>,
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Vec<EmbeddedFileNif<'a>>> {
    resource.doc.with_read(|doc| read_embedded_files(env, doc))
}
