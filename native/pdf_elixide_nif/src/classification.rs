use pdf_oxide::{
    extractors::auto::{
        ImageCodecClass, PageClassification, PageKind, PageSignals, ProducerPrior, ReasonCode,
    },
    Error as PdfError,
};
use rustler::{NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    error::{to_nif_err, to_nif_page_err},
    geometry::finite,
    pages::ensure_page_in_range,
    resource::DocumentResource,
};

#[derive(NifUnitEnum, Debug)]
enum KindNif {
    TextLayer,
    Scanned,
    ImageText,
    Mixed,
    Empty,
    Unknown,
}

impl From<PageKind> for KindNif {
    fn from(kind: PageKind) -> Self {
        match kind {
            PageKind::TextLayer => Self::TextLayer,
            PageKind::Scanned => Self::Scanned,
            PageKind::ImageText => Self::ImageText,
            PageKind::Mixed => Self::Mixed,
            PageKind::Empty => Self::Empty,
            _ => Self::Unknown,
        }
    }
}

#[derive(NifUnitEnum, Debug)]
enum ReasonNif {
    Ok,
    NativeTextHighConfidence,
    NoTextLayerPresent,
    TextLayerBelowThreshold,
    GlyphMappingMissing,
    Empty,
    Unknown,
}

impl From<ReasonCode> for ReasonNif {
    fn from(reason: ReasonCode) -> Self {
        match reason {
            ReasonCode::Ok => Self::Ok,
            ReasonCode::NativeTextHighConfidence => Self::NativeTextHighConfidence,
            ReasonCode::NoTextLayerPresent => Self::NoTextLayerPresent,
            ReasonCode::TextLayerBelowThreshold => Self::TextLayerBelowThreshold,
            ReasonCode::GlyphMappingMissing => Self::GlyphMappingMissing,
            ReasonCode::Empty => Self::Empty,
            _ => Self::Unknown,
        }
    }
}

#[derive(NifUnitEnum, Debug)]
enum CodecNif {
    None,
    Ccitt,
    Jbig2,
    Dct,
    Other,
    Unknown,
}

impl From<ImageCodecClass> for CodecNif {
    fn from(codec: ImageCodecClass) -> Self {
        match codec {
            ImageCodecClass::None => Self::None,
            ImageCodecClass::Ccitt => Self::Ccitt,
            ImageCodecClass::Jbig2 => Self::Jbig2,
            ImageCodecClass::Dct => Self::Dct,
            ImageCodecClass::Other => Self::Other,
            _ => Self::Unknown,
        }
    }
}

#[derive(NifUnitEnum, Debug)]
enum ProducerNif {
    Scanner,
    Authoring,
    Unknown,
}

impl From<ProducerPrior> for ProducerNif {
    fn from(prior: ProducerPrior) -> Self {
        match prior {
            ProducerPrior::Scanner => Self::Scanner,
            ProducerPrior::Authoring => Self::Authoring,
            _ => Self::Unknown,
        }
    }
}

#[derive(NifMap, Debug)]
struct SignalsNif {
    text_glyph_count: usize,
    text_area_ratio: f32,
    image_area_ratio: f32,
    codec: CodecNif,
    invisible_text_ratio: f32,
    garbled_ratio: f32,
    fragmented_word_ratio: f32,
    repeated_word_ratio: f32,
    vector_path_density: f32,
    vector_path_count: usize,
    reliable_structure: bool,
    producer: ProducerNif,
    empty: bool,
}

#[derive(NifMap, Debug)]
pub struct ClassificationNif {
    page: usize,
    kind: KindNif,
    confidence: f32,
    reason: ReasonNif,
    needs_ocr: bool,
    signals: SignalsNif,
}

fn needs_ocr(kind: PageKind) -> bool {
    matches!(
        kind,
        PageKind::Scanned | PageKind::ImageText | PageKind::Mixed
    )
}

fn signals_to_nif(signals: PageSignals) -> SignalsNif {
    SignalsNif {
        text_glyph_count: signals.text_glyph_count,
        text_area_ratio: finite(signals.text_area_ratio),
        image_area_ratio: finite(signals.image_area_ratio),
        codec: signals.codec.into(),
        invisible_text_ratio: finite(signals.invisible_text_ratio),
        garbled_ratio: finite(signals.garbled_ratio),
        fragmented_word_ratio: finite(signals.fragmented_word_ratio),
        repeated_word_ratio: finite(signals.consecutive_repeat_ratio),
        vector_path_density: finite(signals.vector_path_density),
        vector_path_count: signals.vector_path_count,
        reliable_structure: signals.has_reliable_structure,
        producer: signals.producer_prior.into(),
        empty: signals.page_is_empty,
    }
}

fn classification_to_nif(c: PageClassification) -> ClassificationNif {
    ClassificationNif {
        page: c.page,
        kind: c.kind.into(),
        confidence: finite(c.confidence),
        reason: c.reason.into(),
        needs_ocr: needs_ocr(c.kind),
        signals: signals_to_nif(c.signals),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_classify(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<ClassificationNif> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;
        doc.classify_page(page_index)
            .map(classification_to_nif)
            .map_err(to_nif_err)
    })
}

// Classify each page to preserve failures; authenticate first to avoid a page prefix.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_classify(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Vec<ClassificationNif>> {
    resource.doc.with_read(|doc| {
        if !doc.is_authenticated() {
            return Err(to_nif_err(PdfError::EncryptedPdf));
        }
        let count = doc.page_count().map_err(to_nif_err)?;
        (0..count)
            .map(|page_index| {
                doc.classify_page(page_index)
                    .map(classification_to_nif)
                    .map_err(|e| to_nif_page_err(page_index, e))
            })
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{extractors::auto::AutoExtractor, PdfDocument};

    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    #[test]
    fn needs_ocr_matches_upstream_pages_needing_ocr() {
        for name in ["classification.pdf", "image.pdf", "sample.pdf"] {
            let doc = PdfDocument::open(fixture(name)).expect("fixture opens");
            let ours: Vec<usize> = (0..doc.page_count().expect("page count"))
                .filter(|&page| needs_ocr(doc.classify_page(page).expect("classifies").kind))
                .collect();

            let upstream = doc.classify_document().expect("classifies");
            assert_eq!(ours, upstream.pages_needing_ocr, "{name}");
        }
    }

    #[test]
    fn upstream_still_reports_an_unreadable_page_as_empty() {
        let doc = PdfDocument::open(fixture("broken_page.pdf")).expect("fixture opens");

        assert!(doc.classify_page(2).is_err());
        let upstream = doc.classify_document().expect("swallows the page");
        assert_eq!(upstream.pages[2], PageKind::Empty);
    }

    #[test]
    fn upstream_still_auto_extracts_plain_text_without_ocr() {
        let doc = PdfDocument::open(fixture("classification.pdf")).expect("fixture opens");

        for page in 0..doc.page_count().expect("page count") {
            let text = doc.extract_text(page).expect("text");
            assert_eq!(doc.extract_text_auto(page).expect("auto text"), text);

            let extraction = AutoExtractor::new()
                .extract_page(&doc, page)
                .expect("auto page");
            assert_eq!(extraction.text, text);
            assert_eq!(extraction.regions.len(), 1);
            assert!(extraction.regions[0].table.is_none());
        }
    }
}
