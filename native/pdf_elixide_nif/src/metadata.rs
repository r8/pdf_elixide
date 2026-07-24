use std::collections::HashMap;

use pdf_oxide::{
    encryption::PdfPermissions,
    extractors::{
        page_labels::PageLabelExtractor,
        xmp::{XmpExtractor, XmpMetadata},
    },
    PdfDocument,
};
use rustler::{NifMap, NifResult, ResourceArc};

use crate::{
    error::{lock_err, to_nif_err},
    DocumentResource,
};

// Info dictionary --------------------------------------------------------------------------------

/// Document Info dictionary metadata. Every field is optional; a document with
/// no `/Info` dictionary yields an all-`nil` map. Dates are the raw PDF date
/// strings (e.g. `D:20230101120000+00'00'`); `trapped` is the `/Trapped` name
/// (`True` / `False` / `Unknown`) when present.
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

/// Decodes a PDF text string (ISO 32000-1 §7.9.2.2). A leading UTF-16 byte-order
/// mark selects UTF-16; otherwise the bytes are treated as PDFDocEncoding, which
/// coincides with Latin-1 across the range used by real-world Info strings.
fn decode_pdf_text_string(bytes: &[u8]) -> String {
    match bytes {
        [0xFE, 0xFF, rest @ ..] => {
            let units: Vec<u16> = rest
                .chunks_exact(2)
                .map(|c| u16::from_be_bytes([c[0], c[1]]))
                .collect();
            String::from_utf16_lossy(&units)
        }
        [0xFF, 0xFE, rest @ ..] => {
            let units: Vec<u16> = rest
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();
            String::from_utf16_lossy(&units)
        }
        _ => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// Reads the document Info dictionary into a `MetadataNif`. `/Producer` and
/// `/Creator` reuse pdf_oxide's own decoders; the rest are read directly from
/// the resolved `/Info` dictionary (only those two have public accessors).
fn read_metadata(doc: &PdfDocument) -> MetadataNif {
    let producer = doc.document_producer();
    let creator = doc.document_creator();

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
        creator,
        producer,
        creation_date: get("CreationDate"),
        mod_date: get("ModDate"),
        trapped: get("Trapped"),
    }
}

/// Reads the Info dictionary metadata. Missing `/Info` yields an all-`nil` map,
/// not an error.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_info(resource: ResourceArc<DocumentResource>) -> NifResult<MetadataNif> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(read_metadata(&doc))
}

// XMP metadata -----------------------------------------------------------------------------------

/// XMP (Extensible Metadata Platform) metadata. Field names drop the upstream
/// namespace prefixes (`dc_` / `xmp_` / `pdf_` / `xmp_rights_`); `raw_xml`
/// carries the original XMP packet as an escape hatch.
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

/// Extracts XMP metadata. Returns `nil` when the document carries no XMP packet.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_xmp_metadata(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Option<XmpMetadataNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let xmp = XmpExtractor::extract(&doc).map_err(to_nif_err)?;
    Ok(xmp.map(xmp_to_nif))
}

// Permissions ------------------------------------------------------------------------------------

/// Decoded `/P` permission flags (ISO 32000-1 §7.6.3.2). Per spec these are
/// advisory. `raw` is the pre-decoded two's-complement `/P` integer.
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

/// Returns the document's permission flags, or `nil` when the document is not
/// encrypted (no permission dictionary).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_permissions(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Option<PermissionsNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.permissions().map(permissions_to_nif))
}

// Page labels ------------------------------------------------------------------------------------

/// Returns one logical page label per page, in page order. Pages outside any
/// declared label range fall back to their decimal page number (upstream
/// behavior).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_labels(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<String>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let ranges = PageLabelExtractor::extract(&doc).map_err(to_nif_err)?;
    let count = doc.page_count().map_err(to_nif_err)?;
    Ok((0..count)
        .map(|index| PageLabelExtractor::get_label(&ranges, index))
        .collect())
}
