use std::{
    collections::{HashMap, HashSet},
    panic, thread,
};

use pdf_oxide::{
    object::{Object, ObjectRef},
    Error as PdfError, PdfDocument,
};

use crate::{document::read_crop_box, open_editor::PageError, warnings};

// Merged pages lose everything they inherited, their `/Parent` being stripped,
// so the pages' effective values are read here and re-applied after the merge.
pub(crate) struct Incoming {
    pub(crate) bytes: Vec<u8>,
    pub(crate) pages: Vec<PageAttrs>,
    // The first page carrying a structure key, which `declares_structure` weighs
    // against the destination.
    pub(crate) tagged_page: Option<usize>,
}

#[derive(Debug, PartialEq)]
pub(crate) struct PageAttrs {
    pub(crate) rotation: i32,
    pub(crate) media_box: [f32; 4],
    pub(crate) crop_box: Option<[f32; 4]>,
    // A page without its own `/Resources` inherits whatever the destination's
    // page tree declares once merged.
    pub(crate) owns_resources: bool,
}

// Carried as data so the atom is built at the NIF boundary.
#[derive(Debug)]
pub(crate) enum MergeError {
    Encrypted,
    // A page entry that reaches the page tree, which the merge would copy
    // along with the whole tree; or annotations, refused whatever they name.
    NamesAnotherPage { page: usize, entry: String },
    // Nothing can write a page's `/Resources`, so an inherited one is lost.
    InheritsResources { page: usize },
    // The same missing entry, from the other side: the page would take the
    // destination's resources.
    TakesDestinationResources { page: usize },
    // Layer settings live in the catalog's `/OCProperties`, which a merge does
    // not carry, so a hidden layer would show.
    UsesOptionalContent { page: usize },
    // A form action works on the whole document's fields, or names a field or
    // attachment, so once merged it would act on the destination's.
    ActsOnForm { page: usize, entry: String },
    // A `/StructParents` or `/StructParent` key indexes the document's
    // `/ParentTree`; merged into a tagged document, it would index the
    // destination's instead.
    CollidesWithStructure { page: usize },
    // Upstream's import recurses without a limit, so a page nested past this
    // would overflow even the import thread's stack and abort the process.
    TooDeep { page: usize },
    NoPages,
    Miscount { expected: usize, got: usize },
    Page(PageError),
    Upstream(PdfError),
}

impl From<PdfError> for MergeError {
    fn from(e: PdfError) -> Self {
        match e {
            PdfError::EncryptedPdf => MergeError::Encrypted,
            e => MergeError::Upstream(e),
        }
    }
}

impl From<PageError> for MergeError {
    fn from(e: PageError) -> Self {
        MergeError::Page(e)
    }
}

// Bound the walks the way `form_tree.rs` bounds the field tree; their visited
// sets already make them linear, so these only cap a hostile file's size.
const MAX_PAGE_TREE_NODES: usize = 1_000_000;
const MAX_PAGE_GRAPH_NODES: usize = 10_000_000;

// Frames of upstream's import, measured as `import_depth` counts them; about a
// quarter of what `IMPORT_STACK_SIZE` holds.
const MAX_IMPORT_DEPTH: usize = 4096;

// A dirty scheduler's stack holds a few hundred of those frames.
const IMPORT_STACK_SIZE: usize = 16 * 1024 * 1024;

// Upstream's merge work, on the stack `MAX_IMPORT_DEPTH` was set against. The
// warning sink is thread-local, so it is drained there; a panic is resumed on
// the calling thread, where the editor's `Closable` contains it.
pub(crate) fn on_import_stack<T: Send>(
    work: impl FnOnce() -> Result<T, MergeError> + Send,
) -> Result<T, MergeError> {
    let joined = thread::scope(|scope| {
        thread::Builder::new()
            .stack_size(IMPORT_STACK_SIZE)
            .spawn_scoped(scope, || {
                let result = panic::catch_unwind(panic::AssertUnwindSafe(work));
                warnings::collect_global();

                result
            })
            .map(|handle| handle.join().and_then(|result| result))
    });

    match joined {
        Ok(Ok(result)) => result,
        Ok(Err(payload)) => panic::resume_unwind(payload),
        Err(e) => Err(MergeError::Upstream(PdfError::from(e))),
    }
}

