use std::collections::HashMap;

use pdf_oxide::{
    editor::DocumentInfo,
    encryption::PdfPermissions,
    extractors::{
        page_labels::{PageLabelExtractor, PageLabelRange, PageLabelStyle},
        xmp::{XmpExtractor, XmpMetadata},
    },
    PdfDocument,
};
use rustler::{NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
    page_label::{self, TooLong, MAX_LETTERED},
    pages::ensure_page_in_range,
    resource::DocumentResource,
    text_string::{decode_pdf_text_string, encode_pdf_text_string},
};

// Shared by document reads and the editor's pending `/Info` values.
#[derive(NifMap, Debug, Clone)]
pub(crate) struct MetadataNif {
    pub(crate) title: Option<String>,
    pub(crate) author: Option<String>,
    pub(crate) subject: Option<String>,
    pub(crate) keywords: Option<String>,
    pub(crate) creator: Option<String>,
    pub(crate) producer: Option<String>,
    pub(crate) creation_date: Option<String>,
    pub(crate) mod_date: Option<String>,
    pub(crate) trapped: Option<String>,
}

impl MetadataNif {
    // Every field absent. Mirrors what upstream's sanitizer leaves behind, so
    // `editor_info` reports the scrub and `resupply_info` does not undo it.
    pub(crate) fn scrubbed() -> Self {
        Self {
            title: None,
            author: None,
            subject: None,
            keywords: None,
            creator: None,
            producer: None,
            creation_date: None,
            mod_date: None,
            trapped: None,
        }
    }
}

// Whitespace-only reads as absent, on the document and on the editor alike.
pub(crate) fn normalize_text(value: Option<String>) -> Option<String> {
    let value = value?;
    let trimmed = value.trim();

    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

// The fields upstream's struct has; `/Trapped` has no slot and is dropped
// by any write that emits `/Info`. Dates are ASCII-checked before they get
// here, so the encoder's BOM branch never touches one.
pub(crate) fn to_document_info(info: &MetadataNif) -> DocumentInfo {
    let encode = |value: &Option<String>| value.as_deref().map(encode_pdf_text_string);

    DocumentInfo {
        title: encode(&info.title),
        author: encode(&info.author),
        subject: encode(&info.subject),
        keywords: encode(&info.keywords),
        creator: encode(&info.creator),
        producer: encode(&info.producer),
        creation_date: encode(&info.creation_date),
        mod_date: encode(&info.mod_date),
    }
}

// Whether a write would emit anything: `/Trapped` alone does not count.
pub(crate) fn has_info_text(info: &MetadataNif) -> bool {
    [
        &info.title,
        &info.author,
        &info.subject,
        &info.keywords,
        &info.creator,
        &info.producer,
        &info.creation_date,
        &info.mod_date,
    ]
    .into_iter()
    .any(Option::is_some)
}

// Decode every `/Info` field through one path so `/Producer` and `/Creator` do
// not use a different, UTF-8-unaware helper.
pub(crate) fn read_metadata(doc: &PdfDocument) -> MetadataNif {
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
            .or_else(|| resolved.as_name().map(str::to_string));

        normalize_text(value)
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
        (0..count)
            .map(|index| page_label::label(&ranges, index).map_err(too_long))
            .collect()
    })
}

fn too_long(TooLong { page }: TooLong) -> rustler::Error {
    tagged_err(
        atoms::unsupported(),
        format!(
            "the label of page {page} counts past {MAX_LETTERED} in letters, which would take \
             over 1000 of them; this library reads labels in letters up to {MAX_LETTERED}"
        ),
    )
}

// Extracts the label ranges per call; `document_page_labels` is the bulk path.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_label(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        // Load-bearing: a label falls back to the decimal page number, so an
        // out-of-range index would silently yield one.
        ensure_page_in_range(doc, page_index)?;

        let ranges = PageLabelExtractor::extract(doc).map_err(to_nif_err)?;
        page_label::label(&ranges, page_index).map_err(too_long)
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
    use super::{
        has_info_text, normalize_text, read_metadata, to_document_info, MetadataNif, PdfDocument,
    };

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
    fn to_document_info_encodes_every_field_and_drops_trapped() {
        let info = MetadataNif {
            title: Some("Título".into()),
            author: Some("Jane".into()),
            subject: None,
            keywords: Some("a, b".into()),
            creator: Some("Créateur".into()),
            producer: Some("pdf_elixide ✓".into()),
            creation_date: Some("D:20240115120000Z".into()),
            mod_date: None,
            trapped: Some("True".into()),
        };

        let document_info = to_document_info(&info);

        assert_eq!(document_info.title.as_deref(), Some("\u{FEFF}Título"));
        assert_eq!(document_info.author.as_deref(), Some("Jane"));
        assert_eq!(document_info.subject, None);
        assert_eq!(document_info.keywords.as_deref(), Some("a, b"));
        assert_eq!(document_info.creator.as_deref(), Some("\u{FEFF}Créateur"));
        assert_eq!(
            document_info.producer.as_deref(),
            Some("\u{FEFF}pdf_elixide ✓")
        );
        assert_eq!(
            document_info.creation_date.as_deref(),
            Some("D:20240115120000Z")
        );
        assert_eq!(document_info.mod_date, None);
        assert!(!document_info
            .to_object()
            .as_dict()
            .unwrap()
            .contains_key("Trapped"));
    }

    #[test]
    fn has_info_text_ignores_trapped() {
        let empty = MetadataNif {
            title: None,
            author: None,
            subject: None,
            keywords: None,
            creator: None,
            producer: None,
            creation_date: None,
            mod_date: None,
            trapped: Some("True".into()),
        };
        assert!(!has_info_text(&empty));

        let dated = MetadataNif {
            mod_date: Some("D:2024".into()),
            trapped: None,
            ..empty
        };
        assert!(has_info_text(&dated));
    }

    #[test]
    fn normalize_text_maps_whitespace_to_none() {
        assert_eq!(normalize_text(None), None);
        assert_eq!(normalize_text(Some("   ".into())), None);
        assert_eq!(normalize_text(Some("".into())), None);
        assert_eq!(normalize_text(Some("  x ".into())), Some("x".into()));
    }
}
