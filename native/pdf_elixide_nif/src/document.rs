use std::collections::HashSet;

use pdf_oxide::{
    converters::{BoldMarkerBehavior, ConversionOptions},
    error::{Error, Result},
    layout::{LayoutObjectSpatial, SpatialCollectionFiltering},
    object::Object,
    search::{SearchOptions, TextSearcher},
    PdfDocument,
};
use rustler::{Atom, Binary, NifMap, NifResult, NifUnitEnum, OwnedBinary, ResourceArc};

use crate::{
    annotations::{annotation_to_nif, AnnotationNif},
    atoms,
    binary::owned_binary,
    char::{char_to_nif, CharNif},
    error::{tagged_err, to_nif_err, to_nif_page_err, to_search_err},
    extract_options::{
        CharsOptions, CharsOptionsNif, LinesOptions, LinesOptionsNif, OnPageErrorNif,
        ReadingOrderNif, RegionFilter, SearchOptionsNif, SearchRequest, SpansOptions,
        SpansOptionsNif, TableDetectionNif, TablesOptions, TablesOptionsNif, TextOptions,
        TextOptionsNif, WordsOptions, WordsOptionsNif,
    },
    fonts::{extract_page_fonts, FontNif},
    form::{document_form_field_to_nif, export_bytes, is_exportable, FieldNif, FormDataFormatNif},
    form_tree,
    fs_path::path_arg,
    geometry::{rect_from_corners, RectNif},
    images::{image_to_nif, ImageNif},
    outline::{outline_to_nif, OutlineItemNif},
    paths::{path_to_nif, PathNif},
    resource::Closable,
    search::{search_match_to_nif, SearchMatchNif},
    span::{span_to_nif, SpanNif},
    table::{table_to_nif, TableNif},
    text_line::{text_line_to_nif, TextLineNif},
    warnings::{self, OpenDocument, WarningNif},
    word::{word_to_nif, WordNif},
    DocumentResource,
};

// PDF passwords are raw bytes and may not be valid UTF-8. Do not derive `Debug`
// for a type that contains one.
#[derive(NifMap)]
pub struct OpenOptionsNif<'a> {
    pub password: Option<Binary<'a>>,
}

