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

use crate::{document::ensure_page_in_range, error::to_nif_err, DocumentResource};

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

/// Decodes a PDF text string (ISO 32000-1 §7.9.2.2). The decoding itself is
/// upstream's public `decode_pdf_text_string` — the same one `pdf_oxide` applies
/// to optional-content group names: a `FE FF` / `FF FE` byte-order mark selects
/// UTF-16, a BOM-less buffer that is valid UTF-8 is taken as UTF-8 (non-spec
/// leniency for the many producers that write it), and anything else is
/// PDFDocEncoding — Latin-1 except over `0x80`–`0x9F`, where the PDF glyphs
/// (`0x85` en dash, `0x90` right single quote, `0x92` trademark) sit where the
/// C1 controls would be.
///
/// The one case upstream has no branch for is PDF 2.0's UTF-8 text string
/// (ISO 32000-2 §7.9.2.2), tagged `EF BB BF`: those bytes *are* valid UTF-8, so
/// they decode as text but keep the BOM as a leading U+FEFF, which `str::trim`
/// does not remove (U+FEFF is not `White_Space`). Strip it first.
fn decode_pdf_text_string(bytes: &[u8]) -> String {
    let body = match bytes {
        [0xEF, 0xBB, 0xBF, rest @ ..] => rest,
        other => other,
    };

    pdf_oxide::optional_content::decode_pdf_text_string(body)
}

/// Reads the document Info dictionary into a `MetadataNif`. Every field —
/// `/Producer` and `/Creator` included — is read from the resolved `/Info`
/// dictionary here rather than through `PdfDocument::document_producer` /
/// `document_creator`: those decode with a *different*, private upstream
/// decoder that has no UTF-8 branch, so one struct would otherwise mix two
/// decodings (a `EF BB BF`-tagged `/Producer` arriving as `ï»¿…` mojibake next
/// to a correctly decoded `/Title`). Reading them here also gives them the same
/// `/Name` fallback as `/Trapped`, and resolves `/Info` once instead of thrice.
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

/// Reads the Info dictionary metadata. Missing `/Info` yields an all-`nil` map,
/// not an error.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_info(resource: ResourceArc<DocumentResource>) -> NifResult<MetadataNif> {
    resource.doc.with_read(|doc| Ok(read_metadata(doc)))
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
    resource.doc.with_read(|doc| {
        let xmp = XmpExtractor::extract(doc).map_err(to_nif_err)?;
        Ok(xmp.map(xmp_to_nif))
    })
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
    resource
        .doc
        .with_read(|doc| Ok(doc.permissions().map(permissions_to_nif)))
}

// Page labels ------------------------------------------------------------------------------------

/// Returns one logical page label per page, in page order. Pages outside any
/// declared label range fall back to their decimal page number (upstream
/// behavior).
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

/// Returns one page's logical page label. Upstream has no single-label accessor
/// on `PdfDocument` — `Pdf::page_label` takes `&mut self` and is itself
/// `get_label(&self.page_labels()?, page)` — so the label ranges are extracted
/// per call, and `document_page_labels` remains the bulk path.
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

// Tests ------------------------------------------------------------------------------------------

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

    /// Upstream canary, inverted: this one asserts a *difference*, and it is the
    /// only thing keeping [`read_metadata`]'s reason to exist honest.
    ///
    /// `read_metadata` reads all nine `/Info` fields itself rather than calling
    /// `PdfDocument::document_producer` / `document_creator`, purely because
    /// those two decode through a *private* upstream decoder that has no UTF-8
    /// branch and no `/Name` fallback (`pdf_oxide/src/document.rs`,
    /// `document_info_string`). Mixing the two would put a mojibaked
    /// `/Producer` next to a correctly decoded `/Title` in one `%Metadata{}`.
    ///
    /// Nothing in the binding calls those accessors, so if upstream ever unifies
    /// its two decoders the justification evaporates in silence. A failure here
    /// is therefore *not* a bug — it means the local read may no longer be
    /// earning its keep, and that is a decision to make deliberately.
    ///
    /// `metadata_encodings.pdf` provides both branches upstream lacks:
    /// `/Creator` is raw UTF-8 with no BOM, `/Producer` carries PDF 2.0's
    /// `EF BB BF`. The exact mojibake is not asserted — only that it differs —
    /// so the canary reports the change without pinning upstream's spelling of
    /// being wrong.
    ///
    /// Only the decoder half is checked here. The `/Name` fallback is the other
    /// half of the same divergence, but no fixture gives `/Producer` or
    /// `/Creator` a name value, and those are the only two fields reachable
    /// through the upstream accessors — so there is nothing to compare against.
    /// `document_test.exs` covers the fallback itself, over `/Trapped`.
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
        // Upstream's fallback, pinned rather than endorsed: strict `from_utf16`
        // fails and the *whole* buffer, BOM included, is then decoded lossily as
        // UTF-8. This is worse than the `from_utf16_lossy` this binding used to
        // do itself, and is the accepted price of having a single decoder. A
        // future upstream `from_utf16_lossy` would be an improvement — update
        // this assertion then, don't route around it.
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
