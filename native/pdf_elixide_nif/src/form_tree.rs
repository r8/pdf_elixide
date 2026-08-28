// Validates an AcroForm field tree and resolves the inheritable attributes
// upstream reads off a field's own dictionary — `/FT`, `/Ff`, `/V`, `/MaxLen`
// and `/Q` — before extraction, plus `/Opt`, which it never reads.

use std::collections::{HashMap, HashSet};

use pdf_oxide::{
    extractors::{
        forms::{FieldType, FormExtractor},
        FormField,
    },
    object::{Object, ObjectRef},
    PdfDocument,
};
use rustler::NifResult;

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
    form::ChoiceOptionNif,
    metadata::decode_pdf_text_string,
};

// Bound the native recursion before handing the tree to the uncapped extractor.
const MAX_FIELD_DEPTH: usize = 256;

// Depth alone does not bound a DAG whose shared subtrees are reached by many paths.
const MAX_FIELD_NODES: usize = 100_000;

// Upstream's `FormExtractor::parse_field_type` is private, so the four names it
// recognizes are transcribed here.
fn field_type_of(name: &str) -> FieldType {
    match name {
        "Btn" => FieldType::Button,
        "Tx" => FieldType::Text,
        "Ch" => FieldType::Choice,
        "Sig" => FieldType::Signature,
        other => FieldType::Unknown(other.to_string()),
    }
}

// Keep the walk BEAM-independent; build reason atoms only at its boundary.
#[derive(Debug, PartialEq)]
enum Refused {
    Cycle,
    TooDeep,
    TooLarge,
    Unreadable,
}

// Everything the walk decided about one field, as indices into the pools on
// `Walked` where the value is not a plain integer. An attribute the walk
// *rejected* is an absent `Option` on a present entry.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct FieldAttrs {
    field_type: Option<usize>,
    flags: Option<u32>,
    options: Option<usize>,
    max_length: Option<u32>,
    // The raw `/Q`, normalized to an alignment by the caller — an out-of-range
    // value must reach `alignment_nif` rather than being dropped here, so that
    // an own malformed `/Q` still shadows an inherited valid one.
    quadding: Option<u32>,
}

// Names, rather than object references, are the common key available to both
// document and editor form APIs — `get_form_fields` builds every wrapper with
// `object_ref: None`.
#[derive(Debug, Default)]
pub struct Resolved {
    signatures: HashSet<String>,
    attrs: HashMap<String, FieldAttrs>,
    option_lists: Vec<Vec<ChoiceOptionNif>>,
    field_types: Vec<FieldType>,
}

impl Resolved {
    pub fn is_signature(&self, name: &str) -> bool {
        self.signatures.contains(name)
    }

    // Every resolved attribute in one lookup, so the document and editor call
    // sites cannot fall out of step. `None` means the walk never reached this
    // field — an inline field dictionary, which has no object reference to key
    // on — and only then may the caller answer from the source's own reading.
    pub fn attrs(&self, name: &str) -> Option<ResolvedAttrs<'_>> {
        let attrs = self.attrs.get(name)?;

        Some(ResolvedAttrs {
            field_type: attrs.field_type.map(|id| self.field_types[id].clone()),
            flags: attrs.flags,
            options: attrs.options.map(|id| self.option_lists[id].as_slice()),
            max_length: attrs.max_length,
            quadding: attrs.quadding,
        })
    }
}

// What this walk resolves and neither upstream source does: `/FT`, `/Ff`,
// `/MaxLen` and `/Q`, which upstream reads off the own dictionary, and `/Opt`,
// which its forms path never reads.
#[derive(Clone, Debug, Default)]
pub struct ResolvedAttrs<'a> {
    pub field_type: Option<FieldType>,
    pub flags: Option<u32>,
    pub options: Option<&'a [ChoiceOptionNif]>,
    pub max_length: Option<u32>,
    pub quadding: Option<u32>,
}

// Return fields and their resolved attributes together to avoid repeating
// extraction.
pub fn extract_fields(doc: &PdfDocument) -> NifResult<(Vec<FormField>, Resolved)> {
    let walked = walk(doc, Strictness::Tolerant).map_err(refused_err)?;

    let fields = FormExtractor::extract_fields(doc).map_err(to_nif_err)?;
    let resolved = resolved_of(&fields, walked);

    Ok((fields, resolved))
}