impl OpenOptionsNif<'_> {
    // A rejected password is `Ok(false)`, so synthesize the reason atom here.
    fn apply(self, doc: &PdfDocument) -> NifResult<()> {
        if let Some(pw) = self.password {
            let ok = doc.authenticate(pw.as_slice()).map_err(to_nif_err)?;
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

#[derive(NifUnitEnum, Debug)]
pub enum BoldMarkersNif {
    Conservative,
    Aggressive,
}

impl From<BoldMarkersNif> for BoldMarkerBehavior {
    fn from(markers: BoldMarkersNif) -> Self {
        match markers {
            BoldMarkersNif::Conservative => BoldMarkerBehavior::Conservative,
            BoldMarkersNif::Aggressive => BoldMarkerBehavior::Aggressive,
        }
    }
}

// Create the directory up front because the converter otherwise hides write
// failures and returns successful output with the image reference missing.
fn ensure_image_output_dir(
    include_images: bool,
    embed_images: bool,
    image_output_dir: Option<&str>,
) -> NifResult<()> {
    if !include_images || embed_images {
        return Ok(());
    }

    let Some(dir) = image_output_dir else {
        return Ok(());
    };

    std::fs::create_dir_all(dir).map_err(|e| {
        tagged_err(
            atoms::io(),
            format!("Failed to create image output directory {dir}: {e}"),
        )
    })
}

// The subset of `ConversionOptions` exposed to Elixir. Every remaining field
// stays at its upstream default (see the `From` impl below).
#[derive(NifMap, Debug)]
pub struct MarkdownOptionsNif {
    pub detect_headings: bool,
    pub extract_tables: bool,
    pub include_images: bool,
    pub embed_images: bool,
    pub image_output_dir: Option<String>,
    pub include_form_fields: bool,
    pub strip_running_headers_footers: bool,
    pub expand_ligatures: bool,
    pub max_image_pixels: Option<u64>,
    pub reading_order: ReadingOrderNif,
    pub bold_markers: BoldMarkersNif,
}

impl MarkdownOptionsNif {
    fn ensure_image_output_dir(&self) -> NifResult<()> {
        ensure_image_output_dir(
            self.include_images,
            self.embed_images,
            self.image_output_dir.as_deref(),
        )
    }
}

impl From<MarkdownOptionsNif> for ConversionOptions {
    fn from(o: MarkdownOptionsNif) -> Self {
        ConversionOptions {
            detect_headings: o.detect_headings,
            extract_tables: o.extract_tables,
            include_images: o.include_images,
            embed_images: o.embed_images,
            image_output_dir: o.image_output_dir,
            include_form_fields: o.include_form_fields,
            strip_running_headers_footers: o.strip_running_headers_footers,
            expand_ligatures: o.expand_ligatures,
            max_image_pixels: o.max_image_pixels,
            reading_order_mode: o.reading_order.into(),
            bold_marker_behavior: o.bold_markers.into(),
            ..Default::default()
        }
    }
}

// Only options used by HTML conversion cross this boundary.
#[derive(NifMap, Debug)]
pub struct HtmlOptionsNif {
    pub preserve_layout: bool,
    pub detect_headings: bool,
    pub extract_tables: bool,
    pub include_images: bool,
    pub embed_images: bool,
    pub image_output_dir: Option<String>,
    pub include_form_fields: bool,
    pub max_image_pixels: Option<u64>,
    pub reading_order: ReadingOrderNif,
}

impl HtmlOptionsNif {
    fn ensure_image_output_dir(&self) -> NifResult<()> {
        ensure_image_output_dir(
            self.include_images,
            self.embed_images,
            self.image_output_dir.as_deref(),
        )
    }
}

impl From<HtmlOptionsNif> for ConversionOptions {
    fn from(o: HtmlOptionsNif) -> Self {
        ConversionOptions {
            preserve_layout: o.preserve_layout,
            detect_headings: o.detect_headings,
            extract_tables: o.extract_tables,
            include_images: o.include_images,
            embed_images: o.embed_images,
            image_output_dir: o.image_output_dir,
            include_form_fields: o.include_form_fields,
            max_image_pixels: o.max_image_pixels,
            reading_order_mode: o.reading_order.into(),
            ..Default::default()
        }
    }
}

// Only options the plain-text conversion reads cross this boundary.
#[derive(NifMap, Debug)]
pub struct PlainTextOptionsNif {
    pub extract_tables: bool,
    pub table_detection: Option<TableDetectionNif>,
    pub reading_order: ReadingOrderNif,
    pub include_form_fields: bool,
}

impl From<PlainTextOptionsNif> for ConversionOptions {
    fn from(o: PlainTextOptionsNif) -> Self {
        ConversionOptions {
            extract_tables: o.extract_tables,
            table_detection_config: o.table_detection.map(Into::into),
            include_form_fields: o.include_form_fields,
            reading_order_mode: o.reading_order.into(),
            ..Default::default()
        }
    }
}

// Returns an `:out_of_range` error if `page_index` is not a valid page of
// `doc`. Upstream reports a bad index as a generic `InvalidPdf`, so we check
// bounds here to give callers a distinct, matchable reason.
pub fn ensure_page_in_range(doc: &PdfDocument, page_index: usize) -> NifResult<()> {
    let count = doc.page_count().map_err(to_nif_err)?;
    if page_index >= count {
        return Err(tagged_err(
            atoms::out_of_range(),
            format!("Page index {page_index} out of range (document has {count} pages)"),
        ));
    }
    Ok(())
}

// Return the handle and cached fields atomically so no opened resource can be
// stranded by a later accessor failure.
type OpenedDocument = (ResourceArc<DocumentResource>, (u8, u8), Option<usize>);

// Read through `Closable` after authentication so panic containment applies and
// an encrypted page tree becomes readable. An unreadable count is intentionally
// `None`; Elixir falls back to a live call after later authentication.
fn cached_fields(resource: &DocumentResource) -> NifResult<((u8, u8), Option<usize>)> {
    let version = resource.doc.with_read(|doc| Ok(doc.version()))?;
    let page_count = resource
        .doc
        .with_read(|doc| Ok(doc.page_count().ok()))
        .ok()
        .flatten();

    Ok((version, page_count))
}

#[rustler::nif(schedule = "DirtyIo")]
fn document_open(path: Binary, options: OpenOptionsNif<'_>) -> NifResult<OpenedDocument> {
    let path = path_arg(path)?;
    let doc = warnings::drained(|| {
        let doc = PdfDocument::open(path).map_err(to_nif_err)?;
        options.apply(&doc)?;

        Ok(doc)
    })?;

    let resource = ResourceArc::new(DocumentResource {
        doc: Closable::with_hook("Document", OpenDocument::new(doc), OpenDocument::drain),
    });
    let (version, page_count) = cached_fields(&resource)?;

    Ok((resource, version, page_count))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_from_bytes(bytes: Binary, options: OpenOptionsNif<'_>) -> NifResult<OpenedDocument> {
    let doc = warnings::drained(|| {
        let doc = PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;
        options.apply(&doc)?;

        Ok(doc)
    })?;

    let resource = ResourceArc::new(DocumentResource {
        doc: Closable::with_hook("Document", OpenDocument::new(doc), OpenDocument::drain),
    });
    let (version, page_count) = cached_fields(&resource)?;

    Ok((resource, version, page_count))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_close(resource: ResourceArc<DocumentResource>) -> Atom {
    resource.doc.close();

    atoms::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_closed(resource: ResourceArc<DocumentResource>) -> bool {
    resource.doc.is_closed()
}

// Dirty because this shared read can wait behind a long exclusive operation.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_count(resource: ResourceArc<DocumentResource>) -> NifResult<usize> {
    resource
        .doc
        .with_read(|doc| doc.page_count().map_err(to_nif_err))
}

// Keep absent and unparseable structure trees distinct; Elixir chooses whether
// to degrade an error to `false`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_has_structure_tree(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    resource
        .doc
        .with_read(|doc| Ok(doc.structure_tree().map_err(to_nif_err)?.is_some()))
}

// Transcribe `XfaExtractor::has_xfa` against `&PdfDocument`; its `&mut` receiver
// is vestigial and would unnecessarily serialize this predicate.
fn has_xfa(doc: &PdfDocument) -> Result<bool> {
    let catalog = doc.catalog()?;
    let Some(catalog_dict) = catalog.as_dict() else {
        return Ok(false);
    };

    let acroform = match catalog_dict.get("AcroForm") {
        Some(obj) => match obj.as_reference() {
            Some(reference) => doc.load_object(reference)?,
            None => obj.clone(),
        },
        None => return Ok(false),
    };

    Ok(acroform.as_dict().is_some_and(|d| d.contains_key("XFA")))
}

// Keep structural absence (`false`) distinct from an unreadable catalog (`Err`).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_has_xfa(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    resource
        .doc
        .with_read(|doc| has_xfa(doc).map_err(to_nif_err))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_is_encrypted(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    resource.doc.with_read(|doc| Ok(doc.is_encrypted()))
}

// Exclusive because the first successful authentication replaces the whole
// document and no concurrent reader may straddle that swap.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_authenticate(
    resource: ResourceArc<DocumentResource>,
    password: Binary,
) -> NifResult<bool> {
    resource.doc.with_lock(|doc| {
        // Not encrypted, or already authenticated: nothing can have been cached
        // from an undecryptable read, so authenticate in place.
        if doc.is_authenticated() {
            return doc.authenticate(password.as_slice()).map_err(to_nif_err);
        }

        // Upstream's `authenticate` clears only its object cache, so the empty
        // results cached by every pre-auth read would be served for the life of
        // the handle; two of those caches have no clear site at all. Rebuilding
        // drops them. The fresh document is authenticated *before* the swap, so
        // a failure leaves the handle exactly as it was.
        let fresh = PdfDocument::from_bytes(doc.source_bytes.clone()).map_err(to_nif_err)?;
        let result = fresh.authenticate(password.as_slice());

        // Preserve old-then-new warning order, including failed authentication;
        // absorb before `?` can discard the fresh document.
        doc.warnings.absorb(|| doc.doc.take_structured_warnings());
        doc.warnings.absorb(|| fresh.take_structured_warnings());

        let ok = result.map_err(to_nif_err)?;
        if ok {
            doc.doc = fresh;
            // Cached runs belong to the document just discarded.
            doc.search_runs.clear();
        }

        Ok(ok)
    })
}

// The mirror lock makes collection atomic across shared handle readers.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_structured_warnings(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<(Vec<WarningNif>, usize)> {
    resource.doc.with_read(|doc| {
        let (collected, dropped) = doc.warnings.collect(|| doc.doc.take_structured_warnings());

        Ok((warnings::to_nif(collected), dropped))
    })
}

// This route drops every setting but the region; Elixir refuses a non-default
// sibling before the call reaches here, so the fallback is never observable.
fn extract_text_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &TextOptions,
) -> Result<String> {
    if options.filtered() {
        let layers: HashSet<String> = options.exclude_layers.iter().cloned().collect();
        let inks: HashSet<String> = options.exclude_inks.iter().cloned().collect();
        return match &options.region {
            Some(RegionFilter { rect, mode }) => {
                doc.extract_text_filtered_in_rect(page_index, layers, inks, *rect, *mode)
            }
            None => doc.extract_text_filtered(page_index, layers, inks),
        };
    }

    doc.extract_text_with_options(page_index, &options.conversion)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_text(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: TextOptionsNif,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        options.validate()?;

        extract_text_page(doc, page_index, &options.into()).map_err(to_nif_err)
    })
}