struct PageTree {
    leaves: Vec<ObjectRef>,
    owns_resources: Vec<bool>,
    nodes: HashSet<ObjectRef>,
}

// Runs before the editor's lock is taken: it reads nothing of the editor.
pub(crate) fn prepare(bytes: Vec<u8>) -> Result<Incoming, MergeError> {
    let mut doc = PdfDocument::from_bytes(bytes)?;
    // Authenticated is not enough: a document with only an owner password opens,
    // but the merge copies its stream data without decrypting it.
    if doc.is_encrypted() {
        return Err(MergeError::Encrypted);
    }

    let count = doc.page_count()?;
    if count == 0 {
        return Ok(Incoming {
            bytes: Vec::new(),
            pages: Vec::new(),
            tagged_page: None,
        });
    }

    let tree = walk_page_tree(&doc, count)?;

    // Shared across pages, so a resource many pages use is walked once. An object
    // enters on first visit, before its subgraph is known clean; that is sound
    // only because the first hit refuses the whole document.
    let mut clean = HashSet::new();
    let mut depths = HashMap::new();
    let mut load = |reference| -> Result<Object, MergeError> { Ok(doc.load_object(reference)?) };
    let mut pages = Vec::with_capacity(count);
    let mut tagged_page = None;
    for (page, &leaf) in tree.leaves.iter().enumerate() {
        let mut keyed = false;
        match refused_entry(&doc, &tree, leaf, &mut clean, &mut keyed)? {
            Some((entry, Reach::Page)) => {
                return Err(MergeError::NamesAnotherPage { page, entry });
            }
            Some((_, Reach::OptionalContent)) => {
                return Err(MergeError::UsesOptionalContent { page });
            }
            Some((entry, Reach::Form)) => {
                return Err(MergeError::ActsOnForm { page, entry });
            }
            None => {}
        }

        // Upstream imports the page without its `/Parent`.
        let mut stripped = doc.load_object(leaf)?;
        if let Object::Dictionary(dict) = &mut stripped {
            dict.remove("Parent");
            keyed |= has_structure_key(&doc, dict, "StructParents");
        }
        if keyed {
            tagged_page.get_or_insert(page);
        }
        if import_depth(&stripped, &mut load, &mut depths)? > MAX_IMPORT_DEPTH {
            return Err(MergeError::TooDeep { page });
        }

        let (llx, lly, urx, ury) = doc.get_page_media_box(page)?;
        pages.push(PageAttrs {
            rotation: doc.get_page_rotation(page)?,
            media_box: [llx, lly, urx, ury],
            crop_box: read_crop_box(&doc, page)?,
            owns_resources: tree.owns_resources[page],
        });
    }

    Ok(Incoming {
        // Upstream keeps its own copy of the input; taking it saves a second one.
        bytes: std::mem::take(&mut doc.source_bytes),
        pages,
        tagged_page,
    })
}

