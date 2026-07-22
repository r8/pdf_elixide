use std::sync::Mutex;

use pdf_oxide::{extractors::forms::FormExtractor, PdfDocument};
use rustler::{Binary, NifMap, NifResult, ResourceArc};

use crate::{
    atoms,
    char::{char_to_nif, CharNif},
    error::{lock_err, tagged_err, to_nif_err},
    form::{document_form_field_to_nif, FieldNif},
    paths::{path_to_nif, PathNif},
    span::{span_to_nif, SpanNif},
    table::{table_to_nif, TableNif},
    text_line::{text_line_to_nif, TextLineNif},
    word::{word_to_nif, WordNif},
    DocumentResource,
};

#[derive(NifMap, Debug)]
pub struct OpenOptionsNif {
    pub password: Option<String>,
}

impl OpenOptionsNif {
    fn apply(self, doc: &PdfDocument) -> NifResult<()> {
        if let Some(pw) = self.password {
            let ok = doc.authenticate(pw.as_bytes()).map_err(to_nif_err)?;
            if !ok {
                return Err(tagged_err(
                    atoms::wrong_password(),
                    "Authentication failed: wrong password",
                ));
            }
        }
        Ok(())
    }
}

/// Returns an `:out_of_range` error if `page_index` is not a valid page of
/// `doc`. Upstream reports a bad index as a generic `InvalidPdf`, so we check
/// bounds here to give callers a distinct, matchable reason.
fn ensure_page_in_range(doc: &PdfDocument, page_index: usize) -> NifResult<()> {
    let count = doc.page_count().map_err(to_nif_err)?;
    if page_index >= count {
        return Err(tagged_err(
            atoms::out_of_range(),
            format!("Page index {page_index} out of range (document has {count} pages)"),
        ));
    }
    Ok(())
}

/// Opens a PDF document from the specified file path.
#[rustler::nif(schedule = "DirtyIo")]
fn document_open(
    path: String,
    options: OpenOptionsNif,
) -> NifResult<ResourceArc<DocumentResource>> {
    let doc = PdfDocument::open(path).map_err(to_nif_err)?;
    options.apply(&doc)?;

    Ok(ResourceArc::new(DocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Opens a PDF document from the given binary data.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_from_bytes(
    bytes: Binary,
    options: OpenOptionsNif,
) -> NifResult<ResourceArc<DocumentResource>> {
    let doc = PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;
    options.apply(&doc)?;

    Ok(ResourceArc::new(DocumentResource {
        doc: Mutex::new(doc),
    }))
}

/// Returns the number of pages in the PDF document.
#[rustler::nif]
fn document_page_count(resource: ResourceArc<DocumentResource>) -> NifResult<usize> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.page_count().map_err(to_nif_err)?)
}

/// Returns the PDF specification version as a `(major, minor)` tuple.
#[rustler::nif]
fn document_version(resource: ResourceArc<DocumentResource>) -> NifResult<(u8, u8)> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.version())
}

/// Returns whether the PDF document has a structure tree (i.e. is a Tagged PDF).
/// Any error or missing tree is reported as `false`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_has_structure_tree(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.structure_tree().ok().flatten().is_some())
}

/// Returns whether the PDF document is encrypted.
#[rustler::nif]
fn document_is_encrypted(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    Ok(doc.is_encrypted())
}

/// Authenticates against the document's encryption with the given password.
/// Returns `Ok(true)` on success (or if the PDF is not encrypted),
/// `Ok(false)` if the password was invalid.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_authenticate(
    resource: ResourceArc<DocumentResource>,
    password: Binary,
) -> NifResult<bool> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    doc.authenticate(password.as_slice()).map_err(to_nif_err)
}

/// Extracts text content from a single page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_text(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<String> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    doc.extract_text(page_index).map_err(to_nif_err)
}

/// Extracts text content from all pages, separated by form-feed characters.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_all_text(resource: ResourceArc<DocumentResource>) -> NifResult<String> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    doc.extract_all_text().map_err(to_nif_err)
}

/// Extracts words (with bounding boxes) from a single page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_words(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<WordNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    let words = doc.extract_words(page_index).map_err(to_nif_err)?;
    Ok(words
        .into_iter()
        .map(|word| word_to_nif(word, page_index))
        .collect())
}

/// Extracts words (with bounding boxes) from all pages, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_words(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<WordNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let count = doc.page_count().map_err(to_nif_err)?;
    let mut words = Vec::new();
    for page_index in 0..count {
        let page_words = doc.extract_words(page_index).map_err(to_nif_err)?;
        words.extend(
            page_words
                .into_iter()
                .map(|word| word_to_nif(word, page_index)),
        );
    }
    Ok(words)
}

