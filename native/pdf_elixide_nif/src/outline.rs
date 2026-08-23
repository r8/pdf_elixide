use pdf_oxide::{Destination, OutlineItem};
use rustler::{NifMap, NifResult, NifTaggedEnum};

use crate::{atoms, error::tagged_err};

// Bound both this recursion and the recursive NifMap encoder. This remains
// defence in depth because the outline is already parsed before it reaches us.
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

// Keep the recursive conversion BEAM-independent; build the reason atom outside.
#[derive(Debug)]
struct TooDeep;

// Rejects an outline nested past [`MAX_OUTLINE_DEPTH`] with `:unsupported`.
//
// The whole outline fails rather than being silently truncated: a caller who
// asked for the table of contents is better served by an error it can match on
// than by a tree that quietly stops part-way down.
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

// Converts one item and its subtree. `depth` is zero for a top-level item.
//
// The cap is checked here, on the item, rather than before recursing into a
// child list: an item at the last allowed depth with no children is fine, and
// checking the list would reject it for the empty recursion its own leaves make.
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

        // The cap is inclusive.
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