// `get_page` merges inherited keys into the page it returns, so the leaves are
// read raw here. An empty inherited dictionary loses nothing and is allowed.
fn walk_page_tree(doc: &PdfDocument, count: usize) -> Result<PageTree, MergeError> {
    // The walk refuses more nodes than this anyway; refusing first keeps the
    // declared count from sizing an allocation.
    if count > MAX_PAGE_TREE_NODES {
        return Err(invalid("page tree exceeds the supported size"));
    }

    let root = doc
        .catalog()?
        .as_dict()
        .and_then(|catalog| catalog.get("Pages"))
        .and_then(Object::as_reference)
        .ok_or_else(|| PdfError::InvalidPdf("Catalog /Pages is not a reference".into()))?;

    let mut stack: Vec<(ObjectRef, bool)> = vec![(root, false)];
    let mut visited = HashSet::new();
    let mut leaves = Vec::with_capacity(count);
    let mut owns_resources = Vec::with_capacity(count);

    while let Some((node_ref, inherits)) = stack.pop() {
        if visited.len() >= MAX_PAGE_TREE_NODES {
            return Err(invalid("page tree exceeds the supported size"));
        }
        if !visited.insert(node_ref) {
            return Err(invalid("page tree lists a node twice"));
        }

        let node = doc.load_object(node_ref)?;
        let dict = node
            .as_dict()
            .ok_or_else(|| invalid("page tree node is not a dictionary"))?;
        // `/Resources null`, or a reference to a missing object, declares nothing
        // (ISO 32000-1 §7.3.9), so the page inherits through it.
        let resources = dict
            .get("Resources")
            .filter(|own| !matches!(doc.resolve_object(own), Ok(Object::Null)));
        let inherits = match resources {
            Some(own) => nonempty(doc, own),
            None if dict.contains_key("Kids") => inherits,
            None if inherits => return Err(MergeError::InheritsResources { page: leaves.len() }),
            None => false,
        };

        match dict.get("Kids") {
            Some(kids) => {
                let kids = doc.resolve_object(kids)?;
                let kids = kids
                    .as_array()
                    .ok_or_else(|| invalid("/Kids is not an array"))?;

                for kid in kids.iter().rev().filter_map(Object::as_reference) {
                    stack.push((kid, inherits));
                }
            }
            None => {
                leaves.push(node_ref);
                owns_resources.push(resources.is_some());
            }
        }
    }

    if leaves.len() != count {
        return Err(invalid(&format!(
            "page tree holds {} pages where the document declares {count}",
            leaves.len()
        )));
    }

    Ok(PageTree {
        leaves,
        owns_resources,
        nodes: visited,
    })
}

fn invalid(message: &str) -> MergeError {
    MergeError::Upstream(PdfError::InvalidPdf(format!(
        "The document to merge is unreadable: {message}"
    )))
}

// Whether the catalog has a structure tree whose `/ParentTree` a merged page's
// structure key would index. Unreadable counts as declared.
pub(crate) fn declares_structure(doc: &PdfDocument) -> bool {
    match doc.catalog() {
        Ok(catalog) => catalog
            .as_dict()
            .is_some_and(|dict| has_structure_key(doc, dict, "StructTreeRoot")),
        Err(_) => true,
    }
}

// Both structure-parent spellings index the destination's `/ParentTree`.
fn nested_structure_key(doc: &PdfDocument, dict: &HashMap<String, Object>) -> bool {
    has_structure_key(doc, dict, "StructParent") || has_structure_key(doc, dict, "StructParents")
}

fn has_structure_key(doc: &PdfDocument, dict: &HashMap<String, Object>, key: &str) -> bool {
    dict.get(key)
        .is_some_and(|value| !matches!(doc.resolve_object(value), Ok(Object::Null)))
}

// Whether the root `/Pages` node declares resources a page lacking its own would
// inherit. Unreadable counts as declared.
pub(crate) fn root_declares_resources(doc: &PdfDocument) -> bool {
    let Ok(catalog) = doc.catalog() else {
        return true;
    };
    let Some(pages) = catalog.as_dict().and_then(|dict| dict.get("Pages")) else {
        return true;
    };

    match doc.resolve_object(pages) {
        Ok(pages) => pages
            .as_dict()
            .and_then(|dict| dict.get("Resources"))
            .is_some_and(|resources| nonempty(doc, resources)),
        Err(_) => true,
    }
}

// Unreadable is not absent.
fn nonempty(doc: &PdfDocument, value: &Object) -> bool {
    doc.resolve_object(value)
        .map(|resolved| match resolved {
            Object::Dictionary(dict) => !dict.is_empty(),
            Object::Array(items) => !items.is_empty(),
            Object::Null => false,
            _ => true,
        })
        .unwrap_or(true)
}

// What a page entry's graph reached that a merge cannot carry.
#[derive(Debug, PartialEq)]
enum Reach {
    Page,
    OptionalContent,
    Form,
}