pub fn resolved(doc: &PdfDocument) -> NifResult<Resolved> {
    extract_fields(doc).map(|(_fields, resolved)| resolved)
}

// Only the first duplicate name matters because the editor writes the first match.
//
// Takes `Walked` by value so the interned option lists move across rather than
// being cloned per field; nothing reads the walk again afterwards.
fn resolved_of(fields: &[FormField], walked: Walked) -> Resolved {
    let mut resolved = Resolved {
        option_lists: walked.option_lists,
        field_types: walked.field_types,
        ..Resolved::default()
    };
    let mut seen = HashSet::new();

    for field in fields {
        if !seen.insert(&field.full_name) {
            continue;
        }

        let is_signature = field.field_type == FieldType::Signature
            || field
                .object_ref
                .is_some_and(|obj_ref| walked.signatures.contains(&obj_ref));

        if is_signature {
            resolved.signatures.insert(field.full_name.clone());
        }

        if let Some(attrs) = field
            .object_ref
            .and_then(|obj_ref| walked.attrs.get(&obj_ref))
        {
            resolved.attrs.insert(field.full_name.clone(), *attrs);
        }
    }

    resolved
}

// Do not let an unreadable object turn into a false "no signatures" result.
pub fn signature_values(doc: &PdfDocument) -> NifResult<Vec<Object>> {
    walk(doc, Strictness::Strict)
        .map(|walked| {
            walked
                .signature_values
                .into_iter()
                .map(|(value, _obj_ref)| value)
                .collect()
        })
        .map_err(refused_err)
}

#[derive(Debug, Default)]
pub struct Signatures {
    // Effective `/V` values paired with their full field names.
    pub values: Vec<(Object, Option<String>)>,
    // Full names of terminal signature fields carrying no signature.
    pub unsigned: Vec<String>,
}

pub fn signatures(doc: &PdfDocument) -> NifResult<Signatures> {
    let walked = walk(doc, Strictness::Strict).map_err(refused_err)?;

    if walked.signature_values.is_empty() && walked.signatures.is_empty() {
        return Ok(Signatures::default());
    }

    let fields = FormExtractor::extract_fields(doc).map_err(to_nif_err)?;

    let mut names: HashMap<ObjectRef, String> = HashMap::new();
    let mut seen = HashSet::new();
    let mut unsigned = Vec::new();

    for field in &fields {
        // Upstream represents a field with no `/T` as an empty full name.
        let named = !field.full_name.is_empty();

        if let (Some(obj_ref), true) = (field.object_ref, named) {
            names
                .entry(obj_ref)
                .or_insert_with(|| field.full_name.clone());
        }

        // Claim the name before filtering so duplicates match `resolved_of`.
        if !seen.insert(&field.full_name) {
            continue;
        }

        // The walk cannot establish vacancy for an inline, unreferenced field.
        let Some(obj_ref) = field.object_ref else {
            continue;
        };

        let is_signature =
            field.field_type == FieldType::Signature || walked.signatures.contains(&obj_ref);

        // A terminal field can inherit a signature from an ancestor, so both
        // structure and signing state determine whether it is vacant.
        let vacant = !walked.grouping.contains(&obj_ref) && !walked.signed.contains(&obj_ref);

        if is_signature && named && vacant {
            unsigned.push(field.full_name.clone());
        }
    }

    let values = walked
        .signature_values
        .into_iter()
        .map(|(value, obj_ref)| {
            let name = obj_ref.and_then(|obj_ref| names.get(&obj_ref).cloned());

            (value, name)
        })
        .collect();

    Ok(Signatures { values, unsigned })
}