/// Extracts text lines (each with its words) from a single page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_text_lines(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<TextLineNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    let lines = doc.extract_text_lines(page_index).map_err(to_nif_err)?;
    Ok(lines
        .into_iter()
        .map(|line| text_line_to_nif(line, page_index))
        .collect())
}

/// Extracts text lines (each with its words) from all pages, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_text_lines(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<TextLineNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let count = doc.page_count().map_err(to_nif_err)?;
    let mut lines = Vec::new();
    for page_index in 0..count {
        let page_lines = doc.extract_text_lines(page_index).map_err(to_nif_err)?;
        lines.extend(
            page_lines
                .into_iter()
                .map(|line| text_line_to_nif(line, page_index)),
        );
    }
    Ok(lines)
}

/// Extracts characters (with bounding boxes and font metadata) from a single
/// page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_chars(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<CharNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    let chars = doc.extract_chars(page_index).map_err(to_nif_err)?;
    Ok(chars
        .into_iter()
        .map(|ch| char_to_nif(ch, page_index))
        .collect())
}

/// Extracts characters (with bounding boxes and font metadata) from all pages,
/// in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_chars(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<CharNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let count = doc.page_count().map_err(to_nif_err)?;
    let mut chars = Vec::new();
    for page_index in 0..count {
        let page_chars = doc.extract_chars(page_index).map_err(to_nif_err)?;
        chars.extend(page_chars.into_iter().map(|ch| char_to_nif(ch, page_index)));
    }
    Ok(chars)
}

/// Extracts spans (runs of text sharing one text state) from a single page
/// (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_spans(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<SpanNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    let spans = doc.extract_spans(page_index).map_err(to_nif_err)?;
    Ok(spans
        .into_iter()
        .map(|span| span_to_nif(span, page_index))
        .collect())
}

/// Extracts spans (runs of text sharing one text state) from all pages, in
/// page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_spans(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<SpanNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let count = doc.page_count().map_err(to_nif_err)?;
    let mut spans = Vec::new();
    for page_index in 0..count {
        let page_spans = doc.extract_spans(page_index).map_err(to_nif_err)?;
        spans.extend(
            page_spans
                .into_iter()
                .map(|span| span_to_nif(span, page_index)),
        );
    }
    Ok(spans)
}

/// Extracts vector paths (lines, curves, rectangles, shapes) from a single page
/// (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_paths(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<PathNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    let paths = doc.extract_paths(page_index).map_err(to_nif_err)?;
    Ok(paths
        .into_iter()
        .map(|path| path_to_nif(path, page_index))
        .collect())
}

/// Extracts vector paths from all pages, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_paths(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<PathNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let count = doc.page_count().map_err(to_nif_err)?;
    let mut paths = Vec::new();
    for page_index in 0..count {
        let page_paths = doc.extract_paths(page_index).map_err(to_nif_err)?;
        paths.extend(
            page_paths
                .into_iter()
                .map(|path| path_to_nif(path, page_index)),
        );
    }
    Ok(paths)
}

/// Detects tables on a single page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_tables(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<TableNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;
    ensure_page_in_range(&doc, page_index)?;

    let tables = doc.extract_tables(page_index).map_err(to_nif_err)?;
    Ok(tables
        .into_iter()
        .map(|table| table_to_nif(table, page_index))
        .collect())
}

/// Detects tables on all pages, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_tables(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<TableNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let count = doc.page_count().map_err(to_nif_err)?;
    let mut tables = Vec::new();
    for page_index in 0..count {
        let page_tables = doc.extract_tables(page_index).map_err(to_nif_err)?;
        tables.extend(
            page_tables
                .into_iter()
                .map(|table| table_to_nif(table, page_index)),
        );
    }
    Ok(tables)
}

/// Returns the page's width in points (MediaBox urx - llx).
#[rustler::nif]
fn document_get_page_width(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<f32> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    ensure_page_in_range(&doc, page_index)?;

    let (llx, _lly, urx, _ury) = doc.get_page_media_box(page_index).map_err(to_nif_err)?;
    Ok(urx - llx)
}

/// Returns the page's height in points (MediaBox ury - lly).
#[rustler::nif]
fn document_get_page_height(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<f32> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    ensure_page_in_range(&doc, page_index)?;

    let (_llx, lly, _urx, ury) = doc.get_page_media_box(page_index).map_err(to_nif_err)?;
    Ok(ury - lly)
}

/// Extracts form fields from the PDF document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_form_fields(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<FieldNif>> {
    let doc = resource.doc.lock().map_err(|_| lock_err())?;

    let fields = FormExtractor::extract_fields(&doc).map_err(to_nif_err)?;
    Ok(fields.into_iter().map(document_form_field_to_nif).collect())
}