// Walk every page-entry graph: a key allowlist misses indirect page references,
// named destinations and optional-content dependencies.
fn refused_entry(
    doc: &PdfDocument,
    tree: &PageTree,
    leaf: ObjectRef,
    clean: &mut HashSet<ObjectRef>,
    keyed: &mut bool,
) -> Result<Option<(String, Reach)>, MergeError> {
    let page = doc.load_object(leaf)?;
    let dict = page
        .as_dict()
        .ok_or_else(|| invalid("page is not a dictionary"))?;

    if dict.get("Annots").is_some_and(|value| nonempty(doc, value)) {
        return Ok(Some(("Annots".to_string(), Reach::Page)));
    }

    let mut keys: Vec<&String> = dict.keys().filter(|key| *key != "Parent").collect();
    keys.sort();

    for key in keys {
        if let Some(reach) = reaches(doc, &tree.nodes, &dict[key], clean, keyed)? {
            return Ok(Some((key.clone(), reach)));
        }
    }

    Ok(None)
}

// Stream data is copied verbatim, so only a stream's dictionary can refer on.
// Sets `keyed` on meeting a structure key, which refuses only by destination.
fn reaches(
    doc: &PdfDocument,
    nodes: &HashSet<ObjectRef>,
    value: &Object,
    clean: &mut HashSet<ObjectRef>,
    keyed: &mut bool,
) -> Result<Option<Reach>, MergeError> {
    let mut stack = vec![value.clone()];

    while let Some(object) = stack.pop() {
        match object {
            Object::Reference(reference) => {
                if nodes.contains(&reference) {
                    return Ok(Some(Reach::Page));
                }
                if clean.len() >= MAX_PAGE_GRAPH_NODES {
                    return Err(invalid("object graph exceeds the supported size"));
                }
                if clean.insert(reference) {
                    stack.push(doc.load_object(reference)?);
                }
            }
            Object::Dictionary(dict) => {
                if names_a_destination(doc, &dict) {
                    return Ok(Some(Reach::Page));
                }
                if acts_on_form(doc, &dict) {
                    return Ok(Some(Reach::Form));
                }
                if is_optional_content(doc, &dict) {
                    return Ok(Some(Reach::OptionalContent));
                }
                *keyed |= nested_structure_key(doc, &dict);
                stack.extend(dict.into_values());
            }
            Object::Array(items) => stack.extend(items),
            Object::Stream { dict, .. } => {
                *keyed |= nested_structure_key(doc, &dict);
                stack.extend(dict.into_values());
            }
            _ => {}
        }
    }

    Ok(None)
}

// Resolved for the reason `names_a_destination` gives.
fn is_optional_content(doc: &PdfDocument, dict: &HashMap<String, Object>) -> bool {
    dict.get("Type")
        .and_then(|value| doc.resolve_object(value).ok())
        .is_some_and(|value| matches!(value.as_name(), Some("OCG" | "OCMD")))
}

// Refuse actions that would retarget fields or attachments in the destination;
// an external `/F` keeps a `/GoToE` action scoped to that file.
fn acts_on_form(doc: &PdfDocument, dict: &HashMap<String, Object>) -> bool {
    if dict.contains_key("JS") {
        return true;
    }
    let Some(action) = dict.get("S") else {
        return false;
    };
    let Ok(action) = doc.resolve_object(action) else {
        return true;
    };
    let names_a_field = |value: &Object| match doc.resolve_object(value) {
        Ok(Object::String(_)) => true,
        Ok(Object::Array(items)) => items.iter().any(|item| {
            doc.resolve_object(item)
                .map_or(true, |item| matches!(item, Object::String(_)))
        }),
        Ok(_) => false,
        Err(_) => true,
    };
    // A null `/F` is an absent one (ISO 32000-1 §7.3.9).
    let names_another_file = dict.get("F").is_some_and(|file| {
        doc.resolve_object(file)
            .is_ok_and(|file| !matches!(file, Object::Null))
    });

    match action.as_name() {
        Some("ResetForm" | "SubmitForm" | "ImportData") => true,
        Some("Hide") => dict.get("T").is_some_and(names_a_field),
        Some("GoToE") => dict.contains_key("T") && !names_another_file,
        _ => false,
    }
}