fn refused_err(refused: Refused) -> rustler::Error {
    match refused {
        // A cycle is a malformed document; the caps are this binding declining.
        Refused::Cycle => tagged_err(
            atoms::invalid_pdf(),
            "AcroForm field tree contains a /Kids cycle",
        ),
        Refused::TooDeep => tagged_err(
            atoms::unsupported(),
            format!("AcroForm field nesting exceeds the supported depth of {MAX_FIELD_DEPTH}"),
        ),
        Refused::TooLarge => tagged_err(
            atoms::unsupported(),
            format!("AcroForm field tree exceeds the supported size of {MAX_FIELD_NODES} nodes"),
        ),
        Refused::Unreadable => tagged_err(
            atoms::invalid_pdf(),
            "AcroForm field tree contains an unreadable object",
        ),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Strictness {
    Strict,
    Tolerant,
}

// What one walk of the field tree yields, keyed by object reference.
#[derive(Debug, Default, PartialEq)]
struct Walked {
    // Every field object whose *effective* `/FT` is `/Sig`.
    signatures: HashSet<ObjectRef>,
    // Effective `/V` values in the document order `Signature.list/1` reports,
    // each with the field object that carried it.
    signature_values: Vec<(Object, Option<ObjectRef>)>,
    // A field and its widget kids commonly share one signature dictionary.
    signature_value_refs: HashSet<ObjectRef>,
    // Field objects with a field kid rather than only widget kids.
    grouping: HashSet<ObjectRef>,
    // Signature fields carrying a signature, and every ancestor of one.
    signed: HashSet<ObjectRef>,
    // One entry per field object the walk reached, holding its effective
    // attributes. Presence is load-bearing: it is what tells a field the walk
    // rejected a declaration on from one the walk never saw.
    attrs: HashMap<ObjectRef, FieldAttrs>,
    // Interned. `Inherited` carries an index rather than the list itself
    // because a choice field may list thousands of options and the node budget
    // would multiply them, exactly as it would a direct `/V`.
    option_lists: Vec<Vec<ChoiceOptionNif>>,
    // Interned for the same reason, and because it keeps `Inherited` `Copy`
    // where an owned `FieldType::Unknown(String)` would not.
    field_types: Vec<FieldType>,
}

// Resolves the inheritable attributes, validating the tree on the way.
fn walk(doc: &PdfDocument, strictness: Strictness) -> Result<Walked, Refused> {
    let Some(fields) = root_fields(doc, strictness)? else {
        return Ok(Walked::default());
    };

    let mut walker = Walker {
        doc,
        path: Vec::new(),
        walked: Walked::default(),
        budget: MAX_FIELD_NODES,
        strictness,
        option_ids: HashMap::new(),
        field_type_ids: HashMap::new(),
    };

    for field in &fields {
        walker.node(field, Inherited::default(), 0)?;
    }

    Ok(walker.walked)
}

// Missing `/AcroForm` or `/Fields` means no form; unreadable values follow the
// requested strictness.
fn root_fields(doc: &PdfDocument, strictness: Strictness) -> Result<Option<Vec<Object>>, Refused> {
    let unreadable = || match strictness {
        Strictness::Strict => Err(Refused::Unreadable),
        Strictness::Tolerant => Ok(None),
    };

    let Ok(catalog) = doc.catalog() else {
        return unreadable();
    };
    let Some(catalog) = catalog.as_dict() else {
        return unreadable();
    };

    let Some(raw_acroform) = catalog.get("AcroForm") else {
        return Ok(None);
    };
    let Some(acroform) = resolve(doc, raw_acroform) else {
        return unreadable();
    };
    let Some(acroform) = acroform.as_dict() else {
        return unreadable();
    };

    let Some(raw_fields) = acroform.get("Fields") else {
        return Ok(None);
    };
    let Some(fields) = resolve(doc, raw_fields) else {
        return unreadable();
    };
    let Some(fields) = fields.as_array() else {
        return unreadable();
    };

    Ok(Some(fields.clone()))
}

fn resolve(doc: &PdfDocument, obj: &Object) -> Option<Object> {
    match obj.as_reference() {
        Some(obj_ref) => doc.load_object(obj_ref).ok(),
        None => Some(obj.clone()),
    }
}

// The ancestors' verdict, which a node declaring neither attribute adopts.
// §12.7.3.1 inherits each attribute whole, so `/Ff` is carried down as one
// value rather than merged bit by bit.
#[derive(Clone, Copy, Debug, Default)]
struct Inherited {
    // An index into `Walked::field_types`, so this stays `Copy`.
    field_type: Option<usize>,
    flags: Option<u32>,
    // Carry only references; copying a direct `/V` through the tree could
    // multiply a large signature dictionary by the node budget.
    value: Option<ObjectRef>,
    // An index into `Walked::option_lists`, for the same reason.
    options: Option<usize>,
    // Plain integers, so these are carried by value and `Inherited` stays `Copy`.
    max_length: Option<u32>,
    quadding: Option<u32>,
    // Immediate parent; unlike the attributes above, this is not inherited.
    parent: Option<ObjectRef>,
}

struct Walker<'a> {
    doc: &'a PdfDocument,
    // The references on the path from a root field to the current node — an
    // ancestor stack, not a visited set. A node reached twice by *different*
    // paths is a DAG, which upstream expands rather than looping on; only a
    // back edge is a cycle, and `MAX_FIELD_NODES` is what bounds the former.
    path: Vec<ObjectRef>,
    walked: Walked,
    budget: usize,
    strictness: Strictness,
    // One decode per *declaring* object, however many paths reach it. Keyed by
    // the `/Opt` array when indirect and by the declaring field otherwise, so
    // first-write-wins is correct here where it would not be for a value.
    option_ids: HashMap<ObjectRef, usize>,
    // Keyed by the `/FT` name itself: a form declares a handful of distinct
    // types however many fields it has, so there is nothing to key per object.
    field_type_ids: HashMap<String, usize>,
}

impl Walker<'_> {
    fn resolve_or_refuse(&self, obj: &Object) -> Result<Option<Object>, Refused> {
        match resolve(self.doc, obj) {
            Some(resolved) => Ok(Some(resolved)),
            None => match self.strictness {
                Strictness::Strict => Err(Refused::Unreadable),
                Strictness::Tolerant => Ok(None),
            },
        }
    }

    fn entry(&self, dict: &HashMap<String, Object>, key: &str) -> Result<Option<Object>, Refused> {
        match dict.get(key) {
            Some(raw) => self.resolve_or_refuse(raw),
            None => Ok(None),
        }
    }

    // Interns one `/FT` name and hands back its index.
    fn intern_field_type(&mut self, name: &str) -> usize {
        if let Some(&id) = self.field_type_ids.get(name) {
            return id;
        }

        self.walked.field_types.push(field_type_of(name));

        let id = self.walked.field_types.len() - 1;

        self.field_type_ids.insert(name.to_string(), id);

        id
    }

    // Decodes one `/Opt` array into the pool and hands back its index, reusing
    // the entry already decoded for the same declaring object.
    fn intern_options(
        &mut self,
        raw: &Object,
        owner: Option<ObjectRef>,
    ) -> Result<Option<usize>, Refused> {
        // An `ObjectRef` names one object, which is either the array or the
        // field dictionary, so the two key spaces cannot collide.
        let key = raw.as_reference().or(owner);

        if let Some(id) = key.and_then(|key| self.option_ids.get(&key)) {
            return Ok(Some(*id));
        }

        let Some(resolved) = self.resolve_or_refuse(raw)? else {
            return Ok(None);
        };
        // A non-array `/Opt` is malformed; upstream would drop it too, and this
        // walk does not decide whether a document is readable.
        let Some(entries) = resolved.as_array() else {
            return Ok(None);
        };

        let options = entries
            .iter()
            .filter_map(|entry| self.choice_option(entry))
            .collect();

        self.walked.option_lists.push(options);
        let id = self.walked.option_lists.len() - 1;

        if let Some(key) = key {
            self.option_ids.insert(key, id);
        }

        Ok(Some(id))
    }

    // One `/Opt` entry (Table 231). A malformed entry is skipped rather than
    // failing the array, so the options around it survive.
    fn choice_option(&self, entry: &Object) -> Option<ChoiceOptionNif> {
        match resolve(self.doc, entry)? {
            Object::Array(pair) if pair.len() == 2 => Some(ChoiceOptionNif::Pair((
                self.option_text(&pair[0])?,
                self.option_text(&pair[1])?,
            ))),
            other => Some(ChoiceOptionNif::Export(self.option_text(&other)?)),
        }
    }

    fn option_text(&self, obj: &Object) -> Option<String> {
        match resolve(self.doc, obj)? {
            Object::String(bytes) => Some(decode_pdf_text_string(&bytes)),
            Object::Name(name) => Some(name),
            _ => None,
        }
    }

    fn node(&mut self, obj: &Object, inherited: Inherited, depth: usize) -> Result<(), Refused> {
        if depth >= MAX_FIELD_DEPTH {
            return Err(Refused::TooDeep);
        }

        self.budget = self.budget.checked_sub(1).ok_or(Refused::TooLarge)?;

        let obj_ref = obj.as_reference();

        if let Some(obj_ref) = obj_ref {
            if self.path.contains(&obj_ref) {
                return Err(Refused::Cycle);
            }

            self.path.push(obj_ref);
        }

        let result = self.kids(obj, obj_ref, inherited, depth);

        if obj_ref.is_some() {
            self.path.pop();
        }

        result
    }

    // Classifies the node and recurses into its `/Kids`.
    //
    // Split from [`Self::node`] so the ancestor stack is popped on every exit
    // without a `?` in sight having to remember to do it.
    fn kids(
        &mut self,
        obj: &Object,
        obj_ref: Option<ObjectRef>,
        inherited: Inherited,
        depth: usize,
    ) -> Result<(), Refused> {
        let Some(field) = self.resolve_or_refuse(obj)? else {
            return Ok(());
        };
        // Upstream resolves a dangling reference to null, so strictness must
        // also apply when the resolved field is not a dictionary.
        let Some(dict) = field.as_dict() else {
            return match self.strictness {
                Strictness::Strict => Err(Refused::Unreadable),
                Strictness::Tolerant => Ok(()),
            };
        };

        // An own declaration settles it in both directions: a `/Tx` leaf under a
        // `/Sig` parent is a text field, not an inherited signature. A `/FT`
        // that is not a name is malformed and blocks inheritance the way a
        // non-integer `/Ff` does, rather than falling through to the ancestor.
        let field_type = match self.entry(dict, "FT")? {
            Some(object) => object.as_name().map(|name| self.intern_field_type(name)),
            None => inherited.field_type,
        };

        let signature =
            field_type.is_some_and(|id| self.walked.field_types[id] == FieldType::Signature);

        let flags = match self.entry(dict, "Ff")? {
            Some(Object::Integer(bits)) => u32::try_from(bits).ok(),
            // A non-integer `/Ff` is malformed; upstream drops it too, and this
            // walk does not decide whether a document is readable.
            Some(_) => None,
            None => inherited.flags,
        };

        // `/MaxLen` (Table 229) and `/Q` (Table 222) take `/Ff`'s
        // malformed-is-dropped rule. `/Q` is carried raw: mapping an
        // out-of-range value to "none" here would let it inherit instead.
        let max_length = match self.entry(dict, "MaxLen")? {
            Some(Object::Integer(len)) => u32::try_from(len).ok(),
            Some(_) => None,
            None => inherited.max_length,
        };

        let quadding = match self.entry(dict, "Q")? {
            Some(Object::Integer(q)) => u32::try_from(q).ok(),
            Some(_) => None,
            None => inherited.quadding,
        };

        // The one attribute §12.7.3.1 does *not* make inheritable, carried down
        // anyway because generators emit forms relying on it and because this
        // is its only reader — a leaf would otherwise report no options at all.
        let options = match dict.get("Opt") {
            Some(raw) => self.intern_options(raw, obj_ref)?,
            None => inherited.options,
        };

        // `/V` inherits by the same clause as `/FT` and `/Ff` (§12.7.3.1), so a
        // leaf typed `/Sig` can take its signature dictionary from an ancestor.
        let own_value = dict.get("V");
        let value = match own_value {
            Some(raw) => Some(raw.clone()),
            None => inherited.value.map(Object::Reference),
        };

        // Under §12.7.4.2 only a field kid carries `/T`; widget kids do not.
        if let Some(parent) = inherited.parent {
            let named = dict
                .get("T")
                .and_then(Object::as_string)
                .is_some_and(|name| !name.is_empty());

            if named {
                self.walked.grouping.insert(parent);
            }
        }

        if let Some(obj_ref) = obj_ref {
            if signature {
                self.walked.signatures.insert(obj_ref);
            }

            // Written whatever the attributes resolved to: the entry existing is
            // how the caller knows this field was reached at all.
            self.walked.attrs.insert(
                obj_ref,
                FieldAttrs {
                    field_type,
                    flags,
                    options,
                    max_length,
                    quadding,
                },
            );
        }

        if signature {
            if let Some(value) = value {
                // A literal null clears the field and must not mark it taken.
                if !matches!(value, Object::Null) {
                    // Mark before dedup: a widget re-reaching the value still
                    // marks itself and its ancestors as signed.
                    self.walked.signed.extend(self.path.iter().copied());
                }

                // Dedup on the reference, so a field and its widget `/Kids`
                // contribute the signature they share exactly once.
                let fresh = match value.as_reference() {
                    Some(value_ref) => self.walked.signature_value_refs.insert(value_ref),
                    None => true,
                };

                if fresh {
                    self.walked.signature_values.push((value, obj_ref));
                }
            }
        }

        let Some(kids) = self.entry(dict, "Kids")? else {
            return Ok(());
        };
        let Some(kids) = kids.as_array() else {
            return Ok(());
        };

        let inherited = Inherited {
            field_type,
            flags,
            value: own_value
                .and_then(|raw| raw.as_reference())
                .or(inherited.value),
            options,
            max_length,
            quadding,
            parent: obj_ref,
        };

        for kid in kids {
            self.node(kid, inherited, depth + 1)?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> PdfDocument {
        let path = format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        );

        PdfDocument::open(path).expect("fixture opens")
    }

    fn field_types_of(fields: &[FormField]) -> HashMap<&str, &FieldType> {
        fields
            .iter()
            .map(|field| (field.full_name.as_str(), &field.field_type))
            .collect()
    }

    fn resolved_of_fixture(doc: &PdfDocument) -> Resolved {
        let walked = walk(doc, Strictness::Tolerant).expect("a well-formed tree");
        let fields = FormExtractor::extract_fields(doc).expect("fields extract");

        resolved_of(&fields, walked)
    }

    #[test]
    fn upstream_still_types_an_inherited_signature_as_unknown() {
        let doc = fixture("form_signature_edge.pdf");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");
        let types = field_types_of(&fields);

        assert_eq!(
            types.get("inherited.leaf"),
            Some(&&FieldType::Unknown(String::new())),
            "upstream now reads an inherited /FT: {types:?}"
        );
    }

    // After the walk resolves them, nothing caller-visible separates an
    // inherited `/Ff` from an own one, so only this can notice upstream
    // starting to walk the parent chain itself.
    #[test]
    fn upstream_still_reads_field_flags_off_the_own_dictionary() {
        let doc = fixture("form_flags.pdf");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");

        let inherited = fields
            .iter()
            .find(|field| field.full_name == "group.a")
            .expect("the fixture's inheriting leaf");

        assert_eq!(
            inherited.flags, None,
            "upstream now inherits /Ff: {inherited:?}"
        );
    }

    #[test]
    fn carries_field_flags_down_to_a_kid_declaring_none() {
        let resolved = resolved_of_fixture(&fixture("form_flags.pdf"));

        assert_eq!(
            resolved.attrs("group.a").and_then(|a| a.flags),
            Some(0x8000)
        );
    }

    #[test]
    fn an_own_field_flags_overrides_an_inherited_one() {
        let resolved = resolved_of_fixture(&fixture("form_flags.pdf"));

        assert_eq!(
            resolved.attrs("group.b").and_then(|a| a.flags),
            Some(0x10000)
        );
    }

    // The whole fallback rule in one assertion: a name the walk never reached
    // resolves to nothing at all, which is the only thing `field_nif` may
    // answer from the source's own reading.
    #[test]
    fn a_field_the_walk_did_not_reach_resolves_nothing() {
        let resolved = resolved_of_fixture(&fixture("sample.pdf"));

        assert!(resolved.attrs("absent").is_none());
    }

    // The other side of it: the walk reached this field and *rejected* its
    // declaration, so the attribute is absent on a present entry and must not
    // fall back to upstream's `4294967295`.
    #[test]
    fn a_rejected_declaration_resolves_to_a_reached_field_with_no_value() {
        let resolved = resolved_of_fixture(&fixture("form_metadata.pdf"));
        let attrs = resolved.attrs("broken").expect("the walk reached it");

        assert_eq!((attrs.max_length, attrs.flags), (None, None));
    }

    #[test]
    fn upstream_still_reads_max_length_and_quadding_off_the_own_dictionary() {
        let doc = fixture("form_metadata.pdf");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");

        let inherited = fields
            .iter()
            .find(|field| field.full_name == "limits.a")
            .expect("the fixture's inheriting leaf");

        assert_eq!(
            (inherited.max_length, inherited.alignment),
            (None, None),
            "upstream now inherits /MaxLen or /Q; delete the resolution, not \
             this assertion: {inherited:?}"
        );
    }

    // Why the walk is authoritative over every field it reached: upstream casts
    // `/MaxLen` and `/Ff` with a wrapping `i as u32`, so a `-1` comes back as a
    // length cap and as every flag bit set.
    #[test]
    fn upstream_still_wraps_a_negative_max_length_and_field_flags() {
        let doc = fixture("form_metadata.pdf");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");

        let broken = fields
            .iter()
            .find(|field| field.full_name == "broken")
            .expect("the fixture's malformed field");

        assert_eq!(
            (broken.max_length, broken.flags),
            (Some(u32::MAX), Some(u32::MAX)),
            "upstream now range-checks /MaxLen or /Ff; delete the walk-wins \
             rule, not this assertion: {broken:?}"
        );
    }

    #[test]
    fn carries_max_length_and_quadding_down_to_a_kid_declaring_none() {
        let resolved = resolved_of_fixture(&fixture("form_metadata.pdf"));
        let attrs = resolved.attrs("limits.a").expect("the walk reached it");

        assert_eq!((attrs.max_length, attrs.quadding), (Some(12), Some(1)));
    }

    #[test]
    fn an_own_max_length_and_quadding_override_inherited_ones() {
        let resolved = resolved_of_fixture(&fixture("form_metadata.pdf"));
        let attrs = resolved.attrs("limits.b").expect("the walk reached it");

        assert_eq!((attrs.max_length, attrs.quadding), (Some(3), Some(2)));
    }

    // A declared zero must survive as a zero rather than reading as an absence.
    #[test]
    fn a_declared_zero_max_length_resolves_as_zero() {
        let resolved = resolved_of_fixture(&fixture("form_metadata.pdf"));

        assert_eq!(resolved.attrs("amount").and_then(|a| a.max_length), Some(0));
    }

    #[test]
    fn resolves_a_signature_typed_only_on_an_ancestor() {
        let resolved = resolved_of_fixture(&fixture("form_signature_edge.pdf"));

        assert!(resolved.is_signature("inherited.leaf"));
        // The parent carries the `/FT` and no value, and is a field of its own
        // in upstream's output, so it is refused too.
        assert!(resolved.is_signature("inherited"));
    }

    #[test]
    fn an_own_field_type_overrides_an_inherited_signature() {
        let resolved = resolved_of_fixture(&fixture("form_signature_edge.pdf"));

        assert!(!resolved.is_signature("inherited.typed"));
    }

    #[test]
    fn only_the_first_field_of_a_name_decides() {
        let resolved = resolved_of_fixture(&fixture("form_signature_edge.pdf"));

        assert!(!resolved.is_signature("shadowed"));
    }

    #[test]
    fn finds_a_signature_typed_on_the_field_itself() {
        let resolved = resolved_of_fixture(&fixture("form_signature.pdf"));

        assert!(resolved.is_signature("signature"));
        assert!(!resolved.is_signature("signer_name"));
    }

    #[test]
    fn a_form_with_no_signature_refuses_nothing() {
        for name in ["form.pdf", "form_hierarchical.pdf"] {
            let doc = fixture(name);
            let resolved = resolved_of_fixture(&doc);
            let fields = FormExtractor::extract_fields(&doc).expect("fields extract");

            assert!(!fields.is_empty(), "{name} has fields");

            for field in &fields {
                assert!(
                    !resolved.is_signature(&field.full_name),
                    "{name}: {field:?}"
                );
            }
        }
    }

    // The four names upstream's private `parse_field_type` recognizes, which
    // `field_type_of` transcribes.
    #[test]
    fn upstream_still_maps_the_field_type_names() {
        let doc = fixture("form_metadata.pdf");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");
        let types = field_types_of(&fields);

        for (name, declared) in [
            ("full_name", "Tx"),
            ("subscribe", "Btn"),
            ("country", "Ch"),
            ("legacy", "Barcode"),
        ] {
            assert_eq!(
                types.get(name),
                Some(&&field_type_of(declared)),
                "upstream no longer types /FT /{declared} as this walk does: {types:?}"
            );
        }

        let doc = fixture("form_signature.pdf");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");

        assert_eq!(
            field_types_of(&fields).get("signature"),
            Some(&&field_type_of("Sig"))
        );
    }

    #[test]
    fn carries_the_field_type_down_to_a_kid_declaring_none() {
        let resolved = resolved_of_fixture(&fixture("form_metadata.pdf"));
        let attrs = resolved.attrs("typed.text").expect("the walk reached it");

        assert_eq!(attrs.field_type, Some(FieldType::Text));
    }

    #[test]
    fn an_own_field_type_overrides_an_inherited_one() {
        let resolved = resolved_of_fixture(&fixture("form_signature_edge.pdf"));
        let attrs = resolved
            .attrs("inherited.typed")
            .expect("the walk reached it");

        assert_eq!(attrs.field_type, Some(FieldType::Text));
    }

    #[test]
    fn refuses_a_cyclic_kids_chain() {
        assert_eq!(
            walk(&fixture("form_cyclic.pdf"), Strictness::Tolerant),
            Err(Refused::Cycle)
        );
    }

    #[test]
    fn a_document_with_no_form_walks_to_nothing() {
        assert_eq!(
            walk(&fixture("sample.pdf"), Strictness::Tolerant),
            Ok(Walked::default())
        );
    }

    mod limits {
        use super::*;

        fn chain(levels: usize) -> Object {
            (1..levels).fold(leaf(), |kid, _| {
                Object::Dictionary(HashMap::from([(
                    String::from("Kids"),
                    Object::Array(vec![kid]),
                )]))
            })
        }

        fn leaf() -> Object {
            Object::Dictionary(HashMap::new())
        }

        fn bush(levels: usize, width: usize) -> Object {
            (0..levels).fold(leaf(), |kid, _| {
                Object::Dictionary(HashMap::from([(
                    String::from("Kids"),
                    Object::Array(vec![kid; width]),
                )]))
            })
        }

        fn walk_detached(root: &Object, budget: usize) -> Result<(), Refused> {
            // A `PdfDocument` is needed only to resolve references, and these
            // trees hold none.
            let doc = fixture("sample.pdf");

            let mut walker = Walker {
                doc: &doc,
                path: Vec::new(),
                walked: Walked::default(),
                budget,
                strictness: Strictness::Tolerant,
                option_ids: HashMap::new(),
                field_type_ids: HashMap::new(),
            };

            walker.node(root, Inherited::default(), 0)
        }

        #[test]
        fn accepts_a_tree_exactly_at_the_depth_cap() {
            // The cap is inclusive.
            assert_eq!(
                walk_detached(&chain(MAX_FIELD_DEPTH), MAX_FIELD_NODES),
                Ok(())
            );
        }

        #[test]
        fn refuses_a_tree_one_level_past_the_depth_cap() {
            assert_eq!(
                walk_detached(&chain(MAX_FIELD_DEPTH + 1), MAX_FIELD_NODES),
                Err(Refused::TooDeep)
            );
        }

        #[test]
        fn refuses_a_tree_that_exhausts_the_node_budget() {
            // 2^12 paths against a budget of 100, well inside the depth cap —
            // the case the depth cap alone would let through.
            assert_eq!(walk_detached(&bush(12, 2), 100), Err(Refused::TooLarge));
        }

        #[test]
        fn counts_one_node_against_the_budget_per_path_that_reaches_it() {
            // A three-level binary bush is 1 + 2 + 4 + 8 = 15 visits.
            assert_eq!(walk_detached(&bush(3, 2), 15), Ok(()));
            assert_eq!(walk_detached(&bush(3, 2), 14), Err(Refused::TooLarge));
        }
    }
}
