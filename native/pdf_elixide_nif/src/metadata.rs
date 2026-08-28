use std::collections::HashMap;

use pdf_oxide::{
    encryption::PdfPermissions,
    extractors::{
        page_labels::{PageLabelExtractor, PageLabelRange, PageLabelStyle},
        xmp::{XmpExtractor, XmpMetadata},
    },
    PdfDocument,
};
use rustler::{NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{document::ensure_page_in_range, error::to_nif_err, DocumentResource};

// Document Info dictionary metadata. Every field is optional; a document with
// no `/Info` dictionary yields an all-`nil` map. Dates are the raw PDF date
// strings (e.g. `D:20230101120000+00'00'`); `trapped` is the `/Trapped` name
// (`True` / `False` / `Unknown`) when present.
#[derive(NifMap, Debug)]
pub struct MetadataNif {
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
    keywords: Option<String>,
    creator: Option<String>,
    producer: Option<String>,
    creation_date: Option<String>,
    mod_date: Option<String>,
    trapped: Option<String>,
}

// The shared decoder handles UTF-16, UTF-8 and PDFDocEncoding. Strip PDF 2.0's
// UTF-8 BOM first because the decoder otherwise preserves it as U+FEFF.
// Shared with signature decoding so all PDF text strings follow one path.
pub(crate) fn decode_pdf_text_string(bytes: &[u8]) -> String {
    let body = match bytes {
        [0xEF, 0xBB, 0xBF, rest @ ..] => rest,
        other => other,
    };

    pdf_oxide::optional_content::decode_pdf_text_string(body)
}

// Decode every `/Info` field through one path so `/Producer` and `/Creator` do
// not use a different, UTF-8-unaware helper.
fn read_metadata(doc: &PdfDocument) -> MetadataNif {
    let info = doc
        .trailer()
        .as_dict()
        .and_then(|dict| dict.get("Info"))
        .and_then(|raw| doc.resolve_object(raw).ok());
    let dict = info.as_ref().and_then(|obj| obj.as_dict());

    let get = |key: &str| -> Option<String> {
        let resolved = doc.resolve_object(dict?.get(key)?).ok()?;
        let value = resolved
            .as_string()
            .map(decode_pdf_text_string)
            .or_else(|| resolved.as_name().map(str::to_string))?;
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    };

    MetadataNif {
        title: get("Title"),
        author: get("Author"),
        subject: get("Subject"),
        keywords: get("Keywords"),
        creator: get("Creator"),
        producer: get("Producer"),
        creation_date: get("CreationDate"),
        mod_date: get("ModDate"),
        trapped: get("Trapped"),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_info(resource: ResourceArc<DocumentResource>) -> NifResult<MetadataNif> {
    resource.doc.with_read(|doc| Ok(read_metadata(doc)))
}

// XMP (Extensible Metadata Platform) metadata. Field names drop the upstream
// namespace prefixes (`dc_` / `xmp_` / `pdf_` / `xmp_rights_`); `raw_xml`
// carries the original XMP packet as an escape hatch.
#[derive(NifMap, Debug)]
pub struct XmpMetadataNif {
    title: Option<String>,
    creators: Vec<String>,
    description: Option<String>,
    subjects: Vec<String>,
    language: Option<String>,
    rights: Option<String>,
    format: Option<String>,
    creator_tool: Option<String>,
    create_date: Option<String>,
    modify_date: Option<String>,
    metadata_date: Option<String>,
    producer: Option<String>,
    keywords: Option<String>,
    pdf_version: Option<String>,
    trapped: Option<String>,
    rights_usage_terms: Option<String>,
    rights_marked: Option<bool>,
    rights_web_statement: Option<String>,
    custom: HashMap<String, String>,
    raw_xml: Option<String>,
}

fn xmp_to_nif(xmp: XmpMetadata) -> XmpMetadataNif {
    XmpMetadataNif {
        title: xmp.dc_title,
        creators: xmp.dc_creator,
        description: xmp.dc_description,
        subjects: xmp.dc_subject,
        language: xmp.dc_language,
        rights: xmp.dc_rights,
        format: xmp.dc_format,
        creator_tool: xmp.xmp_creator_tool,
        create_date: xmp.xmp_create_date,
        modify_date: xmp.xmp_modify_date,
        metadata_date: xmp.xmp_metadata_date,
        producer: xmp.pdf_producer,
        keywords: xmp.pdf_keywords,
        pdf_version: xmp.pdf_version,
        trapped: xmp.pdf_trapped,
        rights_usage_terms: xmp.xmp_rights_usage_terms,
        rights_marked: xmp.xmp_rights_marked,
        rights_web_statement: xmp.xmp_rights_web_statement,
        custom: xmp.custom,
        raw_xml: xmp.raw_xml,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_xmp_metadata(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Option<XmpMetadataNif>> {
    resource.doc.with_read(|doc| {
        let xmp = XmpExtractor::extract(doc).map_err(to_nif_err)?;
        Ok(xmp.map(xmp_to_nif))
    })
}

// Decoded `/P` permission flags (ISO 32000-1 §7.6.3.2). Per spec these are
// advisory. `raw` is the pre-decoded two's-complement `/P` integer.
#[derive(NifMap, Debug)]
pub struct PermissionsNif {
    print_low_res: bool,
    modify: bool,
    copy: bool,
    annotate: bool,
    fill_forms: bool,
    accessibility: bool,
    assemble: bool,
    print_high_res: bool,
    raw: i32,
}

fn permissions_to_nif(perms: PdfPermissions) -> PermissionsNif {
    PermissionsNif {
        print_low_res: perms.print_low_res,
        modify: perms.modify,
        copy: perms.copy,
        annotate: perms.annotate,
        fill_forms: perms.fill_forms,
        accessibility: perms.accessibility,
        assemble: perms.assemble,
        print_high_res: perms.print_high_res,
        raw: perms.raw_p,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_permissions(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Option<PermissionsNif>> {
    resource
        .doc
        .with_read(|doc| Ok(doc.permissions().map(permissions_to_nif)))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_labels(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<String>> {
    resource.doc.with_read(|doc| {
        let ranges = PageLabelExtractor::extract(doc).map_err(to_nif_err)?;
        let count = doc.page_count().map_err(to_nif_err)?;
        Ok((0..count)
            .map(|index| PageLabelExtractor::get_label(&ranges, index))
            .collect())
    })
}

// Returns one page's logical page label. Upstream has no single-label accessor
// on `PdfDocument` — `Pdf::page_label` takes `&mut self` and is itself
// `get_label(&self.page_labels()?, page)` — so the label ranges are extracted
// per call, and `document_page_labels` remains the bulk path.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_label(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        // Load-bearing: `get_label` is infallible and falls back to the decimal
        // page number, so an out-of-range index would silently yield a label.
        ensure_page_in_range(doc, page_index)?;

        let ranges = PageLabelExtractor::extract(doc).map_err(to_nif_err)?;
        Ok(PageLabelExtractor::get_label(&ranges, page_index))
    })
}

// A page label range's numbering style. `None` is upstream's spelling for a
// range whose label has no numeric part at all — the prefix alone.
#[derive(NifUnitEnum, Debug)]
enum PageLabelStyleNif {
    Decimal,
    RomanUpper,
    RomanLower,
    AlphaUpper,
    AlphaLower,
    None,
}

#[derive(NifMap, Debug)]
struct PageLabelRangeNif {
    start_page: usize,
    style: PageLabelStyleNif,
    prefix: Option<String>,
    start_value: u32,
}

fn style_to_nif(style: PageLabelStyle) -> PageLabelStyleNif {
    match style {
        PageLabelStyle::Decimal => PageLabelStyleNif::Decimal,
        PageLabelStyle::RomanUpper => PageLabelStyleNif::RomanUpper,
        PageLabelStyle::RomanLower => PageLabelStyleNif::RomanLower,
        PageLabelStyle::AlphaUpper => PageLabelStyleNif::AlphaUpper,
        PageLabelStyle::AlphaLower => PageLabelStyleNif::AlphaLower,
        PageLabelStyle::None => PageLabelStyleNif::None,
    }
}

fn page_label_range_to_nif(range: &PageLabelRange) -> PageLabelRangeNif {
    PageLabelRangeNif {
        start_page: range.start_page,
        style: style_to_nif(range.style),
        prefix: range.prefix.clone(),
        start_value: range.start_value,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_label_ranges(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Vec<PageLabelRangeNif>> {
    resource.doc.with_read(|doc| {
        let ranges = PageLabelExtractor::extract(doc).map_err(to_nif_err)?;
        Ok(ranges.iter().map(page_label_range_to_nif).collect())
    })
}

#[cfg(test)]
mod tests {
    use super::{decode_pdf_text_string as decode, read_metadata, PdfDocument};

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    #[test]
    fn producer_and_creator_still_diverge_from_upstreams_own_accessors() {
        let doc = PdfDocument::open(fixture("metadata_encodings.pdf")).expect("fixture opens");
        let metadata = read_metadata(&doc);

        // Ours decodes both correctly.
        assert_eq!(metadata.creator.as_deref(), Some("Créateur"));
        assert_eq!(metadata.producer.as_deref(), Some("pdf_elixide ✓"));

        // Upstream's accessors do not, which is the whole reason for the local
        // read. Both branches, so a partial fix upstream is still caught.
        assert_ne!(
            doc.document_creator().as_deref(),
            metadata.creator.as_deref(),
            "upstream now decodes BOM-less UTF-8 in /Creator"
        );
        assert_ne!(
            doc.document_producer().as_deref(),
            metadata.producer.as_deref(),
            "upstream now strips the PDF 2.0 BOM from /Producer"
        );
    }

    #[test]
    fn decodes_ascii_unchanged() {
        assert_eq!(decode(b"Test Title"), "Test Title");
        assert_eq!(decode(b""), "");
    }

    #[test]
    fn decodes_pdfdoc_encoding_not_latin1() {
        // 0x80-0x9F are PDFDocEncoding glyphs, not the C1 controls a Latin-1
        // decoder would produce: en dash, right single quote, trademark
        // (ISO 32000-1 Table D.2).
        assert_eq!(
            decode(b"PDFDoc: \x85 \x90 \x92"),
            "PDFDoc: \u{2013} \u{2019} \u{2122}"
        );
    }

    #[test]
    fn decodes_the_latin1_range_as_latin1() {
        assert_eq!(decode(b"caf\xE9, na\xEFve"), "café, naïve");
    }

    #[test]
    fn drops_codes_undefined_in_pdfdoc_encoding() {
        // Upstream's table `filter_map`s, so 0x9F — the one undefined code —
        // disappears rather than becoming U+FFFD.
        assert_eq!(decode(b"a\x9Fb"), "ab");
    }

    #[test]
    fn decodes_utf16be_with_a_bom() {
        assert_eq!(decode(b"\xFE\xFF\x00H\x00i"), "Hi");
        // Surrogate pairs survive: U+1F642.
        assert_eq!(decode(b"\xFE\xFF\xD8\x3D\xDE\x42"), "🙂");
    }

    #[test]
    fn decodes_utf16le_with_a_bom() {
        assert_eq!(decode(b"\xFF\xFEH\x00i\x00"), "Hi");
    }

    #[test]
    fn drops_a_trailing_odd_byte_in_utf16() {
        assert_eq!(decode(b"\xFE\xFF\x00H\x00"), "H");
    }

    #[test]
    fn falls_back_to_lossy_utf8_on_an_unpaired_surrogate() {
        // Record the shared decoder's lossy fallback for an unpaired surrogate.
        assert_eq!(
            decode(b"\xFE\xFF\xD8\x3D\x00A"),
            "\u{FFFD}\u{FFFD}\u{FFFD}=\u{0}A"
        );
    }

    #[test]
    fn strips_the_pdf_2_0_utf8_bom() {
        assert_eq!(decode(b"\xEF\xBB\xBFCaf\xC3\xA9"), "Café");
        // BOM only: empty, so `read_metadata`'s trim-to-`None` rule applies.
        assert_eq!(decode(b"\xEF\xBB\xBF"), "");
    }

    #[test]
    fn decodes_raw_utf8_without_a_bom() {
        assert_eq!(decode(b"Caf\xC3\xA9"), "Café");
    }
}