// Resolve values here because the graph walk loses the key attached to an
// indirect value. Treat unreadable values as present.
fn names_a_destination(doc: &PdfDocument, dict: &HashMap<String, Object>) -> bool {
    let is = |key: &str, test: fn(&Object) -> bool| match dict.get(key) {
        None => false,
        Some(value) => doc.resolve_object(value).map_or(true, |value| test(&value)),
    };
    let named = |value: &Object| matches!(value, Object::Name(_) | Object::String(_));
    let go_to = |value: &Object| value.as_name() == Some("GoTo");
    let thread = |value: &Object| value.as_name() == Some("Thread");
    let titled_or_counted = |value: &Object| {
        matches!(
            value,
            Object::Name(_) | Object::String(_) | Object::Integer(_)
        )
    };

    (is("S", go_to) && is("D", named))
        || is("Dest", named)
        || (is("S", thread) && is("D", titled_or_counted))
}

// Upstream's import copies a value in one frame per array, dictionary, stream
// dictionary and reference it nests through, then the referenced object's own.
struct Scan {
    nesting: usize,
    refs: Vec<ObjectRef>,
}

fn scan(value: &Object) -> Scan {
    let mut nesting = 0;
    let mut refs = Vec::new();
    let mut stack = vec![(value, 1)];

    while let Some((object, depth)) = stack.pop() {
        nesting = nesting.max(depth);
        match object {
            Object::Reference(reference) => refs.push(*reference),
            Object::Dictionary(dict) | Object::Stream { dict, .. } => {
                stack.extend(dict.values().map(|value| (value, depth + 1)));
            }
            Object::Array(items) => stack.extend(items.iter().map(|item| (item, depth + 1))),
            _ => {}
        }
    }

    Scan { nesting, refs }
}

type Load<'a> = dyn FnMut(ObjectRef) -> Result<Object, MergeError> + 'a;

// An upper bound on the frames upstream's import nests to copy `root`. Its
// recursion stops only at an object already on its path, so a reference cycle
// may be walked through every object in it: each strongly connected component
// counts the nesting of all its members. `finished` holds each object's bound
// across pages, since it does not depend on which page reached the object.
fn import_depth(
    root: &Object,
    load: &mut Load,
    finished: &mut HashMap<ObjectRef, usize>,
) -> Result<usize, MergeError> {
    let Scan { nesting, refs } = scan(root);
    let mut below = 0;
    for reference in refs {
        let depth = match finished.get(&reference) {
            Some(&depth) => depth,
            None => DepthWalk::new(finished).run(reference, load)?,
        };
        below = below.max(depth);
    }

    Ok(nesting.saturating_add(below))
}

struct Visit {
    node: ObjectRef,
    low: usize,
    nesting: usize,
    below: usize,
    refs: Vec<ObjectRef>,
    next: usize,
}

// Tarjan's algorithm, iterative so a deep graph cannot overflow this stack
// either. A visit's position in `visits` is its Tarjan index, and a visited
// object not yet in `finished` is on the component stack.
struct DepthWalk<'a> {
    finished: &'a mut HashMap<ObjectRef, usize>,
    visits: Vec<Visit>,
    index_of: HashMap<ObjectRef, usize>,
    component: Vec<usize>,
    frames: Vec<usize>,
}

impl<'a> DepthWalk<'a> {
    fn new(finished: &'a mut HashMap<ObjectRef, usize>) -> Self {
        Self {
            finished,
            visits: Vec::new(),
            index_of: HashMap::new(),
            component: Vec::new(),
            frames: Vec::new(),
        }
    }

    fn run(mut self, root: ObjectRef, load: &mut Load) -> Result<usize, MergeError> {
        self.enter(root, load)?;

        while let Some(&current) = self.frames.last() {
            let visit = &mut self.visits[current];
            if let Some(&child) = visit.refs.get(visit.next) {
                visit.next += 1;
                if let Some(&depth) = self.finished.get(&child) {
                    visit.below = visit.below.max(depth);
                } else if let Some(&seen) = self.index_of.get(&child) {
                    visit.low = visit.low.min(seen);
                } else {
                    self.enter(child, load)?;
                }
                continue;
            }

            self.frames.pop();
            self.leave(current);
        }

        Ok(self.finished.get(&root).copied().unwrap_or_default())
    }

