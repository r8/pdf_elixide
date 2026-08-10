// Validates an AcroForm field tree and resolves the inheritable attributes
// upstream reads off a field's own dictionary — `/FT` and `/Ff` — before
// extraction.

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
};

// Bound the native recursion before handing the tree to the uncapped extractor.
const MAX_FIELD_DEPTH: usize = 256;

// Depth alone does not bound a DAG whose shared subtrees are reached by many paths.
const MAX_FIELD_NODES: usize = 100_000;

const SIGNATURE_FIELD_TYPE: &str = "Sig";

// Keep the walk BEAM-independent; build reason atoms only at its boundary.
#[derive(Debug, PartialEq)]
enum Refused {
    Cycle,
    TooDeep,
    TooLarge,
}

// Names, rather than object references, are the common key available to both
// document and editor form APIs — `get_form_fields` builds every wrapper with
// `object_ref: None`.
#[derive(Debug, Default)]
pub struct Resolved {
    signatures: HashSet<String>,
    flags: HashMap<String, u32>,
}

impl Resolved {
    pub fn is_signature(&self, name: &str) -> bool {
        self.signatures.contains(name)
    }

    // The caller's own reading is the fallback, so a field the walk could not
    // reach still reports the bits upstream found on it.
    pub fn flags(&self, name: &str, own: Option<u32>) -> Option<u32> {
        self.flags.get(name).copied().or(own)
    }
}

// Return fields and their resolved attributes together to avoid repeating
// extraction.
pub fn extract_fields(doc: &PdfDocument) -> NifResult<(Vec<FormField>, Resolved)> {
    let walked = walk(doc).map_err(refused_err)?;

    let fields = FormExtractor::extract_fields(doc).map_err(to_nif_err)?;
    let resolved = resolved_of(&fields, &walked);

    Ok((fields, resolved))
}

pub fn resolved(doc: &PdfDocument) -> NifResult<Resolved> {
    extract_fields(doc).map(|(_fields, resolved)| resolved)
}

// Only the first duplicate name matters because the editor writes the first match.
fn resolved_of(fields: &[FormField], walked: &Walked) -> Resolved {
    let mut resolved = Resolved::default();
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

        if let Some(flags) = field
            .object_ref
            .and_then(|obj_ref| walked.flags.get(&obj_ref))
        {
            resolved.flags.insert(field.full_name.clone(), *flags);
        }
    }

    resolved
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
    }
}

// What one walk of the field tree yields, keyed by object reference.
#[derive(Debug, Default, PartialEq)]
struct Walked {
    // Every field object whose *effective* `/FT` is `/Sig`.
    signatures: HashSet<ObjectRef>,
    // Every field object's effective `/Ff`, absent where neither it nor any
    // ancestor declares one.
    flags: HashMap<ObjectRef, u32>,
}

// Resolves the inheritable attributes, validating the tree on the way.
fn walk(doc: &PdfDocument) -> Result<Walked, Refused> {
    let Some(fields) = root_fields(doc) else {
        return Ok(Walked::default());
    };

    let mut walker = Walker {
        doc,
        path: Vec::new(),
        walked: Walked::default(),
        budget: MAX_FIELD_NODES,
    };

    for field in &fields {
        walker.node(field, Inherited::default(), 0)?;
    }

    Ok(walker.walked)
}

// `/Root /AcroForm /Fields`, or `None` for a document with no form — which
// includes every way of failing to read one, per the tolerance above.
fn root_fields(doc: &PdfDocument) -> Option<Vec<Object>> {
    let catalog = doc.catalog().ok()?;
    let acroform = resolve(doc, catalog.as_dict()?.get("AcroForm")?)?;
    let fields = resolve(doc, acroform.as_dict()?.get("Fields")?)?;

    fields.as_array().cloned()
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
    signature: bool,
    flags: Option<u32>,
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
}

impl Walker<'_> {
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
        let Some(field) = resolve(self.doc, obj) else {
            return Ok(());
        };
        let Some(dict) = field.as_dict() else {
            return Ok(());
        };

        // An own declaration settles it in both directions: a `/Tx` leaf under a
        // `/Sig` parent is a text field, not an inherited signature.
        let signature = match dict.get("FT").and_then(|ft| resolve(self.doc, ft)) {
            Some(field_type) => field_type.as_name() == Some(SIGNATURE_FIELD_TYPE),
            None => inherited.signature,
        };

        let flags = match dict.get("Ff").and_then(|ff| resolve(self.doc, ff)) {
            Some(Object::Integer(bits)) => u32::try_from(bits).ok(),
            // A non-integer `/Ff` is malformed; upstream drops it too, and this
            // walk does not decide whether a document is readable.
            Some(_) => None,
            None => inherited.flags,
        };

        if let Some(obj_ref) = obj_ref {
            if signature {
                self.walked.signatures.insert(obj_ref);
            }

            if let Some(flags) = flags {
                self.walked.flags.insert(obj_ref, flags);
            }
        }

        let Some(kids) = dict.get("Kids").and_then(|kids| resolve(self.doc, kids)) else {
            return Ok(());
        };
        let Some(kids) = kids.as_array() else {
            return Ok(());
        };

        let inherited = Inherited { signature, flags };

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
        let walked = walk(doc).expect("a well-formed tree");
        let fields = FormExtractor::extract_fields(doc).expect("fields extract");

        resolved_of(&fields, &walked)
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

        assert_eq!(resolved.flags("group.a", None), Some(0x8000));
    }

    #[test]
    fn an_own_field_flags_overrides_an_inherited_one() {
        let resolved = resolved_of_fixture(&fixture("form_flags.pdf"));

        assert_eq!(resolved.flags("group.b", None), Some(0x10000));
    }

    #[test]
    fn a_field_the_walk_did_not_reach_keeps_its_own_flags() {
        let resolved = resolved_of_fixture(&fixture("sample.pdf"));

        assert_eq!(resolved.flags("absent", Some(0x2)), Some(0x2));
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

    #[test]
    fn refuses_a_cyclic_kids_chain() {
        assert_eq!(walk(&fixture("form_cyclic.pdf")), Err(Refused::Cycle));
    }

    #[test]
    fn a_document_with_no_form_walks_to_nothing() {
        assert_eq!(walk(&fixture("sample.pdf")), Ok(Walked::default()));
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
            };

            walker.node(root, Inherited::default(), 0)
        }

        #[test]
        fn accepts_a_tree_exactly_at_the_depth_cap() {
            // Pins the off-by-one: 256 means 256 levels are usable, not 255.
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
