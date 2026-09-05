use pdf_oxide::{
    structured::{ColumnMode, RegionRole, StructuredPage, StructuredRegion},
    PdfDocument,
};
use rustler::{NifMap, NifResult, NifTaggedEnum, ResourceArc};

use crate::{
    document::ensure_page_in_range,
    error::to_nif_err,
    extract_options::StructuredOptionsNif,
    geometry::{rect_to_nif, RectNif},
    span::{span_to_nif, SpanNif},
    DocumentResource,
};

#[derive(NifTaggedEnum, Debug)]
pub enum RegionKindNif {
    Body,
    Heading(u8),
    MarginalLabel,
    Header,
    Footer,
    PageNumber,
    Artifact,
}

impl From<RegionRole> for RegionKindNif {
    fn from(role: RegionRole) -> Self {
        match role {
            RegionRole::BodyBlock => RegionKindNif::Body,
            RegionRole::StructuralHeading { level } => RegionKindNif::Heading(level),
            RegionRole::MarginalLabel => RegionKindNif::MarginalLabel,
            RegionRole::Header => RegionKindNif::Header,
            RegionRole::Footer => RegionKindNif::Footer,
            RegionRole::PageNumber => RegionKindNif::PageNumber,
            RegionRole::Artifact => RegionKindNif::Artifact,
        }
    }
}

#[derive(NifMap, Debug)]
pub struct StructuredRegionNif {
    page: usize,
    kind: RegionKindNif,
    text: String,
    bbox: RectNif,
    spans: Vec<SpanNif>,
    column: Option<usize>,
    section: Option<usize>,
}

#[derive(NifMap, Debug)]
pub struct StructuredPageNif {
    page: usize,
    width: f32,
    height: f32,
    regions: Vec<StructuredRegionNif>,
}

fn region_to_nif(region: StructuredRegion, page: usize) -> StructuredRegionNif {
    StructuredRegionNif {
        page,
        kind: region.kind.into(),
        text: region.text,
        bbox: rect_to_nif(region.bbox),
        spans: region
            .spans
            .into_iter()
            .map(|span| span_to_nif(span, page))
            .collect(),
        column: region.column_index,
        section: region.section_id,
    }
}

fn page_to_nif(page: StructuredPage) -> StructuredPageNif {
    let index = page.page_index;
    StructuredPageNif {
        page: index,
        width: page.page_width,
        height: page.page_height,
        regions: page
            .regions
            .into_iter()
            .map(|region| region_to_nif(region, index))
            .collect(),
    }
}

fn extract_structured_page(
    doc: &PdfDocument,
    page_index: usize,
    mode: ColumnMode,
) -> NifResult<StructuredPageNif> {
    doc.extract_structured_with_column_mode(page_index, mode)
        .map(page_to_nif)
        .map_err(to_nif_err)
}

// Reject bad indices before upstream scans every object and returns InvalidPdf.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_structured(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: StructuredOptionsNif,
) -> NifResult<StructuredPageNif> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;
        extract_structured_page(doc, page_index, options.column_mode.into())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_structured(
    resource: ResourceArc<DocumentResource>,
    options: StructuredOptionsNif,
) -> NifResult<Vec<StructuredPageNif>> {
    resource.doc.with_read(|doc| {
        let mode: ColumnMode = options.column_mode.into();
        let count = doc.page_count().map_err(to_nif_err)?;
        (0..count)
            .map(|page_index| extract_structured_page(doc, page_index, mode))
            .collect()
    })
}
