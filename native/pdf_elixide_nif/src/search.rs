use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use pdf_oxide::{error::Result, layout::TextSpan, search::SearchResult};
use rustler::NifMap;

use crate::{
    geometry::{rect_to_nif, RectNif},
    span::{span_ref_to_nif, SpanNif},
};

#[derive(NifMap, Debug)]
pub struct SearchMatchNif {
    page: usize,
    text: String,
    bbox: RectNif,
    spans: Vec<SpanNif>,
}

pub fn search_match_to_nif(hit: SearchResult, runs: &PageRuns) -> Option<SearchMatchNif> {
    let spans = runs
        .matched(&hit)?
        .iter()
        .map(|span| span_ref_to_nif(span, hit.page))
        .collect();

    Some(SearchMatchNif {
        page: hit.page,
        text: hit.text,
        bbox: rect_to_nif(hit.bbox),
        spans,
    })
}

// One page's indexed spans and their byte ranges in the joined search text.
pub struct PageRuns {
    spans: Vec<TextSpan>,
    positions: Vec<(usize, usize)>,
}

impl PageRuns {
    pub fn from_spans(mut spans: Vec<TextSpan>) -> Self {
        // Encoding never reads these per-glyph vectors, so do not cache them.
        for span in &mut spans {
            span.char_widths = Vec::new();
            span.char_x_offsets = Vec::new();
        }
        let positions = positions(&spans);
        Self { spans, positions }
    }

    // Verify the selected spans against upstream's boxes rather than guessing
    // if the duplicated join rule drifts.
    pub fn matched(&self, hit: &SearchResult) -> Option<&[TextSpan]> {
        let overlaps =
            |&(start, end): &(usize, usize)| start < hit.end_index && end > hit.start_index;
        let first = self.positions.iter().position(overlaps);
        let last = self.positions.iter().rposition(overlaps);
        let slice = match (first, last) {
            (Some(first), Some(last)) => &self.spans[first..=last],
            _ => &self.spans[0..0],
        };

        let boxes_agree = slice.len() == hit.span_boxes.len()
            && slice
                .iter()
                .zip(&hit.span_boxes)
                .all(|(span, bbox)| span.bbox == *bbox);
        boxes_agree.then_some(slice)
    }
}

// Upstream's join rule: each span's text in order, with one space after any
// span but the last that does not already end in one.
fn positions(spans: &[TextSpan]) -> Vec<(usize, usize)> {
    let mut offset = 0;
    spans
        .iter()
        .enumerate()
        .map(|(idx, span)| {
            let start = offset;
            let end = start + span.text.len();
            offset = end;
            if idx < spans.len() - 1 && !span.text.ends_with(' ') {
                offset += 1;
            }
            (start, end)
        })
        .collect()
}

// Per-handle cache of the runs behind matches, released with the search index.
pub struct SearchRuns(Mutex<HashMap<usize, Arc<PageRuns>>>);

impl SearchRuns {
    pub fn new() -> Self {
        Self(Mutex::new(HashMap::new()))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<usize, Arc<PageRuns>>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    // Two readers filling one page do the work twice and converge; the guard
    // is not held across the extraction so neither blocks the other.
    pub fn get_or_fill(
        &self,
        page: usize,
        extract: impl FnOnce() -> Result<Vec<TextSpan>>,
    ) -> Result<Arc<PageRuns>> {
        if let Some(runs) = self.lock().get(&page) {
            return Ok(Arc::clone(runs));
        }
        let runs = Arc::new(PageRuns::from_spans(extract()?));
        self.lock().insert(page, Arc::clone(&runs));
        Ok(runs)
    }

    pub fn clear(&self) {
        self.lock().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(text: &str) -> TextSpan {
        TextSpan {
            text: text.to_string(),
            ..TextSpan::default()
        }
    }

    #[test]
    fn a_join_space_follows_only_a_span_that_does_not_end_in_one() {
        let spans = [span("ab"), span("cd "), span("ef"), span("gh")];

        assert_eq!(positions(&spans), vec![(0, 2), (3, 6), (6, 8), (9, 11)]);
    }

    #[test]
    fn the_last_span_gets_no_join_space() {
        assert_eq!(positions(&[span("ab")]), vec![(0, 2)]);
        assert!(positions(&[]).is_empty());
    }
}
