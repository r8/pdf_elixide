use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use pdf_oxide::{
    error::Result,
    layout::TextSpan,
    search::{SearchOptions, SearchResult},
};
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

// Options for `PdfElixide.Document.search/3,4`.
#[derive(NifMap, Debug)]
pub struct SearchOptionsNif {
    pub case_insensitive: bool,
    pub literal: bool,
    pub whole_word: bool,
    pub max_results: Option<usize>,
}

impl From<SearchOptionsNif> for SearchOptions {
    fn from(o: SearchOptionsNif) -> Self {
        SearchOptions::new()
            .with_case_insensitive(o.case_insensitive)
            .with_literal(o.literal)
            .with_whole_word(o.whole_word)
            // Upstream reads a limit of 0 as no limit.
            .with_max_results(o.max_results.unwrap_or(0))
    }
}

// What `TextSearcher::search` is handed for one search call.
pub struct SearchRequest {
    pub pattern: String,
    pub options: SearchOptions,
    // The caller's pattern when `pattern` was grouped, so a compile error can
    // be reported against what they wrote rather than the grouped form.
    pub raw_pattern: Option<String>,
}

impl SearchOptionsNif {
    // Upstream wraps a `whole_word` pattern as `\b{pattern}\b` with no group,
    // so a top-level alternation binds as `(\bcat)|(dog\b)`. The escaped
    // literal path has nothing to misbind; the regex path is grouped here and
    // sent upstream with `whole_word` off.
    pub fn into_request(self, pattern: String) -> SearchRequest {
        let grouped = !self.literal && self.whole_word;
        let options = SearchOptions::from(self);

        if grouped {
            SearchRequest {
                pattern: format!(r"\b(?:{pattern})\b"),
                options: options.with_whole_word(false),
                raw_pattern: Some(pattern),
            }
        } else {
            SearchRequest {
                pattern,
                options,
                raw_pattern: None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn search_options(literal: bool, whole_word: bool) -> SearchOptionsNif {
        SearchOptionsNif {
            case_insensitive: true,
            literal,
            whole_word,
            max_results: Some(7),
        }
    }

    #[test]
    fn a_whole_word_regex_is_grouped_and_sent_upstream_ungrouped() {
        let request = search_options(false, true).into_request("cat|dog".into());

        assert_eq!(request.pattern, r"\b(?:cat|dog)\b");
        assert_eq!(request.raw_pattern.as_deref(), Some("cat|dog"));
        assert!(!request.options.whole_word);
        assert!(!request.options.literal);
        assert!(request.options.case_insensitive);
        assert_eq!(request.options.max_results, 7);
    }

    #[test]
    fn a_whole_word_literal_passes_through_for_upstream_to_escape_and_wrap() {
        let request = search_options(true, true).into_request("cat|dog".into());

        assert_eq!(request.pattern, "cat|dog");
        assert_eq!(request.raw_pattern, None);
        assert!(request.options.whole_word);
        assert!(request.options.literal);
    }

    #[test]
    fn a_regex_without_whole_word_passes_through() {
        let request = search_options(false, false).into_request("cat|dog".into());

        assert_eq!(request.pattern, "cat|dog");
        assert_eq!(request.raw_pattern, None);
        assert!(!request.options.whole_word);
    }

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
