use pdf_oxide::search::SearchResult;
use rustler::NifMap;

use crate::geometry::{rect_to_nif, RectNif};

#[derive(NifMap, Debug)]
pub struct SearchMatchNif {
    page: usize,
    text: String,
    bbox: RectNif,
    span_boxes: Vec<RectNif>,
}

pub fn search_match_to_nif(hit: SearchResult) -> SearchMatchNif {
    SearchMatchNif {
        page: hit.page,
        text: hit.text,
        bbox: rect_to_nif(hit.bbox),
        span_boxes: hit.span_boxes.into_iter().map(rect_to_nif).collect(),
    }
}
