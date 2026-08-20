// Optional-content group and ink discovery — the vocabulary the
// `:exclude_layers` and `:exclude_inks` extraction filters accept.

use pdf_oxide::{
    error::{Error, Result},
    optional_content::decode_pdf_text_string,
    PdfDocument,
};
use rustler::{NifMap, NifResult, ResourceArc};

use crate::{document::ensure_page_in_range, error::to_nif_err, DocumentResource};

// Use the filter's PDF text decoder so every listed layer name can also be
// matched by `:exclude_layers`.
fn read_layers(doc: &PdfDocument) -> Result<Vec<String>> {
    let catalog = doc.catalog()?;
    let catalog_dict = catalog
        .as_dict()
        .ok_or_else(|| Error::InvalidPdf("Catalog is not a dictionary".to_string()))?;

    let Some(oc_props) = catalog_dict.get("OCProperties") else {
        return Ok(Vec::new());
    };
    let oc_props = doc.resolve_object(oc_props)?;
    let Some(oc_dict) = oc_props.as_dict() else {
        return Ok(Vec::new());
    };

    let Some(ocgs) = oc_dict.get("OCGs") else {
        return Ok(Vec::new());
    };
    let ocgs = doc.resolve_object(ocgs)?;
    let Some(items) = ocgs.as_array() else {
        return Ok(Vec::new());
    };

    let mut names = Vec::with_capacity(items.len());
    for item in items {
        let Ok(ocg) = doc.resolve_object(item) else {
            continue;
        };
        let Some(name) = ocg.as_dict().and_then(|dict| dict.get("Name")) else {
            continue;
        };

        if let Some(token) = name.as_name() {
            names.push(token.to_string());
        } else if let Some(bytes) = name.as_string() {
            // Raw, *not* `metadata.rs`'s wrapper, which strips a PDF 2.0
            // `EF BB BF` and trims. The matcher does neither, so a name tidied
            // up here would silently stop matching the filter it feeds.
            names.push(decode_pdf_text_string(bytes));
        }
    }
    Ok(names)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_layers(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<String>> {
    resource
        .doc
        .with_read(|doc| read_layers(doc).map_err(to_nif_err))
}

// Decode `deep` here so invalid values follow the common NifMap error contract.
#[derive(NifMap, Debug)]
pub struct InksOptionsNif {
    pub deep: bool,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_inks(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: InksOptionsNif,
) -> NifResult<Vec<String>> {
    resource.doc.with_read(|doc| {
        // Load-bearing: both upstream calls reach `get_page`, which reports a bad
        // index as a generic `InvalidPdf`.
        ensure_page_in_range(doc, page_index)?;

        if options.deep {
            doc.get_page_inks_deep(page_index).map_err(to_nif_err)
        } else {
            doc.get_page_inks(page_index).map_err(to_nif_err)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/../../test/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    #[test]
    fn layers_still_diverge_from_upstreams_get_layers() {
        let doc = PdfDocument::open(fixture("layers_and_inks.pdf")).expect("open");

        let ours = read_layers(&doc).expect("local read");
        assert!(
            ours.contains(&"\u{00DC}-Layer".to_string()),
            "local read lost the UTF-16BE name: {ours:?}"
        );
        assert!(
            ours.contains(&"Calque r\u{00E9}serv\u{00E9}".to_string()),
            "local read lost the PDFDocEncoded name: {ours:?}"
        );

        let upstream = doc.get_layers().expect("upstream read");
        assert!(
            !upstream.contains(&"\u{00DC}-Layer".to_string()),
            "upstream now decodes UTF-16BE OCG names: {upstream:?}"
        );
        assert!(
            !upstream.contains(&"Calque r\u{00E9}serv\u{00E9}".to_string()),
            "upstream now decodes PDFDocEncoded OCG names: {upstream:?}"
        );
    }
}
