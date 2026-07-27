use pdf_oxide::{Destination, OutlineItem};
use rustler::{NifMap, NifResult, NifTaggedEnum};

use crate::{atoms, error::tagged_err};

/// Maximum outline nesting this conversion will walk.
///
/// [`outline_item_to_nif`] recurses over `children`, and so does the `NifMap`
/// encoder that turns the result into terms, so an attacker-controlled `/First`
/// chain would otherwise overflow the *native* stack. That is not a catchable
/// panic — it aborts the OS process, taking the whole BEAM with it, so
/// `contain_panic` cannot degrade it the way it does an upstream `unwrap`.
///
/// 256 is far past any real table of contents while staying comfortably inside
/// the dirty scheduler's stack; upstream caps its own name-tree walk at 32
/// (`pdf_oxide` `src/outline.rs`, `NAME_TREE_MAX_DEPTH`, citing its
/// untrusted-input limits policy), its page-tree walk at 50 and object
/// resolution at 100. Recursing this far is safe *a fortiori*: upstream's much
/// heavier `parse_outline_item` already recursed to the same depth on this same
/// thread to build the tree we are handed.
///
/// **This is defence in depth, not a complete fix.** `PdfDocument::get_outline`
/// returns a fully owned tree, built eagerly by `parse_outline_item`
/// (`src/outline.rs:112`, recursing at :143), which has no depth parameter, no
/// visited set and no cap of its own — nor does the `/Next` sibling walk, where
/// a cycle loops until it exhausts memory. A document deep enough to matter
/// therefore dies *there*, before this code runs. `load_object`'s
/// `MAX_RECURSION_DEPTH` and `RESOLVING_STACK` (`src/document.rs:2249-2273`) do
/// not help, being scoped to a single resolution. The cap is what keeps this
/// crate from being the remaining hole, and becomes the effective guard once
/// upstream closes theirs.
const MAX_OUTLINE_DEPTH: usize = 256;

#[derive(NifMap, Debug)]
pub struct OutlineItemNif {
    title: String,
    dest: Option<DestinationNif>,
    children: Vec<OutlineItemNif>,
}

#[derive(NifTaggedEnum, Debug)]
pub enum DestinationNif {
    Page(usize),
    Named(String),
}

/// Signals an outline nested deeper than [`MAX_OUTLINE_DEPTH`].
///
/// A marker type rather than a `tagged_err` built where the cap is checked, so
/// the recursion stays reachable from `cargo test`: every reason atom needs a
/// live BEAM to exist, which is why `error.rs`'s own tests can only cover
/// `panic_message`.
#[derive(Debug)]
struct TooDeep;

/// Converts a document's top-level outline items, rejecting one nested past
/// [`MAX_OUTLINE_DEPTH`] with `:unsupported`.
///
/// The whole outline fails rather than being silently truncated: a caller who
/// asked for the table of contents is better served by an error it can match on
/// than by a tree that quietly stops part-way down.
pub fn outline_to_nif(items: Vec<OutlineItem>) -> NifResult<Vec<OutlineItemNif>> {
    items
        .into_iter()
        .map(|item| outline_item_to_nif(item, 0))
        .collect::<Result<_, TooDeep>>()
        .map_err(|TooDeep| {
            tagged_err(
                atoms::unsupported(),
                format!("Outline nesting exceeds the supported depth of {MAX_OUTLINE_DEPTH}"),
            )
        })
}

/// Converts one item and its subtree. `depth` is zero for a top-level item.
///
/// The cap is checked here, on the item, rather than before recursing into a
/// child list: an item at the last allowed depth with no children is fine, and
/// checking the list would reject it for the empty recursion its own leaves make.
fn outline_item_to_nif(item: OutlineItem, depth: usize) -> Result<OutlineItemNif, TooDeep> {
    if depth >= MAX_OUTLINE_DEPTH {
        return Err(TooDeep);
    }

    Ok(OutlineItemNif {
        title: item.title,
        dest: item.dest.map(|dest| match dest {
            Destination::PageIndex(index) => DestinationNif::Page(index),
            Destination::Named(name) => DestinationNif::Named(name),
        }),
        children: item
            .children
            .into_iter()
            .map(|child| outline_item_to_nif(child, depth + 1))
            .collect::<Result<_, TooDeep>>()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A linear chain of `levels` nested items — the shape a malicious `/First`
    /// chain produces, and the only one whose depth is unambiguous.
    fn chain(levels: usize) -> OutlineItem {
        (1..levels).fold(leaf(), |child, _| OutlineItem {
            title: String::from("nested"),
            dest: None,
            children: vec![child],
        })
    }

    fn leaf() -> OutlineItem {
        OutlineItem {
            title: String::from("leaf"),
            dest: Some(Destination::PageIndex(0)),
            children: Vec::new(),
        }
    }

    fn depth_of(item: &OutlineItemNif) -> usize {
        1 + item.children.iter().map(depth_of).max().unwrap_or(0)
    }

    #[test]
    fn converts_an_outline_exactly_at_the_depth_cap() {
        let converted = outline_item_to_nif(chain(MAX_OUTLINE_DEPTH), 0).expect("at the cap");

        // Pins the off-by-one: 256 means 256 levels are usable, not 255.
        assert_eq!(depth_of(&converted), MAX_OUTLINE_DEPTH);
    }

    #[test]
    fn rejects_an_outline_one_level_past_the_depth_cap() {
        assert!(outline_item_to_nif(chain(MAX_OUTLINE_DEPTH + 1), 0).is_err());
    }

    #[test]
    fn accepts_a_childless_item_at_the_last_allowed_depth() {
        // The regression the check's placement avoids: an item here recurses
        // into an empty child list, which must not count as a level of its own.
        assert!(outline_item_to_nif(leaf(), MAX_OUTLINE_DEPTH - 1).is_ok());
        assert!(outline_item_to_nif(leaf(), MAX_OUTLINE_DEPTH).is_err());
    }
}
