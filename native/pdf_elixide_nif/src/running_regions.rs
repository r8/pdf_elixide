use std::collections::{BTreeMap, HashMap, HashSet};

use pdf_oxide::{
    document::PageArea,
    error::Result,
    extractors::text::{ArtifactType, PaginationSubtype},
    geometry::Rect,
    layout::TextSpan,
    PdfDocument,
};
use rustler::{NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
    span::{span_to_nif, SpanNif},
    DocumentResource,
};

#[derive(NifUnitEnum, Debug, Clone, Copy)]
pub enum RunningAreaNif {
    Header,
    Footer,
    Both,
}

impl RunningAreaNif {
    // `Both` is headers then footers, the order `remove_artifacts` runs them in.
    fn areas(self) -> &'static [PageArea] {
        match self {
            RunningAreaNif::Header => &[PageArea::Header],
            RunningAreaNif::Footer => &[PageArea::Footer],
            RunningAreaNif::Both => &[PageArea::Header, PageArea::Footer],
        }
    }
}

#[derive(NifMap, Debug)]
pub struct RunningRegionsOptionsNif {
    area: RunningAreaNif,
    threshold: f32,
}

impl RunningRegionsOptionsNif {
    // Defence in depth for callers bypassing Elixir's identical check; the
    // inclusive range also rejects NaN and infinities.
    fn validate(&self) -> NifResult<()> {
        if !(0.0..=1.0).contains(&self.threshold) {
            return Err(tagged_err(
                atoms::other(),
                format!(
                    "Invalid :threshold {:?}: the threshold must be between 0.0 and 1.0",
                    self.threshold
                ),
            ));
        }
        Ok(())
    }
}

const ZONE_TOP: f32 = 0.85;
const ZONE_BOTTOM: f32 = 0.15;
const POS_TOL_X: f32 = 40.0;
const POS_TOL_Y: f32 = 24.0;

struct PageSpans {
    spans: Vec<TextSpan>,
    height: Option<f32>,
}

fn in_zone(area: PageArea, bbox: &Rect, height: f32) -> bool {
    match area {
        PageArea::Header => bbox.y > height * ZONE_TOP,
        PageArea::Footer => bbox.y + bbox.height < height * ZONE_BOTTOM,
    }
}

// Keep every span when the media box cannot be read: tagged results need no
// box, while heuristic detection retries the lookup and returns its error.
fn candidates(doc: &PdfDocument, page: usize, areas: &[PageArea]) -> Result<PageSpans> {
    let spans = doc.extract_spans(page)?;
    let height = doc
        .get_page_media_box(page)
        .ok()
        .map(|media_box| media_box.3);

    let spans = spans
        .into_iter()
        .filter(|span| {
            matches!(span.artifact_type, Some(ArtifactType::Pagination(_)))
                || height.is_none_or(|height| {
                    areas.iter().any(|&area| in_zone(area, &span.bbox, height))
                })
        })
        .collect();

    Ok(PageSpans { spans, height })
}

fn running_regions(
    doc: &PdfDocument,
    areas: &[PageArea],
    threshold: f32,
) -> Result<BTreeMap<usize, Vec<TextSpan>>> {
    let page_count = doc.page_count()?;
    let pages = (0..page_count)
        .map(|page| candidates(doc, page, areas))
        .collect::<Result<Vec<_>>>()?;

    let mut found: BTreeMap<usize, Vec<&TextSpan>> = BTreeMap::new();
    for &area in areas {
        // Upstream's second area sees the first one's finds masked out.
        let visible: Vec<(Option<f32>, Vec<&TextSpan>)> = pages
            .iter()
            .enumerate()
            .map(|(page, PageSpans { spans, height })| {
                let masked = found.get(&page).map_or(&[][..], Vec::as_slice);
                let spans = spans
                    .iter()
                    .filter(|span| !masked.iter().any(|hit| hit.bbox.intersects(&span.bbox)))
                    .collect();
                (*height, spans)
            })
            .collect();

        for (page, span) in area_regions(doc, &visible, area, threshold)? {
            found.entry(page).or_default().push(span);
        }
    }

    // Upstream counts a span once per find, so a duplicate is kept.
    Ok(found
        .into_iter()
        .map(|(page, spans)| (page, spans.into_iter().cloned().collect()))
        .collect())
}

