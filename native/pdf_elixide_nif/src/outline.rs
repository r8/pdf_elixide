use pdf_oxide::{Destination, OutlineItem};
use rustler::{NifMap, NifResult, NifTaggedEnum};

use crate::{atoms, error::tagged_err};

// Bounds this recursion, the recursive NifMap encoder and upstream's
// `flatten_outline` in the bookmark split; defence in depth, since the outline
// is parsed before it gets here.
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

// Keep the recursive walks BEAM-independent; build the reason atom outside.
#[derive(Debug)]
pub(crate) struct TooDeep;

pub(crate) fn too_deep() -> rustler::Error {
    tagged_err(
        atoms::unsupported(),
        format!("Outline nesting exceeds the supported depth of {MAX_OUTLINE_DEPTH}"),
    )
}

// The same cap for callers that walk upstream's tree without converting it.
pub(crate) fn check_depth(items: &[OutlineItem]) -> Result<(), TooDeep> {
    check_depth_from(items, 0)
}

fn check_depth_from(items: &[OutlineItem], depth: usize) -> Result<(), TooDeep> {
    items.iter().try_for_each(|item| {
        if depth >= MAX_OUTLINE_DEPTH {
            return Err(TooDeep);
        }

        check_depth_from(&item.children, depth + 1)
    })
}

// Fails whole rather than truncating: a caller cannot detect a table of
// contents that quietly stops part-way down.
pub fn outline_to_nif(items: Vec<OutlineItem>) -> NifResult<Vec<OutlineItemNif>> {
    items
        .into_iter()
        .map(|item| outline_item_to_nif(item, 0))
        .collect::<Result<_, TooDeep>>()
        .map_err(|TooDeep| too_deep())
}

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

        assert_eq!(depth_of(&converted), MAX_OUTLINE_DEPTH);
    }

    #[test]
    fn rejects_an_outline_one_level_past_the_depth_cap() {
        assert!(outline_item_to_nif(chain(MAX_OUTLINE_DEPTH + 1), 0).is_err());
    }

    #[test]
    fn check_depth_agrees_with_the_conversion_cap() {
        assert!(check_depth(&[chain(MAX_OUTLINE_DEPTH)]).is_ok());
        assert!(check_depth(&[chain(MAX_OUTLINE_DEPTH + 1)]).is_err());
    }

    #[test]
    fn accepts_a_childless_item_at_the_last_allowed_depth() {
        assert!(outline_item_to_nif(leaf(), MAX_OUTLINE_DEPTH - 1).is_ok());
        assert!(outline_item_to_nif(leaf(), MAX_OUTLINE_DEPTH).is_err());
    }
}