// Insert the form feed before extraction so a skipped page still leaves an
// empty slot. Any non-empty document then splits into `page_count` parts.
fn extract_all_text_pages(doc: &PdfDocument, options: &TextOptions) -> NifResult<String> {
    let count = doc.page_count().map_err(to_nif_err)?;
    let mut text = String::new();
    for page_index in 0..count {
        if page_index > 0 {
            text.push('\x0c');
        }
        match extract_text_page(doc, page_index, options) {
            Ok(page_text) => text.push_str(&page_text),
            Err(_) if options.on_page_error == OnPageErrorNif::Skip => {}
            Err(e) => return Err(to_nif_page_err(page_index, e)),
        }
    }
    Ok(text)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_all_text(
    resource: ResourceArc<DocumentResource>,
    options: TextOptionsNif,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        options.validate()?;
        extract_all_text_pages(doc, &options.into())
    })
}

fn markdown_page(
    resource: &DocumentResource,
    page_index: usize,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;
        options.ensure_image_output_dir()?;

        doc.to_markdown(page_index, &options.into())
            .map_err(to_nif_err)
    })
}

fn markdown_all(resource: &DocumentResource, options: MarkdownOptionsNif) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        options.ensure_image_output_dir()?;

        doc.to_markdown_all(&options.into()).map_err(to_nif_err)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_markdown(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    markdown_page(&resource, page_index, options)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_markdown_all(
    resource: ResourceArc<DocumentResource>,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    markdown_all(&resource, options)
}

// The `_to_dir` pair is identical to the two above but for the scheduler. The
// Elixir side routes here when the options make upstream create directories and
// write PNGs, so those writes stay off the dirty CPU pool — the same split as
// `image_to_binary` versus `image_save`.

#[rustler::nif(schedule = "DirtyIo")]
fn document_to_markdown_to_dir(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    markdown_page(&resource, page_index, options)
}

#[rustler::nif(schedule = "DirtyIo")]
fn document_to_markdown_all_to_dir(
    resource: ResourceArc<DocumentResource>,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    markdown_all(&resource, options)
}

fn html_page(
    resource: &DocumentResource,
    page_index: usize,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;
        options.ensure_image_output_dir()?;

        doc.to_html(page_index, &options.into()).map_err(to_nif_err)
    })
}

fn html_all(resource: &DocumentResource, options: HtmlOptionsNif) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        options.ensure_image_output_dir()?;

        doc.to_html_all(&options.into()).map_err(to_nif_err)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_html(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_page(&resource, page_index, options)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_html_all(
    resource: ResourceArc<DocumentResource>,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_all(&resource, options)
}

// The dirty-IO pair, for the same reason as the Markdown one above.

#[rustler::nif(schedule = "DirtyIo")]
fn document_to_html_to_dir(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_page(&resource, page_index, options)
}

#[rustler::nif(schedule = "DirtyIo")]
fn document_to_html_all_to_dir(
    resource: ResourceArc<DocumentResource>,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_all(&resource, options)
}

fn plain_text_page(
    resource: &DocumentResource,
    page_index: usize,
    options: PlainTextOptionsNif,
) -> NifResult<String> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        doc.to_plain_text(page_index, &options.into())
            .map_err(to_nif_err)
    })
}

fn plain_text_all(resource: &DocumentResource, options: PlainTextOptionsNif) -> NifResult<String> {
    resource
        .doc
        .with_read(|doc| doc.to_plain_text_all(&options.into()).map_err(to_nif_err))
}

