// Validates an AcroForm field tree and resolves inherited signature types
// before extraction.

use std::collections::HashSet;

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
// document and editor form APIs.
#[derive(Debug, Default)]
pub struct SignatureNames(HashSet<String>);

impl SignatureNames {
    pub fn contains(&self, name: &str) -> bool {
        self.0.contains(name)
    }
}

// Return fields and signature names together to avoid repeating extraction.
pub fn extract_fields(doc: &PdfDocument) -> NifResult<(Vec<FormField>, SignatureNames)> {
    let signatures = walk(doc).map_err(refused_err)?;

    let fields = FormExtractor::extract_fields(doc).map_err(to_nif_err)?;
    let names = signature_names_of(&fields, &signatures);

    Ok((fields, names))
}

pub fn signature_names(doc: &PdfDocument) -> NifResult<SignatureNames> {
    extract_fields(doc).map(|(_fields, names)| names)
}

// Only the first duplicate name matters because the editor writes the first match.
fn signature_names_of(fields: &[FormField], signatures: &HashSet<ObjectRef>) -> SignatureNames {
    let mut names = HashSet::new();
    let mut seen = HashSet::new();

    for field in fields {
        if !seen.insert(&field.full_name) {
            continue;
        }

        let is_signature = field.field_type == FieldType::Signature
            || field
                .object_ref
                .is_some_and(|obj_ref| signatures.contains(&obj_ref));

        if is_signature {
            names.insert(field.full_name.clone());
        }
    }

    SignatureNames(names)
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

// Collects every field object whose *effective* `/FT` is `/Sig`, validating the
// tree on the way.
fn walk(doc: &PdfDocument) -> Result<HashSet<ObjectRef>, Refused> {
    let Some(fields) = root_fields(doc) else {
        return Ok(HashSet::new());
    };

    let mut walker = Walker {
        doc,
        path: Vec::new(),
        signatures: HashSet::new(),
        budget: MAX_FIELD_NODES,
    };

    for field in &fields {
        walker.node(field, false, 0)?;
    }

    Ok(walker.signatures)
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

struct Walker<'a> {
    doc: &'a PdfDocument,
    // The references on the path from a root field to the current node — an
    // ancestor stack, not a visited set. A node reached twice by *different*
    // paths is a DAG, which upstream expands rather than looping on; only a
    // back edge is a cycle, and `MAX_FIELD_NODES` is what bounds the former.
    path: Vec<ObjectRef>,
    signatures: HashSet<ObjectRef>,
    budget: usize,
}

impl Walker<'_> {
    // `inherited_signature` is its ancestors' verdict, which a node with no
    // `/FT` of its own adopts.
    fn node(
        &mut self,
        obj: &Object,
        inherited_signature: bool,
        depth: usize,
    ) -> Result<(), Refused> {
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

        let result = self.kids(obj, obj_ref, inherited_signature, depth);

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
        inherited_signature: bool,
        depth: usize,
    ) -> Result<(), Refused> {
        let Some(field) = resolve(self.doc, obj) else {
            return Ok(());
        };
        let Some(dict) = field.as_dict() else {
            return Ok(());
        };

        // An own `/FT` settles it in both directions: a `/Tx` leaf under a `/Sig`
        // parent is a text field, not an inherited signature.
        let signature = match dict.get("FT").and_then(|ft| resolve(self.doc, ft)) {
            Some(field_type) => field_type.as_name() == Some(SIGNATURE_FIELD_TYPE),
            None => inherited_signature,
        };

        if signature {
            if let Some(obj_ref) = obj_ref {
                self.signatures.insert(obj_ref);
            }
        }

        let Some(kids) = dict.get("Kids").and_then(|kids| resolve(self.doc, kids)) else {
            return Ok(());
        };
        let Some(kids) = kids.as_array() else {
            return Ok(());
        };

        for kid in kids {
            self.node(kid, signature, depth + 1)?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

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

    fn names_of(doc: &PdfDocument) -> SignatureNames {
        let signatures = walk(doc).expect("a well-formed tree");
        let fields = FormExtractor::extract_fields(doc).expect("fields extract");

        signature_names_of(&fields, &signatures)
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

    #[test]
    fn resolves_a_signature_typed_only_on_an_ancestor() {
        let names = names_of(&fixture("form_signature_edge.pdf"));

        assert!(names.contains("inherited.leaf"));
        // The parent carries the `/FT` and no value, and is a field of its own
        // in upstream's output, so it is refused too.
        assert!(names.contains("inherited"));
    }

    #[test]
    fn an_own_field_type_overrides_an_inherited_signature() {
        let names = names_of(&fixture("form_signature_edge.pdf"));

        assert!(!names.contains("inherited.typed"));
    }

    #[test]
    fn only_the_first_field_of_a_name_decides() {
        let names = names_of(&fixture("form_signature_edge.pdf"));

        assert!(!names.contains("shadowed"));
    }

    #[test]
    fn finds_a_signature_typed_on_the_field_itself() {
        let names = names_of(&fixture("form_signature.pdf"));

        assert!(names.contains("signature"));
        assert!(!names.contains("signer_name"));
    }

    #[test]
    fn a_form_with_no_signature_refuses_nothing() {
        for name in ["form.pdf", "form_hierarchical.pdf"] {
            let doc = fixture(name);
            let names = names_of(&doc);
            let fields = FormExtractor::extract_fields(&doc).expect("fields extract");

            assert!(!fields.is_empty(), "{name} has fields");

            for field in &fields {
                assert!(!names.contains(&field.full_name), "{name}: {field:?}");
            }
        }
    }

    #[test]
    fn refuses_a_cyclic_kids_chain() {
        assert_eq!(walk(&fixture("form_cyclic.pdf")), Err(Refused::Cycle));
    }

    #[test]
    fn a_document_with_no_form_walks_to_nothing() {
        assert_eq!(walk(&fixture("sample.pdf")), Ok(HashSet::new()));
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
                signatures: HashSet::new(),
                budget,
            };

            walker.node(root, false, 0)
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