    fn enter(&mut self, node: ObjectRef, load: &mut Load) -> Result<(), MergeError> {
        if self.finished.len() + self.visits.len() >= MAX_PAGE_GRAPH_NODES {
            return Err(invalid("object graph exceeds the supported size"));
        }

        let Scan { nesting, refs } = scan(&load(node)?);
        let index = self.visits.len();
        self.visits.push(Visit {
            node,
            low: index,
            nesting,
            below: 0,
            refs,
            next: 0,
        });
        self.index_of.insert(node, index);
        self.component.push(index);
        self.frames.push(index);

        Ok(())
    }

    fn leave(&mut self, current: usize) {
        if self.visits[current].low == current {
            let at = self.component.partition_point(|&index| index < current);
            let members = self.component.split_off(at);
            let nesting = members.iter().fold(0usize, |sum, &index| {
                sum.saturating_add(self.visits[index].nesting)
            });
            let below = members
                .iter()
                .map(|&index| self.visits[index].below)
                .max()
                .unwrap_or_default();
            let depth = nesting.saturating_add(below);

            for index in members {
                self.finished.insert(self.visits[index].node, depth);
                self.visits[index].refs = Vec::new();
            }
        }

        if let Some(&parent) = self.frames.last() {
            let (low, done) = {
                let visit = &self.visits[current];
                (visit.low, self.finished.get(&visit.node).copied())
            };
            let parent = &mut self.visits[parent];
            match done {
                Some(depth) => parent.below = parent.below.max(depth),
                None => parent.low = parent.low.min(low),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        ))
        .expect("fixture reads")
    }

    fn dict(entries: &[(&str, Object)]) -> Object {
        Object::Dictionary(
            entries
                .iter()
                .map(|(key, value)| (key.to_string(), value.clone()))
                .collect(),
        )
    }

    fn to(id: u32) -> Object {
        Object::Reference(ObjectRef::new(id, 0))
    }

    // Depth of a page `<< /Foo 1 0 R >>` over `objects`, counting the loads.
    fn depth(
        objects: &HashMap<u32, Object>,
        finished: &mut HashMap<ObjectRef, usize>,
    ) -> (usize, usize) {
        let mut loads = 0;
        let mut load = |reference: ObjectRef| -> Result<Object, MergeError> {
            loads += 1;
            Ok(objects[&reference.id].clone())
        };
        let page = dict(&[("Foo", to(1))]);
        let depth = import_depth(&page, &mut load, finished).expect("measures");

        (depth, loads)
    }

    // Each `<< /N next >>` is a dictionary frame and a reference frame.
    #[test]
    fn a_reference_chain_costs_two_frames_a_level() {
        let objects: HashMap<u32, Object> = (1..=100)
            .map(|id| {
                let next = if id < 100 {
                    to(id + 1)
                } else {
                    Object::Boolean(true)
                };
                (id, dict(&[("N", next)]))
            })
            .collect();

        assert_eq!(depth(&objects, &mut HashMap::new()).0, 2 + 2 * 100);
    }

    #[test]
    fn nesting_inside_an_object_counts() {
        let nested = Object::Array(vec![Object::Array(vec![Object::Array(vec![to(2)])])]);
        let objects = HashMap::from([
            (1, dict(&[("A", nested)])),
            (2, dict(&[("End", Object::Boolean(true))])),
        ]);

        // The page's two frames, then 1's dictionary, three arrays and the
        // reference, then 2's two.
        assert_eq!(depth(&objects, &mut HashMap::new()).0, 2 + 5 + 2);
    }

    // Upstream stops only at an object already on its path, so it may walk a
    // cycle through every member before leaving it.
    #[test]
    fn a_cycle_counts_every_member() {
        let objects = HashMap::from([
            (1, dict(&[("N", to(2))])),
            (2, dict(&[("N", to(3))])),
            (3, dict(&[("N", to(1)), ("Out", to(4))])),
            (4, dict(&[("End", Object::Boolean(true))])),
        ]);

        assert_eq!(depth(&objects, &mut HashMap::new()).0, 2 + (2 + 2 + 2) + 2);
    }

