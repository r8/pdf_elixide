use pdf_oxide::{Destination, OutlineItem};
use rustler::{NifMap, NifTaggedEnum};

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

pub fn outline_item_to_nif(item: OutlineItem) -> OutlineItemNif {
    OutlineItemNif {
        title: item.title,
        dest: item.dest.map(|dest| match dest {
            Destination::PageIndex(index) => DestinationNif::Page(index),
            Destination::Named(name) => DestinationNif::Named(name),
        }),
        children: item.children.into_iter().map(outline_item_to_nif).collect(),
    }
}
