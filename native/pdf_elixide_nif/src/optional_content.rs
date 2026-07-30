//! Optional-content group and ink discovery — the vocabulary the
//! `:exclude_layers` and `:exclude_inks` extraction filters accept.

use pdf_oxide::{
    error::{Error, Result},
    optional_content::decode_pdf_text_string,
    PdfDocument,
};
use rustler::{NifMap, NifResult, ResourceArc};

use crate::{document::ensure_page_in_range, error::to_nif_err, DocumentResource};

// Layers -----------------------------------------------------------------------------------------

/// Reads the catalog's optional-content group names.
///
/// Deliberately **not** `PdfDocument::get_layers`, which is otherwise identical:
/// upstream decodes a string-valued `/Name` with strict `String::from_utf8` and
/// skips what fails, dropping every UTF-16 and PDFDocEncoded name — while the
/// matcher this list feeds, `optional_content::ocg_name_is_excluded`, decodes the
/// same bytes with `decode_pdf_text_string` and *would* have matched them.
/// Binding upstream would ship a vocabulary the filter does not share. Every
/// other branch mirrors upstream, leaving the decoder as the single divergence.
///
/// Returns upstream's `Result` rather than a `NifResult` so it stays callable
/// from `cargo test`, where building the atom a `to_nif_err` carries would abort
/// the process instead of failing the test.
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

/// Lists the optional-content group names the document catalog declares, in
/// `/OCGs` order. Neither sorted nor deduplicated, and `[]` for a document with
/// no optional content.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_layers(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<String>> {
    resource
        .doc
        .with_read(|doc| read_layers(doc).map_err(to_nif_err))
}

// Inks -------------------------------------------------------------------------------------------

/// Options for `PdfElixide.Document.inks/2,3`.
///
/// `deep` selects between two upstream calls rather than configuring one, and it
/// is decoded here rather than branched on in Elixir so a non-boolean value is
/// rejected by the `NifMap` decoder — the single authority on option types —
/// and reaches the caller as an `ArgumentError` naming the key, uniform with
/// every other bad option value.
#[derive(NifMap, Debug)]
pub struct InksOptionsNif {
    pub deep: bool,
}

/// Lists the Separation / DeviceN ink names a page declares, sorted and
/// deduplicated by upstream. `deep` also walks `Do` into Form XObject resources.
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

    /// Upstream canary, inverted: it asserts the *difference* [`read_layers`]
    /// documents, and is the only thing keeping that function's reason to exist
    /// honest — nothing in the binding calls `get_layers`, so upstream adopting
    /// the lenient decoder would retire the local read in silence. A failure is
    /// therefore not a bug but a decision to make deliberately.
    ///
    /// The two names upstream cannot reach are asserted separately, so a partial
    /// fix still fails.
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