    #[test]
    fn an_object_is_measured_once_across_pages() {
        let objects = HashMap::from([
            (1, dict(&[("N", to(2))])),
            (2, dict(&[("End", Object::Boolean(true))])),
        ]);
        let mut finished = HashMap::new();

        assert_eq!(depth(&objects, &mut finished), (6, 2));
        assert_eq!(depth(&objects, &mut finished), (6, 0));
    }

    #[test]
    fn a_page_of_an_ordinary_fixture_is_shallow() {
        let doc = PdfDocument::from_bytes(fixture("fonts.pdf")).expect("parses");
        let mut load =
            |reference| -> Result<Object, MergeError> { Ok(doc.load_object(reference)?) };
        let mut page = doc.get_page(0).expect("reads page 0");
        if let Object::Dictionary(dict) = &mut page {
            dict.remove("Parent");
        }

        let depth = import_depth(&page, &mut load, &mut HashMap::new()).expect("measures");

        assert!((4..64).contains(&depth), "depth {depth}");
    }

    #[test]
    fn a_page_with_annotations_is_refused() {
        assert!(matches!(
            prepare(fixture("flatten.pdf")),
            Err(MergeError::NamesAnotherPage { page: 0, entry }) if entry == "Annots"
        ));
    }

    #[test]
    fn a_page_reaching_the_page_tree_is_refused_by_the_entry_that_reaches_it() {
        let doc = PdfDocument::from_bytes(fixture("merge_page_references.pdf")).expect("parses");
        let tree = walk_page_tree(&doc, 5).expect("walks");
        // A fresh set per page: one left behind by a hit is not sound to share.
        let entry = |page: usize| {
            refused_entry(
                &doc,
                &tree,
                tree.leaves[page],
                &mut HashSet::new(),
                &mut false,
            )
            .expect("reads")
            .map(|(entry, _)| entry)
        };

        assert_eq!(entry(0), None);
        assert_eq!(entry(1).as_deref(), Some("SeparationInfo"));
        assert_eq!(entry(2).as_deref(), Some("PresSteps"));
        assert_eq!(entry(3).as_deref(), Some("AA"));
        assert_eq!(entry(4).as_deref(), Some("AA"));
    }

    #[test]
    fn a_named_destination_reached_indirectly_is_refused() {
        let doc =
            PdfDocument::from_bytes(fixture("merge_indirect_destinations.pdf")).expect("parses");
        let tree = walk_page_tree(&doc, 4).expect("walks");
        let entry = |page: usize| {
            refused_entry(
                &doc,
                &tree,
                tree.leaves[page],
                &mut HashSet::new(),
                &mut false,
            )
            .expect("reads")
            .map(|(entry, _)| entry)
        };

        assert_eq!(entry(0), None);
        assert_eq!(entry(1).as_deref(), Some("AA"));
        assert_eq!(entry(2).as_deref(), Some("AA"));
        assert_eq!(entry(3).as_deref(), Some("AA"));
        assert!(matches!(
            prepare(fixture("merge_indirect_destinations.pdf")),
            Err(MergeError::NamesAnotherPage { page: 1, entry }) if entry == "AA"
        ));
    }

    #[test]
    fn a_page_action_on_the_form_is_refused() {
        let doc = PdfDocument::from_bytes(fixture("merge_named_fields.pdf")).expect("parses");
        let tree = walk_page_tree(&doc, 9).expect("walks");
        let reach = |page: usize| {
            refused_entry(
                &doc,
                &tree,
                tree.leaves[page],
                &mut HashSet::new(),
                &mut false,
            )
            .expect("reads")
        };

        assert_eq!(reach(0), None);
        for page in 1..=8 {
            assert_eq!(
                reach(page),
                Some(("AA".to_string(), Reach::Form)),
                "page {page}"
            );
        }
        assert!(matches!(
            prepare(fixture("merge_named_fields.pdf")),
            Err(MergeError::ActsOnForm { page: 1, entry }) if entry == "AA"
        ));
    }