// No dirty-IO pair, unlike Markdown and HTML above: the plain-text converter
// emits no images, so nothing on this path can write to disk.

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_plain_text(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: PlainTextOptionsNif,
) -> NifResult<String> {
    plain_text_page(&resource, page_index, options)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_plain_text_all(
    resource: ResourceArc<DocumentResource>,
    options: PlainTextOptionsNif,
) -> NifResult<String> {
    plain_text_all(&resource, options)
}

// Post-filter so a region composes with extraction options that the dedicated
// `extract_*_in_rect` methods would discard.
fn apply_region<T>(items: Vec<T>, region: &Option<RegionFilter>) -> Vec<T>
where
    T: pdf_oxide::layout::LayoutObjectSpatial + Clone,
{
    match region {
        Some(RegionFilter { rect, mode }) => items.filter_by_rect(rect, *mode),
        None => items,
    }
}

fn extract_words_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &WordsOptions,
) -> Result<Vec<pdf_oxide::layout::Word>> {
    let words = if options.include_artifacts {
        doc.extract_words_with_thresholds(
            page_index,
            options.word_gap_threshold,
            options.profile.clone(),
        )?
    } else {
        doc.extract_words_with_thresholds_no_artifacts(
            page_index,
            options.word_gap_threshold,
            options.profile.clone(),
        )?
    };
    Ok(apply_region(words, &options.region))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_words(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: WordsOptionsNif,
) -> NifResult<Vec<WordNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        options.validate()?;

        let words = extract_words_page(doc, page_index, &options.into()).map_err(to_nif_err)?;
        Ok(words
            .into_iter()
            .map(|word| word_to_nif(word, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_words(
    resource: ResourceArc<DocumentResource>,
    options: WordsOptionsNif,
) -> NifResult<Vec<WordNif>> {
    resource.doc.with_read(|doc| {
        options.validate()?;
        let options: WordsOptions = options.into();

        let count = doc.page_count().map_err(to_nif_err)?;
        let mut words = Vec::new();
        for page_index in 0..count {
            let page_words = extract_words_page(doc, page_index, &options).map_err(to_nif_err)?;
            words.extend(
                page_words
                    .into_iter()
                    .map(|word| word_to_nif(word, page_index)),
            );
        }
        Ok(words)
    })
}

fn extract_text_lines_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &LinesOptions,
) -> Result<Vec<pdf_oxide::layout::TextLine>> {
    let lines = if options.include_artifacts {
        doc.extract_text_lines_with_thresholds(
            page_index,
            options.word_gap_threshold,
            options.line_gap_threshold,
            options.profile.clone(),
        )?
    } else {
        doc.extract_text_lines_with_thresholds_no_artifacts(
            page_index,
            options.word_gap_threshold,
            options.line_gap_threshold,
            options.profile.clone(),
        )?
    };
    Ok(apply_region(lines, &options.region))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_text_lines(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: LinesOptionsNif,
) -> NifResult<Vec<TextLineNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        options.validate()?;

        let lines =
            extract_text_lines_page(doc, page_index, &options.into()).map_err(to_nif_err)?;
        Ok(lines
            .into_iter()
            .map(|line| text_line_to_nif(line, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_text_lines(
    resource: ResourceArc<DocumentResource>,
    options: LinesOptionsNif,
) -> NifResult<Vec<TextLineNif>> {
    resource.doc.with_read(|doc| {
        options.validate()?;
        let options: LinesOptions = options.into();

        let count = doc.page_count().map_err(to_nif_err)?;
        let mut lines = Vec::new();
        for page_index in 0..count {
            let page_lines =
                extract_text_lines_page(doc, page_index, &options).map_err(to_nif_err)?;
            lines.extend(
                page_lines
                    .into_iter()
                    .map(|line| text_line_to_nif(line, page_index)),
            );
        }
        Ok(lines)
    })
}

fn extract_chars_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &CharsOptions,
) -> Result<Vec<pdf_oxide::layout::TextChar>> {
    let chars = if options.exclude_layers.is_empty() && options.exclude_inks.is_empty() {
        doc.extract_chars(page_index)?
    } else {
        doc.extract_chars_filtered(
            page_index,
            options.exclude_layers.iter().cloned().collect(),
            options.exclude_inks.iter().cloned().collect(),
        )?
    };
    Ok(apply_region(chars, &options.region))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_chars(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: CharsOptionsNif,
) -> NifResult<Vec<CharNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        options.validate()?;

        let chars = extract_chars_page(doc, page_index, &options.into()).map_err(to_nif_err)?;
        Ok(chars
            .into_iter()
            .map(|ch| char_to_nif(ch, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_chars(
    resource: ResourceArc<DocumentResource>,
    options: CharsOptionsNif,
) -> NifResult<Vec<CharNif>> {
    resource.doc.with_read(|doc| {
        options.validate()?;
        let options: CharsOptions = options.into();

        let count = doc.page_count().map_err(to_nif_err)?;
        let mut chars = Vec::new();
        for page_index in 0..count {
            let page_chars = extract_chars_page(doc, page_index, &options).map_err(to_nif_err)?;
            chars.extend(page_chars.into_iter().map(|ch| char_to_nif(ch, page_index)));
        }
        Ok(chars)
    })
}

// Configured span merging cannot take reading-order or layer/ink filters;
// Elixir refuses those combinations, and region still composes because it is
// applied afterward.
fn extract_spans_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &SpansOptions,
) -> Result<Vec<pdf_oxide::layout::TextSpan>> {
    let spans = match &options.span_merging {
        Some(config) => doc.extract_spans_with_config(page_index, config.clone())?,
        None if options.exclude_layers.is_empty() && options.exclude_inks.is_empty() => {
            doc.extract_spans_with_reading_order(page_index, options.reading_order)?
        }
        None => doc.extract_spans_filtered_with_reading_order(
            page_index,
            options.reading_order,
            options.exclude_layers.iter().cloned().collect(),
            options.exclude_inks.iter().cloned().collect(),
        )?,
    };
    Ok(apply_region(spans, &options.region))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_spans(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: SpansOptionsNif,
) -> NifResult<Vec<SpanNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        options.validate()?;

        let spans = extract_spans_page(doc, page_index, &options.into()).map_err(to_nif_err)?;
        Ok(spans
            .into_iter()
            .map(|span| span_to_nif(span, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_spans(
    resource: ResourceArc<DocumentResource>,
    options: SpansOptionsNif,
) -> NifResult<Vec<SpanNif>> {
    resource.doc.with_read(|doc| {
        options.validate()?;
        let options: SpansOptions = options.into();

        let count = doc.page_count().map_err(to_nif_err)?;
        let mut spans = Vec::new();
        for page_index in 0..count {
            let page_spans = extract_spans_page(doc, page_index, &options).map_err(to_nif_err)?;
            spans.extend(
                page_spans
                    .into_iter()
                    .map(|span| span_to_nif(span, page_index)),
            );
        }
        Ok(spans)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_paths(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<PathNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let paths = doc.extract_paths(page_index).map_err(to_nif_err)?;
        Ok(paths
            .into_iter()
            .map(|path| path_to_nif(path, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_paths(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<PathNif>> {
    resource.doc.with_read(|doc| {
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
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_rects(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<PathNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let rects = doc.extract_rects(page_index).map_err(to_nif_err)?;
        Ok(rects
            .into_iter()
            .map(|path| path_to_nif(path, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_rects(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<PathNif>> {
    resource.doc.with_read(|doc| {
        let count = doc.page_count().map_err(to_nif_err)?;
        let mut rects = Vec::new();
        for page_index in 0..count {
            let page_rects = doc.extract_rects(page_index).map_err(to_nif_err)?;
            rects.extend(
                page_rects
                    .into_iter()
                    .map(|path| path_to_nif(path, page_index)),
            );
        }
        Ok(rects)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_lines(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<PathNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let lines = doc.extract_lines(page_index).map_err(to_nif_err)?;
        Ok(lines
            .into_iter()
            .map(|path| path_to_nif(path, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_lines(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<PathNif>> {
    resource.doc.with_read(|doc| {
        let count = doc.page_count().map_err(to_nif_err)?;
        let mut lines = Vec::new();
        for page_index in 0..count {
            let page_lines = doc.extract_lines(page_index).map_err(to_nif_err)?;
            lines.extend(
                page_lines
                    .into_iter()
                    .map(|path| path_to_nif(path, page_index)),
            );
        }
        Ok(lines)
    })
}

// Reaches the page through `page_range` rather than `TextSearcher::search_page`,
// which takes a pre-built `regex::Regex` and ignores every option but
// `max_results`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_search(
    resource: ResourceArc<DocumentResource>,
    pattern: String,
    page_index: usize,
    options: SearchOptionsNif,
) -> NifResult<Vec<SearchMatchNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        run_search(
            doc,
            options.into_request(pattern),
            Some((page_index, page_index)),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_search(
    resource: ResourceArc<DocumentResource>,
    pattern: String,
    options: SearchOptionsNif,
) -> NifResult<Vec<SearchMatchNif>> {
    resource
        .doc
        .with_read(|doc| run_search(doc, options.into_request(pattern), None))
}

// Inverted, so `start..=end` visits no page: upstream clamps the end to the
// last page and never the start, which is what keeps this empty on every
// document.
const EMPTY_PAGE_RANGE: (usize, usize) = (1, 0);

fn run_search(
    doc: &OpenDocument,
    request: SearchRequest,
    page_range: Option<(usize, usize)>,
) -> NifResult<Vec<SearchMatchNif>> {
    // Compile before the per-page loop so empty searches still validate, using
    // the caller's raw pattern when grouping would obscure its error message.
    let probe = request
        .options
        .clone()
        .with_page_range(EMPTY_PAGE_RANGE.0, EMPTY_PAGE_RANGE.1);
    let probed = request.raw_pattern.as_deref().unwrap_or(&request.pattern);
    TextSearcher::search(doc, probed, &probe).map_err(to_search_err)?;

    // The probe above has already validated the pattern on a zero-page document.
    let Some(last) = doc.page_count().map_err(to_nif_err)?.checked_sub(1) else {
        return Ok(Vec::new());
    };
    let (start, end) = page_range.unwrap_or((0, last));
    let end = end.min(last);
    let max_results = request.options.max_results;

    // Resolve each page's runs while the search extraction is still cached.
    let mut matches = Vec::new();
    for page in start..=end {
        let options = request.options.clone().with_page_range(page, page);
        let hits = TextSearcher::search(doc, &request.pattern, &options).map_err(to_search_err)?;
        if hits.is_empty() {
            continue;
        }

        let runs = doc
            .search_runs
            .get_or_fill(page, || doc.extract_spans(page))
            .map_err(to_nif_err)?;
        for hit in hits {
            matches.push(search_match_to_nif(hit, &runs).ok_or_else(|| {
                tagged_err(
                    atoms::other(),
                    format!("page {page}: search match names runs the page's spans do not contain"),
                )
            })?);
        }

        if max_results > 0 && matches.len() >= max_results {
            matches.truncate(max_results);
            break;
        }
    }
    Ok(matches)
}

// A pattern that matches nothing, so a one-page search only builds that
// page's index.
const NEVER_MATCHES: &str = r"[^\s\S]";

#[rustler::nif(schedule = "DirtyCpu")]
fn document_prepare_search(resource: ResourceArc<DocumentResource>) -> NifResult<Atom> {
    resource.doc.with_read(|doc| {
        // Interleave the two caches so each page is extracted once.
        let count = doc.page_count().map_err(to_nif_err)?;
        for page in 0..count {
            doc.search_runs
                .get_or_fill(page, || doc.extract_spans(page))
                .map_err(to_nif_err)?;
            let options = SearchOptions::new().with_page_range(page, page);
            TextSearcher::search(doc, NEVER_MATCHES, &options).map_err(to_nif_err)?;
        }
        Ok(atoms::ok())
    })
}

// Exclusive so a concurrent search cannot reinsert an index after clear returns.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_clear_search_index(resource: ResourceArc<DocumentResource>) -> NifResult<Atom> {
    resource.doc.with_lock(|doc| {
        doc.clear_search_index();
        doc.search_runs.clear();
        Ok(atoms::ok())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_outline(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<OutlineItemNif>> {
    resource.doc.with_read(|doc| {
        let items = doc.get_outline().map_err(to_nif_err)?.unwrap_or_default();
        outline_to_nif(items)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_annotations(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<AnnotationNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let annotations = doc.get_annotations(page_index).map_err(to_nif_err)?;
        Ok(annotations
            .into_iter()
            .map(|annotation| annotation_to_nif(annotation, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_annotations(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Vec<AnnotationNif>> {
    resource.doc.with_read(|doc| {
        let count = doc.page_count().map_err(to_nif_err)?;
        let mut annotations = Vec::new();
        for page_index in 0..count {
            let page_annotations = doc.get_annotations(page_index).map_err(to_nif_err)?;
            annotations.extend(
                page_annotations
                    .into_iter()
                    .map(|annotation| annotation_to_nif(annotation, page_index)),
            );
        }
        Ok(annotations)
    })
}

// The pixel data behind each returned handle is *encoded* lazily, by
// `image_to_binary` / `image_save`, but it is resident from extraction onward —
// see `image_to_nif`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_images(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<ImageNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let images = doc.extract_images(page_index).map_err(to_nif_err)?;
        Ok(images
            .into_iter()
            .map(|image| image_to_nif(image, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_images(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<ImageNif>> {
    resource.doc.with_read(|doc| {
        let count = doc.page_count().map_err(to_nif_err)?;
        let mut images = Vec::new();
        for page_index in 0..count {
            let page_images = doc.extract_images(page_index).map_err(to_nif_err)?;
            images.extend(
                page_images
                    .into_iter()
                    .map(|image| image_to_nif(image, page_index)),
            );
        }
        Ok(images)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_fonts(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Vec<FontNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        Ok(extract_page_fonts(doc, page_index))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_fonts(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<FontNif>> {
    resource.doc.with_read(|doc| {
        let count = doc.page_count().map_err(to_nif_err)?;
        let mut fonts = Vec::new();
        for page_index in 0..count {
            fonts.extend(extract_page_fonts(doc, page_index));
        }
        Ok(fonts)
    })
}

// Adapts a present table bbox to upstream's spatial-filter trait.
struct TableBox(pdf_oxide::geometry::Rect);

impl LayoutObjectSpatial for TableBox {
    fn bbox(&self) -> pdf_oxide::geometry::Rect {
        self.0
    }
}

// Filter after detection so every mode preserves the caller's config.
fn extract_tables_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &TablesOptions,
) -> Result<Vec<pdf_oxide::structure::table_extractor::Table>> {
    let tables = doc.extract_tables_with_config(page_index, options.detection.clone())?;
    Ok(match &options.region {
        Some(RegionFilter { rect, mode }) => tables
            .into_iter()
            .filter(|table| {
                table
                    .bbox
                    .is_some_and(|bbox| TableBox(bbox).matches_filter(rect, *mode))
            })
            .collect(),
        None => tables,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_tables(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: TablesOptionsNif,
) -> NifResult<Vec<TableNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        options.validate()?;

        let tables = extract_tables_page(doc, page_index, &options.into()).map_err(to_nif_err)?;
        Ok(tables
            .into_iter()
            .map(|table| table_to_nif(table, page_index))
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_tables(
    resource: ResourceArc<DocumentResource>,
    options: TablesOptionsNif,
) -> NifResult<Vec<TableNif>> {
    resource.doc.with_read(|doc| {
        options.validate()?;
        let options: TablesOptions = options.into();

        let count = doc.page_count().map_err(to_nif_err)?;
        let mut tables = Vec::new();
        for page_index in 0..count {
            let page_tables = extract_tables_page(doc, page_index, &options).map_err(to_nif_err)?;
            tables.extend(
                page_tables
                    .into_iter()
                    .map(|table| table_to_nif(table, page_index)),
            );
        }
        Ok(tables)
    })
}

// Normalize raw corners so the Elixir rectangle and derived page dimensions
// always have a bottom-left origin and non-negative dimensions.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_get_page_media_box(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<RectNif> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let (llx, lly, urx, ury) = doc.get_page_media_box(page_index).map_err(to_nif_err)?;
        Ok(rect_from_corners(
            llx.into(),
            lly.into(),
            urx.into(),
            ury.into(),
        ))
    })
}

// Read the merged page dictionary and resolve the box and its elements so
// inherited and indirect spellings behave like `/MediaBox`; `null` is absent.
pub(crate) fn read_crop_box(doc: &PdfDocument, page_index: usize) -> Result<Option<[f32; 4]>> {
    let page = doc.get_page(page_index)?;
    let dict = page
        .as_dict()
        .ok_or_else(|| Error::InvalidPdf("Page is not a dictionary".to_string()))?;

    let Some(raw) = dict.get("CropBox") else {
        return Ok(None);
    };
    let resolved = doc.resolve_object(raw)?;
    if matches!(resolved, Object::Null) {
        return Ok(None);
    }
    let elements = resolved
        .as_array()
        .ok_or_else(|| Error::InvalidPdf("CropBox is not an array".to_string()))?;
    if elements.len() < 4 {
        return Err(Error::InvalidPdf(
            "CropBox must have at least 4 elements".to_string(),
        ));
    }

    let mut corners = [0.0f32; 4];
    for (corner, element) in corners.iter_mut().zip(elements) {
        *corner = match doc.resolve_object(element)? {
            Object::Integer(v) => v as f32,
            Object::Real(v) => v as f32,
            _ => 0.0,
        };
    }

    Ok(Some(corners))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_get_page_crop_box(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<Option<RectNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        Ok(read_crop_box(doc, page_index)
            .map_err(to_nif_err)?
            .map(|[llx, lly, urx, ury]| {
                rect_from_corners(llx.into(), lly.into(), urx.into(), ury.into())
            }))
    })
}

// `get_page_rotation` already resolves inheritance and normalizes the value.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_get_page_rotation(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<i32> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        doc.get_page_rotation(page_index).map_err(to_nif_err)
    })
}

// Bounds-check explicitly because the static probe does not produce the public
// `:out_of_range` reason on its own.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_has_text_layer(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
) -> NifResult<bool> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        doc.has_text_layer(page_index).map_err(to_nif_err)
    })
}

// Keep this uncached because authentication can replace the whole document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_form_fields(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<FieldNif>> {
    resource.doc.with_read(|doc| {
        let (fields, resolved) = form_tree::extract_fields(doc)?;

        Ok(fields
            .into_iter()
            .filter(|field| !resolved.is_signature(&field.full_name))
            .filter_map(|field| {
                let attrs = resolved.attrs(&field.full_name);
                let on_states = resolved.on_states(&field.full_name);

                document_form_field_to_nif(field, attrs, on_states)
            })
            .collect())
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_export_form_data(
    resource: ResourceArc<DocumentResource>,
    format: FormDataFormatNif,
    file_spec: Option<String>,
) -> NifResult<OwnedBinary> {
    resource.doc.with_read(|doc| {
        let (fields, resolved) = form_tree::extract_fields(doc)?;

        // The writers do not omit signature fields themselves.
        let fields = fields
            .into_iter()
            .filter(|field| is_exportable(field, &resolved))
            .collect();

        owned_binary(&export_bytes(fields, format, file_spec)?, "form data")
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{geometry::Rect, layout::RectFilterMode, search::SearchOptions};

    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    // A one-page document painting one Form XObject holding `content`, so the
    // stream runs under upstream's XObject handling behind a correct xref.
    fn one_xobject_page(content: &[u8]) -> Vec<u8> {
        let form = format!(
            "<< /Type /XObject /Subtype /Form /BBox [0 0 448 337] \
             /Resources << /Font << /F1 5 0 R >> >> /Length {} >>\nstream\n",
            content.len()
        );
        let objects: [Vec<u8>; 6] = [
            b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 448 337] \
              /Resources << /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>"
                .to_vec(),
            b"<< /Length 8 >>\nstream\n/Im1 Do \nendstream".to_vec(),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_vec(),
            [form.as_bytes(), content, b"\nendstream"].concat(),
        ];
        let mut out = b"%PDF-1.4\n".to_vec();
        let mut offsets = Vec::new();
        for (index, object) in objects.iter().enumerate() {
            offsets.push(out.len());
            out.extend_from_slice(format!("{} 0 obj\n", index + 1).as_bytes());
            out.extend_from_slice(object);
            out.extend_from_slice(b"\nendobj\n");
        }
        let xref = out.len();
        let size = objects.len() + 1;
        out.extend_from_slice(format!("xref\n0 {size}\n0000000000 65535 f \n").as_bytes());
        for offset in offsets {
            out.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
        }
        out.extend_from_slice(
            format!("trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n")
                .as_bytes(),
        );
        out
    }

    // The non-finite-float family: each pins one upstream mechanism that
    // overflows an f32. The boundary clamp stays when they fail; the canary goes.
    #[test]
    fn upstream_still_emits_an_infinite_span_size_for_a_huge_text_matrix() {
        let doc = PdfDocument::open(fixture("unbounded_text_matrix.pdf")).expect("fixture opens");
        let spans = doc.extract_spans(0).expect("spans");
        assert_eq!(spans.len(), 1);
        let span = &spans[0];
        assert!(span.font_size.is_infinite(), "{}", span.font_size);
        assert!(span.bbox.width.is_infinite(), "{}", span.bbox.width);
        assert!(span.bbox.height.is_infinite(), "{}", span.bbox.height);
    }

    #[test]
    fn upstream_still_accumulates_the_ctm_across_q_blocks_past_the_prescan_threshold() {
        let runs: Vec<u8> = (0..25)
            .flat_map(|index| {
                format!(
                    "q\n10 0 0 10 0 0 cm\nBT\n/F1 10 Tf\n1 0 0 1 {} 5 Tm\n(1) Tj\nET\nQ\n",
                    5 + index
                )
                .into_bytes()
            })
            .collect();
        let padding = b"0 0 m\n1 1 l\nS\n".repeat(25_000);
        let sizes = |content: Vec<u8>| -> Vec<f32> {
            let doc = PdfDocument::from_bytes(one_xobject_page(&content)).expect("synthetic opens");
            let mut sizes: Vec<f32> = doc
                .extract_chars(0)
                .expect("chars")
                .into_iter()
                .map(|ch| ch.font_size)
                .collect();
            sizes.sort_by(|a, b| a.partial_cmp(b).expect("no NaN"));
            sizes
        };

        let control = sizes(runs.clone());
        assert_eq!(control.len(), 25);
        assert!(control.iter().all(|&size| size == 100.0), "{control:?}");

        let compounded = sizes([runs, padding].concat());
        assert_eq!(compounded.len(), 25);
        assert_eq!(compounded[0], 100.0, "{compounded:?}");
        let finite: Vec<f32> = compounded
            .iter()
            .copied()
            .filter(|s| s.is_finite())
            .collect();
        assert!(
            finite
                .windows(2)
                .all(|pair| (pair[1] / pair[0] - 10.0).abs() < 1e-3),
            "{compounded:?}"
        );
        assert!(
            compounded.iter().any(|size| size.is_infinite()),
            "{compounded:?}"
        );
    }

    #[test]
    fn upstream_still_composes_an_infinite_image_ctm() {
        let doc = PdfDocument::open(fixture("unbounded_image_matrix.pdf")).expect("fixture opens");
        let images = doc.extract_images(0).expect("images");
        assert_eq!(images.len(), 1);
        let [a, b, c, d, e, f] = images[0].matrix();
        assert!(a.is_infinite(), "{a}");
        assert!(d.is_infinite(), "{d}");
        assert_eq!((b, c, e, f), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn upstream_still_serves_pre_authentication_caches_after_authenticate() {
        let doc = PdfDocument::open(fixture("encrypted.pdf")).expect("fixture opens");
        let search = |doc: &PdfDocument| {
            TextSearcher::search(doc, "Page", &SearchOptions::new()).expect("search runs")
        };
        assert!(doc.extract_spans(0).expect("spans").is_empty());
        assert!(doc.extract_chars(0).expect("chars").is_empty());
        assert!(search(&doc).is_empty());

        assert!(doc.authenticate(b"secret").expect("authenticate runs"));
        assert!(doc.extract_spans(0).expect("spans").is_empty());
        assert!(doc.extract_chars(0).expect("chars").is_empty());
        assert!(search(&doc).is_empty());

        // The control: authenticated before any read, the same file has text.
        let fresh = PdfDocument::open(fixture("encrypted.pdf")).expect("fixture opens");
        assert!(fresh.authenticate(b"secret").expect("authenticate runs"));
        assert!(!fresh.extract_spans(0).expect("spans").is_empty());
        assert!(!search(&fresh).is_empty());
    }

    #[test]
    fn has_xfa_matches_upstream() {
        for (name, expected) in [
            ("xfa.pdf", true),
            ("form.pdf", false),
            ("sample.pdf", false),
        ] {
            let mut doc = PdfDocument::open(fixture(name)).expect("fixture opens");

            // Precondition: `xfa.pdf` really is the positive case, so the
            // comparison below cannot pass by both sides answering `false`.
            assert_eq!(has_xfa(&doc).expect("local copy"), expected, "{name}");
            assert_eq!(
                has_xfa(&doc).expect("local copy"),
                pdf_oxide::xfa::XfaExtractor::has_xfa(&mut doc).expect("upstream"),
                "{name}"
            );
        }
    }

    // When the first assertion fails, upstream has added the group: delete the
    // grouping branch of `SearchOptionsNif::into_request` and the raw-pattern
    // probe in `run_search`, not this assertion.
    #[test]
    fn upstream_still_wraps_whole_word_without_grouping() {
        let doc = PdfDocument::open(fixture("search.pdf")).expect("fixture opens");
        let texts = |hits: Vec<pdf_oxide::search::SearchResult>| {
            hits.into_iter().map(|hit| hit.text).collect::<Vec<_>>()
        };

        // Ungrouped, the leading boundary also admits the "cat" in "category".
        let upstream = SearchOptions::new()
            .with_literal(false)
            .with_whole_word(true);
        assert_eq!(
            texts(TextSearcher::search(&doc, "cat|Report", &upstream).expect("upstream")),
            ["Report", "cat", "cat"]
        );

        let request = SearchOptionsNif {
            case_insensitive: false,
            literal: false,
            whole_word: true,
            max_results: 0,
        }
        .into_request("cat|Report".into());
        assert_eq!(
            texts(TextSearcher::search(&doc, &request.pattern, &request.options).expect("grouped")),
            ["Report", "cat"]
        );
    }

    // A filter given alone promises the default text, which holds only while
    // the filtered extractor's own conversion options match the binding's.
    #[test]
    fn upstream_filtered_text_still_matches_the_default_conversion() {
        let doc = PdfDocument::open(fixture("table.pdf")).expect("fixture opens");
        let plain = doc.extract_text(0).expect("plain text");

        // Precondition: the compared option changes the output when honoured.
        let without_tables = ConversionOptions {
            extract_tables: false,
            ..Default::default()
        };
        assert_ne!(
            doc.extract_text_with_options(0, &without_tables)
                .expect("text without tables"),
            plain
        );

        let filtered = doc
            .extract_text_filtered(
                0,
                HashSet::from(["NoSuchLayer".to_string()]),
                HashSet::new(),
            )
            .expect("filtered text");
        assert_eq!(filtered, plain);
    }

    #[test]
    fn whole_document_text_still_matches_upstream_extract_all_text() {
        let doc = PdfDocument::open(fixture("broken_page.pdf")).expect("fixture opens");

        // Precondition: the fixture still has a page that fails on its own.
        // Without it the comparison below would hold vacuously.
        assert_eq!(doc.page_count().expect("page count"), 3);
        assert!(doc.extract_text(2).is_err());

        let options = TextOptions {
            // What upstream's own `extract_text` sets before delegating.
            conversion: ConversionOptions {
                extract_tables: true,
                ..Default::default()
            },
            region: None,
            exclude_layers: Vec::new(),
            exclude_inks: Vec::new(),
            on_page_error: OnPageErrorNif::Skip,
        };

        assert_eq!(
            extract_all_text_pages(&doc, &options).expect("skips the failed page"),
            doc.extract_all_text().expect("upstream skips it too")
        );
    }

    #[test]
    fn upstream_still_ignores_region_filters_in_to_plain_text() {
        let doc = PdfDocument::open(fixture("extraction.pdf")).expect("fixture opens");

        // Vacuity guard: the tagged branch reads the option.
        assert!(!doc.prefers_structure_reading_order());

        let unfiltered = doc
            .to_plain_text(3, &ConversionOptions::default())
            .expect("plain text");
        assert!(!unfiltered.trim().is_empty(), "the page carries text");

        let (llx, lly, urx, ury) = doc.get_page_media_box(3).expect("media box");
        let filtered = ConversionOptions {
            exclude_regions: vec![Rect::new(llx, lly, urx - llx, ury - lly)],
            exclude_regions_mode: RectFilterMode::Intersects,
            ..Default::default()
        };

        // Control: the same exclusion is live on the text path.
        assert!(doc
            .extract_text_with_options(3, &filtered)
            .expect("text")
            .trim()
            .is_empty());

        assert_eq!(
            doc.to_plain_text(3, &filtered).expect("plain text"),
            unfiltered
        );
    }

    #[test]
    fn upstream_still_ignores_expand_ligatures_in_to_plain_text() {
        let doc = PdfDocument::open(fixture("extraction.pdf")).expect("fixture opens");

        // Vacuity guard: the tagged branch reads the option.
        assert!(!doc.prefers_structure_reading_order());

        let expand = ConversionOptions {
            expand_ligatures: true,
            ..Default::default()
        };

        // Control: the same option is live on the text path.
        assert!(doc
            .extract_text_with_options(2, &expand)
            .expect("text")
            .contains("cofin"));

        let unexpanded = doc
            .to_plain_text(2, &ConversionOptions::default())
            .expect("plain text");
        assert!(
            unexpanded.contains("co\u{FB01}n"),
            "the ligature reaches the plain-text output at all"
        );
        assert_eq!(
            doc.to_plain_text(2, &expand).expect("plain text"),
            unexpanded
        );
    }
}