fn area_regions<'a>(
    doc: &PdfDocument,
    pages: &[(Option<f32>, Vec<&'a TextSpan>)],
    area: PageArea,
    threshold: f32,
) -> Result<Vec<(usize, &'a TextSpan)>> {
    let mut regions = Vec::new();

    for (page, (_, spans)) in pages.iter().enumerate() {
        for &span in spans {
            if let Some(ArtifactType::Pagination(subtype)) = &span.artifact_type {
                if matches!(
                    (area, subtype),
                    (PageArea::Header, PaginationSubtype::Header)
                        | (PageArea::Footer, PaginationSubtype::Footer)
                ) {
                    regions.push((page, span));
                }
            }
        }
    }

    // Tagged artifacts, when present, replace the heuristic entirely.
    if !regions.is_empty() || pages.len() < 2 {
        return Ok(regions);
    }

    let min_pages = ((pages.len() as f32 * threshold).ceil() as usize).max(1);
    let mut occurrences: HashMap<&str, Vec<(usize, &TextSpan)>> = HashMap::new();

    for (page, (height, spans)) in pages.iter().enumerate() {
        let height = match height {
            Some(height) => *height,
            None => doc.get_page_media_box(page)?.3,
        };
        for &span in spans {
            if !in_zone(area, &span.bbox, height) {
                continue;
            }

            if matches!(
                span.artifact_type,
                Some(ArtifactType::Pagination(PaginationSubtype::Other))
            ) {
                regions.push((page, span));
                continue;
            }

            let text = span.text.trim();
            if text.len() > 3 && !text.chars().all(char::is_numeric) {
                occurrences.entry(text).or_default().push((page, span));
            }
        }
    }

    for occurrences in occurrences.into_values() {
        let distinct: HashSet<usize> = occurrences.iter().map(|&(page, _)| page).collect();
        if distinct.len() < min_pages {
            continue;
        }

        let (mut min_x, mut max_x) = (f32::MAX, f32::MIN);
        let (mut min_y, mut max_y) = (f32::MAX, f32::MIN);
        for (_, span) in &occurrences {
            min_x = min_x.min(span.bbox.x);
            max_x = max_x.max(span.bbox.x);
            min_y = min_y.min(span.bbox.y);
            max_y = max_y.max(span.bbox.y);
        }
        if max_x - min_x > POS_TOL_X || max_y - min_y > POS_TOL_Y {
            continue;
        }

        regions.extend(occurrences);
    }

    Ok(regions)
}

// Upstream's order follows `HashMap` iteration; sort so a result is stable.
fn to_nif(found: BTreeMap<usize, Vec<TextSpan>>) -> HashMap<usize, Vec<SpanNif>> {
    found
        .into_iter()
        .map(|(page, mut spans)| {
            spans.sort_by(|a, b| {
                b.bbox
                    .y
                    .total_cmp(&a.bbox.y)
                    .then(a.bbox.x.total_cmp(&b.bbox.x))
            });
            let spans = spans
                .into_iter()
                .map(|span| span_to_nif(span, page))
                .collect();
            (page, spans)
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_running_regions(
    resource: ResourceArc<DocumentResource>,
    options: RunningRegionsOptionsNif,
) -> NifResult<HashMap<usize, Vec<SpanNif>>> {
    resource.doc.with_read(|doc| {
        options.validate()?;

        running_regions(doc, options.area.areas(), options.threshold)
            .map(to_nif)
            .map_err(to_nif_err)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open(name: &str) -> PdfDocument {
        PdfDocument::open(format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        ))
        .expect("fixture opens")
    }

    fn texts<'a>(spans: impl IntoIterator<Item = &'a TextSpan>) -> Vec<String> {
        spans.into_iter().map(|span| span.text.clone()).collect()
    }

    #[test]
    fn running_regions_match_upstream() {
        for (name, threshold) in [
            ("running_headers.pdf", 0.8),
            ("running_headers.pdf", 0.5),
            ("running_folios.pdf", 0.8),
            ("running_folios.pdf", 0.25),
            ("running_rotated.pdf", 0.8),
            ("extraction.pdf", 0.8),
            ("structured.pdf", 0.8),
            ("sample.pdf", 0.8),
        ] {
            for area in [
                RunningAreaNif::Header,
                RunningAreaNif::Footer,
                RunningAreaNif::Both,
            ] {
                let label = format!("{name} {area:?} {threshold}");
                let ours = running_regions(&open(name), area.areas(), threshold).expect("local");

                let upstream = open(name);
                let count = match area {
                    RunningAreaNif::Header => upstream.remove_headers(threshold),
                    RunningAreaNif::Footer => upstream.remove_footers(threshold),
                    RunningAreaNif::Both => upstream.remove_artifacts(threshold),
                }
                .expect("upstream");

                assert_eq!(ours.values().map(Vec::len).sum::<usize>(), count, "{label}");

                let fresh = open(name);
                for page in 0..fresh.page_count().expect("page count") {
                    let found = ours.get(&page).map_or(&[][..], Vec::as_slice);
                    let spans = fresh.extract_spans(page).expect("spans");
                    let kept = spans
                        .iter()
                        .filter(|span| !found.iter().any(|hit| hit.bbox.intersects(&span.bbox)));

                    assert_eq!(
                        texts(kept),
                        texts(&upstream.extract_spans(page).expect("masked spans")),
                        "{label} page {page}"
                    );
                }
            }
        }
    }

    // Precondition for the comparison above: each path really finds something,
    // so it cannot pass by both sides finding nothing.
    #[test]
    fn running_regions_fixtures_exercise_every_path() {
        let both = RunningAreaNif::Both.areas();

        let heuristic = running_regions(&open("running_headers.pdf"), both, 0.8).expect("local");
        assert_eq!(heuristic.len(), 4);

        let tagged = running_regions(&open("structured.pdf"), both, 0.8).expect("local");
        assert!(!tagged.is_empty());

        let inferred = running_regions(&open("running_folios.pdf"), both, 0.8).expect("local");
        assert_eq!(inferred.keys().copied().collect::<Vec<_>>(), [1, 2, 3]);
    }
}