    #[test]
    fn a_structure_key_is_found_on_the_page_or_beneath_it() {
        let tagged = |name| prepare(fixture(name)).expect("prepares").tagged_page;

        assert_eq!(tagged("actualtext.pdf"), Some(0));
        assert_eq!(tagged("merge_tagged_xobject.pdf"), Some(0));
        assert_eq!(tagged("merge_tagged_xobject_plural.pdf"), Some(0));
        assert_eq!(tagged("fonts.pdf"), None);
    }

    #[test]
    fn a_structure_tree_is_told_from_its_absence() {
        let declares =
            |name| declares_structure(&PdfDocument::from_bytes(fixture(name)).expect("parses"));

        assert!(declares("structured.pdf"));
        assert!(!declares("fonts.pdf"));
    }

    #[test]
    fn prepare_reports_the_first_page_reaching_the_tree() {
        assert!(matches!(
            prepare(fixture("merge_page_references.pdf")),
            Err(MergeError::NamesAnotherPage { page: 1, entry }) if entry == "SeparationInfo"
        ));
    }

    // Its default configuration hides one of the two layers.
    #[test]
    fn a_page_using_layers_is_refused() {
        assert!(matches!(
            prepare(fixture("render_layers.pdf")),
            Err(MergeError::UsesOptionalContent { page: 0 })
        ));
    }

    // `sample.pdf` puts its font on the `/Pages` node.
    #[test]
    fn a_page_inheriting_resources_is_refused() {
        assert!(matches!(
            prepare(fixture("sample.pdf")),
            Err(MergeError::InheritsResources { page: 0 })
        ));
    }

    // Its page's `/Resources null` hides nothing: the font is on `/Pages`.
    #[test]
    fn a_null_resources_entry_is_inherited_through() {
        assert!(matches!(
            prepare(fixture("merge_null_resources.pdf")),
            Err(MergeError::InheritsResources { page: 0 })
        ));
    }

    // `degenerate_box.pdf`'s `/Pages` node carries an empty `/Resources`; its
    // pages declare none, which `OpenEditor::merge` weighs against the
    // destination's root.
    #[test]
    fn an_empty_inherited_resources_is_allowed() {
        let incoming = prepare(fixture("degenerate_box.pdf")).expect("prepares");

        assert!(incoming.pages.iter().all(|page| !page.owns_resources));
    }

    #[test]
    fn a_root_declaring_resources_is_told_from_one_that_does_not() {
        let declares = |name| {
            root_declares_resources(&PdfDocument::from_bytes(fixture(name)).expect("parses"))
        };

        assert!(declares("sample.pdf"));
        assert!(!declares("structured.pdf"));
        assert!(!declares("degenerate_box.pdf"));
    }

    // It opens without a password, which is what a check on authentication missed.
    #[test]
    fn an_encrypted_document_is_refused_even_when_it_opens() {
        assert!(matches!(
            prepare(fixture("encrypted_owner_only.pdf")),
            Err(MergeError::Encrypted)
        ));
    }

    #[test]
    fn a_declared_count_past_the_cap_is_refused_before_allocating() {
        let doc = PdfDocument::from_bytes(fixture("sample.pdf")).expect("parses");

        assert!(matches!(
            walk_page_tree(&doc, usize::MAX),
            Err(MergeError::Upstream(PdfError::InvalidPdf(_)))
        ));
    }

    #[test]
    fn a_page_tree_that_does_not_hold_its_count_is_refused() {
        assert!(matches!(
            prepare(fixture("broken_page.pdf")),
            Err(MergeError::Upstream(PdfError::InvalidPdf(_)))
        ));
    }

    #[test]
    fn every_page_reports_its_effective_attributes() {
        let incoming = prepare(fixture("inherited_boxes.pdf")).expect("prepares");

        assert_eq!(
            incoming.pages[0],
            PageAttrs {
                rotation: 180,
                media_box: [0.0, 0.0, 300.0, 500.0],
                crop_box: Some([20.0, 20.0, 280.0, 480.0]),
                owns_resources: false,
            }
        );
    }

    #[test]
    fn a_document_with_no_pages_prepares_to_nothing() {
        assert!(prepare(fixture("no_pages.pdf"))
            .expect("prepares")
            .pages
            .is_empty());
    }
}
