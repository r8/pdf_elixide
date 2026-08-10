use std::collections::HashSet;

use pdf_oxide::{
    converters::{BoldMarkerBehavior, ConversionOptions, ReadingOrderMode},
    error::Result,
    layout::SpatialCollectionFiltering,
    search::{SearchOptions, TextSearcher},
    PdfDocument,
};
use rustler::{Atom, Binary, NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    annotations::{annotation_to_nif, AnnotationNif},
    atoms,
    char::{char_to_nif, CharNif},
    error::{tagged_err, to_nif_err, to_nif_page_err, to_search_err},
    extract_options::{
        CharsOptions, CharsOptionsNif, LinesOptions, LinesOptionsNif, OnPageErrorNif, RegionFilter,
        SearchOptionsNif, SpansOptions, SpansOptionsNif, TablesOptions, TablesOptionsNif,
        TextOptions, TextOptionsNif, WordsOptions, WordsOptionsNif,
    },
    fonts::{extract_page_fonts, FontNif},
    form::{document_form_field_to_nif, FieldNif},
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
    word::{word_to_nif, WordNif},
    DocumentResource,
};

/// The `:password` is a `Binary`, not a `String`, for the same reason
/// `document_authenticate` takes one: upstream authenticates over raw bytes
/// (`PdfDocument::authenticate(&[u8])`), and a revision ≤ 4 password is a
/// PDFDocEncoded byte string that need not be valid UTF-8. Decoding it as a
/// `String` rejected such a password here — as a `NifMap` field-decode failure,
/// so `%Error{reason: :other}` rather than `:wrong_password` — while
/// `document_authenticate` accepted the very same bytes.
///
/// No `Debug`: `Binary` has no `Debug` impl, and a password has no business in
/// a derived debug string anyway.
#[derive(NifMap)]
pub struct OpenOptionsNif<'a> {
    pub password: Option<Binary<'a>>,
}

impl OpenOptionsNif<'_> {
    /// Note this is the *only* producer of `:wrong_password`: upstream has no
    /// error variant for a rejected password — `authenticate` returns
    /// `Ok(false)` — so the atom is synthesized here rather than reached
    /// through `error::classify`, whose doc comment marks the gap and says what
    /// breaks if upstream closes it.
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

/// The reading-order strategy requested for a Markdown or HTML conversion.
#[derive(NifUnitEnum, Debug)]
pub enum ReadingOrderNif {
    StructureTree,
    ColumnAware,
    TopToBottom,
}

/// Whether bold markers may wrap whitespace-only spans.
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

/// Creates the image output directory up front, for options that make upstream
/// write image files (`include_images` without `embed_images`, plus a
/// directory).
///
/// Upstream drops the result of its own `create_dir_all` and only logs a failed
/// `save_as_png`, so an unusable directory would otherwise surface as a
/// successful conversion with the image reference quietly missing. Creating it
/// here turns that into an `:io` error, matching what upstream does on its
/// non-converter export path.
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

/// The subset of `ConversionOptions` exposed to Elixir. Every remaining field
/// stays at its upstream default (see the `From` impl below).
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
    pub annotate_skipped_pages: bool,
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
            annotate_skipped_pages: o.annotate_skipped_pages,
            max_image_pixels: o.max_image_pixels,
            reading_order_mode: match o.reading_order {
                // `mcid_order` is an extraction-time detail upstream fills in.
                ReadingOrderNif::StructureTree => {
                    ReadingOrderMode::StructureTreeFirst { mcid_order: vec![] }
                }
                ReadingOrderNif::ColumnAware => ReadingOrderMode::ColumnAware,
                ReadingOrderNif::TopToBottom => ReadingOrderMode::TopToBottomLeftToRight,
            },
            bold_marker_behavior: o.bold_markers.into(),
            ..Default::default()
        }
    }
}

/// The subset of `ConversionOptions` that affects HTML output. Fields upstream
/// reads only on its Markdown path (`bold_marker_behavior`,
/// `annotate_skipped_pages`, `strip_running_headers_footers`) or only on its
/// plain-text path (`expand_ligatures`) are deliberately not exposed, and
/// `preserve_layout` is exposed here only, being HTML-only upstream.
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
            reading_order_mode: match o.reading_order {
                // `mcid_order` is an extraction-time detail upstream fills in.
                ReadingOrderNif::StructureTree => {
                    ReadingOrderMode::StructureTreeFirst { mcid_order: vec![] }
                }
                ReadingOrderNif::ColumnAware => ReadingOrderMode::ColumnAware,
                ReadingOrderNif::TopToBottom => ReadingOrderMode::TopToBottomLeftToRight,
            },
            ..Default::default()
        }
    }
}

/// Returns an `:out_of_range` error if `page_index` is not a valid page of
/// `doc`. Upstream reports a bad index as a generic `InvalidPdf`, so we check
/// bounds here to give callers a distinct, matchable reason.
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

/// What both open NIFs hand back: the handle, plus the two fields
/// `%PdfElixide.Document{}` caches at open, in one call.
///
/// One call rather than three is what closes the leak window: an open followed
/// by a separate version call left the opened document stranded until the BEAM
/// collected the handle if that second call failed.
///
/// A bare tuple rather than a `NifMap` struct: unlike `ImageNif`/`FontNif`/
/// `TableNif` this payload has no public Elixir struct behind it, and its only
/// consumers are `Document.open/2` and `Document.from_binary/2`. Give it a
/// `NifMap` if a third cached field appears, or a second consumer.
type OpenedDocument = (ResourceArc<DocumentResource>, (u8, u8), Option<usize>);

/// Reads the fields `%PdfElixide.Document{}` caches at open: the PDF version,
/// and the page count when it can be read.
///
/// **A page count that cannot be read is `None`, not an open failure.** For an
/// encrypted document whose page tree needs a password, upstream reports
/// `EncryptedPdf` until `document_authenticate` runs, and refusing to open such
/// a document would be stricter than upstream's own `page_indices()`. Elixir's
/// `page_count/1` falls back to `document_page_count` for exactly that document,
/// which is the escape hatch making this the *only* remaining swallow in the
/// NIF — the contract `PdfElixide.Document.page_count/1` documents.
///
/// Both reads go through `with_read` rather than reading the `PdfDocument`
/// before it is moved into the `Closable`, so a panic in upstream's page-tree
/// walk stays contained: a panic reading the version fails the open, a panic
/// reading the count only leaves it `None`. That is why they are two calls and
/// not one closure.
///
/// Callers must read *after* applying the open options: authentication is what
/// makes an encrypted document's page tree readable, so reading first would
/// silently downgrade a correctly-passworded document to `None`.
fn cached_fields(resource: &DocumentResource) -> NifResult<((u8, u8), Option<usize>)> {
    let version = resource.doc.with_read(|doc| Ok(doc.version()))?;
    let page_count = resource
        .doc
        .with_read(|doc| Ok(doc.page_count().ok()))
        .ok()
        .flatten();

    Ok((version, page_count))
}

/// Opens a PDF document from the specified file path, returning the handle
/// together with the version and page count Elixir caches on the struct.
#[rustler::nif(schedule = "DirtyIo")]
fn document_open(path: Binary, options: OpenOptionsNif<'_>) -> NifResult<OpenedDocument> {
    let doc = PdfDocument::open(path_arg(path)?).map_err(to_nif_err)?;
    options.apply(&doc)?;

    let resource = ResourceArc::new(DocumentResource {
        doc: Closable::new("Document", doc),
    });
    let (version, page_count) = cached_fields(&resource)?;

    Ok((resource, version, page_count))
}

/// Opens a PDF document from the given binary data, returning the handle
/// together with the version and page count Elixir caches on the struct.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_from_bytes(bytes: Binary, options: OpenOptionsNif<'_>) -> NifResult<OpenedDocument> {
    let doc = PdfDocument::from_bytes(bytes.as_slice().to_vec()).map_err(to_nif_err)?;
    options.apply(&doc)?;

    let resource = ResourceArc::new(DocumentResource {
        doc: Closable::new("Document", doc),
    });
    let (version, page_count) = cached_fields(&resource)?;

    Ok((resource, version, page_count))
}

/// Releases the document's native memory now, rather than waiting for the BEAM
/// to garbage-collect the handle. Idempotent; later calls on the handle fail
/// with `:closed`. Takes the document lock *exclusively*, so it waits for every
/// in-flight call on the same handle to return rather than interrupting them —
/// with reads running shared there can be many at once. See
/// [`Closable::close`](crate::resource::Closable::close).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_close(resource: ResourceArc<DocumentResource>) -> Atom {
    resource.doc.close();

    atoms::ok()
}

/// Returns whether the document has been released with `document_close`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_closed(resource: ResourceArc<DocumentResource>) -> bool {
    resource.doc.is_closed()
}

/// Returns the number of pages in the PDF document.
///
/// Dirty despite looking like a cheap accessor: it takes the document lock, and
/// a shared lock still waits behind an exclusive one — `document_authenticate`
/// or `document_close`, either of which waits in turn for every in-flight
/// extraction. A normal scheduler must never wait on that chain.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_count(resource: ResourceArc<DocumentResource>) -> NifResult<usize> {
    resource
        .doc
        .with_read(|doc| doc.page_count().map_err(to_nif_err))
}

/// Returns whether the PDF document has a structure tree (i.e. is a Tagged PDF).
///
/// Strict: a structure tree that fails to *parse* is an error, not `false`.
/// Upstream keeps the three states apart on purpose — `Ok(Some)` for a tagged
/// document, `Ok(None)` for an untagged one, `Err` for a broken
/// `/StructTreeRoot` — so collapsing the last two here would put the error
/// beyond any caller's reach. Elixir applies the tolerance instead:
/// `has_structure_tree?/1` degrades this to `false`, `has_structure_tree/1`
/// reports it.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_has_structure_tree(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    resource
        .doc
        .with_read(|doc| Ok(doc.structure_tree().map_err(to_nif_err)?.is_some()))
}

/// Upstream's `XfaExtractor::has_xfa` (`src/xfa/extractor.rs`), transcribed
/// against `&PdfDocument`.
///
/// Its `&mut PdfDocument` is vestigial — the body calls only `&self` methods —
/// but keeping it would force this NIF onto `Closable::with_lock` and make a
/// cheap predicate serialize every concurrent read on the handle.
/// `has_xfa_matches_upstream` below is the canary that the copy still agrees.
///
/// Deliberately *not* upstream's own `pdf_document_has_xfa` (`src/ffi.rs`),
/// which reimplements the same check inequivalently: it never resolves an
/// indirect `/AcroForm` reference, and collapses every error to `false`.
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

/// Returns whether the PDF document contains XFA (XML Forms Architecture) form
/// data.
///
/// Strict, for the same reason as `document_has_structure_tree`, and with less
/// to lose by it: upstream's `has_xfa` already answers `Ok(false)` for every
/// *structural* absence (no catalog dictionary, no `/AcroForm`, no `/XFA`), so
/// its `Err` arms are only an unreadable catalog and a dangling `/AcroForm`
/// reference. Swallowing them would add no tolerance upstream had not already
/// applied.
///
/// Reads through the local `has_xfa` above rather than calling upstream, whose
/// signature would demand an exclusive lock for no reason — see its comment.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_has_xfa(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    resource
        .doc
        .with_read(|doc| has_xfa(doc).map_err(to_nif_err))
}

/// Returns whether the PDF document is encrypted.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_is_encrypted(resource: ResourceArc<DocumentResource>) -> NifResult<bool> {
    resource.doc.with_read(|doc| Ok(doc.is_encrypted()))
}

/// Authenticates against the document's encryption with the given password.
/// Returns `Ok(true)` on success (or if the PDF is not encrypted),
/// `Ok(false)` if the password was invalid.
///
/// **The one document NIF that takes the lock exclusively**, though upstream's
/// `authenticate` is `&self` like everything else here. A first successful
/// authentication replaces the whole `PdfDocument` (see below), and nothing
/// upstream stops a concurrent reader from straddling that swap. `with_lock` is
/// what makes it atomic against every reader on the handle. It costs nothing:
/// this is a one-shot call, where the extractors it excludes are the hot path.
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
        let ok = fresh
            .authenticate(password.as_slice())
            .map_err(to_nif_err)?;

        if ok {
            *doc = fresh;
        }

        Ok(ok)
    })
}

/// Extracts one page's text under the caller's options.
///
/// Layer and ink filtering can only be served by upstream's
/// `extract_text_filtered` / `extract_text_filtered_in_rect`, which build their
/// own `ConversionOptions` internally (`extract_tables: true`, everything else
/// default) and offer no way to pass ours — `assemble_text_from_spans` is
/// private. So when either list is non-empty every option except `:region` and
/// `:region_mode` falls back to its upstream default; `PdfElixide.Document`
/// documents that and `upstream_drift_test.exs` pins it.
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

/// Extracts text content from a single page (zero-indexed).
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

/// Concatenates every page's text, separated by form feeds.
///
/// Free rather than inline in the NIF so the parity test below can drive it
/// with a `&PdfDocument` of its own, no resource involved.
///
/// The `\x0c` goes in *before* the fallible extraction, so a page that fails
/// still leaves its (empty) slot behind: the result always splits into exactly
/// `page_count` parts, and a skipped page is indistinguishable from a blank
/// one. That is upstream `extract_all_text`'s shape, byte for byte, and the
/// parity test pins it.
fn extract_all_text_pages(doc: &PdfDocument, options: &TextOptions) -> NifResult<String> {
    let count = doc.page_count().map_err(to_nif_err)?;
    let mut text = String::new();
    for page_index in 0..count {
        if page_index > 0 {
            text.push('\x0c');
        }
        match extract_text_page(doc, page_index, options) {
            Ok(page_text) => text.push_str(&page_text),
            // The default: a failed page contributes nothing and does not fail
            // the document, as upstream `extract_all_text` swallows it (it logs
            // the error, which this crate cannot — no logging dependency). Only
            // `:halt` diverges, and then the message names the page, since the
            // silent skip is what leaves the caller nothing to go on.
            Err(_) if options.on_page_error == OnPageErrorNif::Skip => {}
            Err(e) => return Err(to_nif_page_err(page_index, e)),
        }
    }
    Ok(text)
}

/// Extracts text content from all pages, separated by form-feed characters.
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

/// Converts a single page (zero-indexed) to Markdown.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_markdown(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    markdown_page(&resource, page_index, options)
}

/// Converts all pages to Markdown, separated by a `---` thematic break.
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

/// Converts a single page (zero-indexed) to Markdown, writing images to disk.
#[rustler::nif(schedule = "DirtyIo")]
fn document_to_markdown_to_dir(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: MarkdownOptionsNif,
) -> NifResult<String> {
    markdown_page(&resource, page_index, options)
}

/// Converts all pages to Markdown, writing images to disk.
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

/// Converts a single page (zero-indexed) to an HTML fragment.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_html(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_page(&resource, page_index, options)
}

/// Converts all pages to HTML, each wrapped in a `<div class="page">`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_html_all(
    resource: ResourceArc<DocumentResource>,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_all(&resource, options)
}

// The dirty-IO pair, for the same reason as the Markdown one above.

/// Converts a single page (zero-indexed) to HTML, writing images to disk.
#[rustler::nif(schedule = "DirtyIo")]
fn document_to_html_to_dir(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_page(&resource, page_index, options)
}

/// Converts all pages to HTML, writing images to disk.
#[rustler::nif(schedule = "DirtyIo")]
fn document_to_html_all_to_dir(
    resource: ResourceArc<DocumentResource>,
    options: HtmlOptionsNif,
) -> NifResult<String> {
    html_all(&resource, options)
}

/// Applies a caller-supplied `:region` to an already-extracted collection.
///
/// Upstream's own `extract_*_in_rect` methods do exactly this internally, over
/// the plain (option-less) extraction. Filtering here instead of calling them
/// is what lets `:region` compose with `:word_gap_threshold`, `:profile`,
/// `:span_merging` and the layer/ink-filtered variants — those methods would
/// discard all of it.
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

/// Extracts words (with bounding boxes) from a single page (zero-indexed).
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

/// Extracts words (with bounding boxes) from all pages, in page order.
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

/// Extracts text lines (each with its words) from a single page (zero-indexed).
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

/// Extracts text lines (each with its words) from all pages, in page order.
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

/// Extracts characters (with bounding boxes and font metadata) from a single
/// page (zero-indexed).
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

/// Extracts characters (with bounding boxes and font metadata) from all pages,
/// in page order.
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

/// Extracts one page's spans under the caller's options.
///
/// `:span_merging` is served by `extract_spans_with_config`, which takes no
/// reading order and no layer/ink filters, so setting it drops `:reading_order`,
/// `:exclude_layers` and `:exclude_inks`. `:region` still applies — it is a
/// post-filter here rather than an upstream argument.
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

/// Extracts spans (runs of text sharing one text state) from a single page
/// (zero-indexed).
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

/// Extracts spans (runs of text sharing one text state) from all pages, in
/// page order.
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

/// Extracts vector paths (lines, curves, rectangles, shapes) from a single page
/// (zero-indexed).
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

/// Extracts vector paths from all pages, in page order.
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

/// Extracts the paths upstream classifies as rectangles from a single page
/// (zero-indexed).
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

/// Extracts rectangles from all pages, in page order.
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

/// Extracts the paths upstream classifies as single straight line segments from
/// a single page (zero-indexed).
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

/// Extracts straight lines from all pages, in page order.
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

/// Searches a single page (zero-indexed) for `pattern`.
///
/// Reaches the page through `page_range` rather than `TextSearcher::search_page`,
/// which takes a pre-built `regex::Regex` and ignores every option but
/// `max_results`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_search(
    resource: ResourceArc<DocumentResource>,
    pattern: String,
    page_index: usize,
    options: SearchOptionsNif,
) -> NifResult<Vec<SearchMatchNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let options = SearchOptions::from(options).with_page_range(page_index, page_index);
        let hits = TextSearcher::search(doc, &pattern, &options).map_err(to_search_err)?;
        Ok(hits.into_iter().map(search_match_to_nif).collect())
    })
}

/// Searches every page for `pattern`, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_search(
    resource: ResourceArc<DocumentResource>,
    pattern: String,
    options: SearchOptionsNif,
) -> NifResult<Vec<SearchMatchNif>> {
    resource.doc.with_read(|doc| {
        let mut options = SearchOptions::from(options);

        // A document with no pages must answer `[]` like every sibling
        // extractor, but not by returning early: `TextSearcher::search` compiles
        // the pattern before it reads the page count, so an early return would
        // accept an unparseable one. An inverted range keeps the call and still
        // visits nothing — `start..=end` is empty when `start > end`.
        if doc.page_count().map_err(to_nif_err)? == 0 {
            options = options.with_page_range(1, 0);
        }

        let hits = TextSearcher::search(doc, &pattern, &options).map_err(to_search_err)?;
        Ok(hits.into_iter().map(search_match_to_nif).collect())
    })
}

/// Builds the search index for every page up front, so the first `search` call
/// does not pay for the whole document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_prepare_search(resource: ResourceArc<DocumentResource>) -> NifResult<Atom> {
    resource.doc.with_read(|doc| {
        doc.prepare_search().map_err(to_nif_err)?;
        Ok(atoms::ok())
    })
}

/// Drops the cached search index, releasing the page text and span boxes it
/// holds.
///
/// Exclusive, unlike every other read here, because upstream's
/// `search_page_index` drops its map guard before extracting a page and
/// re-acquires it to insert. A concurrent search would therefore be free to put
/// its page back *after* the clear returned, leaving the one call that releases
/// this memory unable to promise it did.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_clear_search_index(resource: ResourceArc<DocumentResource>) -> NifResult<Atom> {
    resource.doc.with_lock(|doc| {
        doc.clear_search_index();
        Ok(atoms::ok())
    })
}

/// Reads the document outline (bookmarks / table of contents) as a tree of
/// `OutlineItemNif`. Returns an empty list when the document has no outline, and
/// `:unsupported` for one nested past `outline::MAX_OUTLINE_DEPTH`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_outline(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<OutlineItemNif>> {
    resource.doc.with_read(|doc| {
        let items = doc.get_outline().map_err(to_nif_err)?.unwrap_or_default();
        outline_to_nif(items)
    })
}

/// Reads the annotations of a single page (zero-indexed) as `AnnotationNif`
/// structs. Returns an empty list when the page has no annotations.
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

/// Reads the annotations across all pages, in page order.
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

/// Extracts raster images (photos, logos, scanned pictures) from a single page
/// (zero-indexed). Each one carries its metadata plus a handle to the image
/// itself; the pixel data is *encoded* lazily, by `image_to_binary` /
/// `image_save`, but it is resident in the handle from extraction onward — see
/// `image_to_nif`.
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

/// Extracts raster images from all pages, in page order.
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

/// Extracts the fonts referenced by a single page (zero-indexed), with their
/// metadata and a handle to any embedded font program.
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

/// Extracts the fonts referenced across all pages, in page order.
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

/// Detects one page's tables under the caller's detection config.
///
/// The region variant passes the caller's config through, where upstream's own
/// `extract_tables_in_rect` would silently swap in `TableDetectionConfig::
/// relaxed()`. Python deviates the same way; `:preset` makes it explicit.
fn extract_tables_page(
    doc: &PdfDocument,
    page_index: usize,
    options: &TablesOptions,
) -> Result<Vec<pdf_oxide::structure::table_extractor::Table>> {
    match &options.region {
        Some(rect) => {
            doc.extract_tables_in_rect_with_config(page_index, *rect, options.detection.clone())
        }
        None => doc.extract_tables_with_config(page_index, options.detection.clone()),
    }
}

/// Detects tables on a single page (zero-indexed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_tables(
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: TablesOptionsNif,
) -> NifResult<Vec<TableNif>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let tables = extract_tables_page(doc, page_index, &options.into()).map_err(to_nif_err)?;
        Ok(tables
            .into_iter()
            .map(|table| table_to_nif(table, page_index))
            .collect())
    })
}

/// Detects tables on all pages, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_all_tables(
    resource: ResourceArc<DocumentResource>,
    options: TablesOptionsNif,
) -> NifResult<Vec<TableNif>> {
    resource.doc.with_read(|doc| {
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

/// Returns the page's `/MediaBox` as a normalised rect.
///
/// Upstream hands back the four raw array elements — absolute corners in file
/// order — so a malformed box may arrive reversed. `rect_from_corners`
/// normalises it, because `PdfElixide.Geometry.Rect` promises a bottom-left
/// origin and non-negative dimensions, and because `Page.width/1` and
/// `Page.height/1` are these fields: nothing else computes a page size, so
/// nothing else can disagree about one.
///
/// An absent `/MediaBox`, a non-array entry and an array shorter than four are
/// each an `InvalidPdf` — propagated, never replaced with a default page size.
/// Upstream reads the entry off the dictionary [`get_page`] returns, which
/// carries the inherited attributes, so a `/MediaBox` on an ancestor `/Pages`
/// node is honoured — though *which* ancestor wins depends on how the page was
/// reached; the "Page boxes and the coordinate origin" section of the
/// `PdfElixide.Document` moduledoc has it. An indirect reference is resolved
/// both for the array and for each element. A non-numeric element is upstream's
/// one silent case: it coerces to 0.0.
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

/// Returns the page's `/Rotate`, normalised to 0, 90, 180 or 270.
///
/// Upstream reads the value off the dictionary [`get_page`] returns, which
/// carries the inherited attributes, so a `/Rotate` on an ancestor `/Pages`
/// node is honoured (ISO 32000-1 §7.7.3.4) — with the same which-ancestor-wins
/// caveat as `document_get_page_media_box` above. A value that is not a
/// multiple of 90 is invalid and yields 0 rather than being floored
/// (`pdf_oxide` `src/document.rs`, `get_page_rotation`).
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

/// Returns whether the page carries a text layer, or is image-only / empty.
///
/// A *static probe*, not an extraction: upstream's `has_text_layer` loads no
/// fonts and maps no glyphs. It checks the resource dictionary, then scans the
/// decoded content stream for a delimiter-bounded `BT` or `Do`; both stages
/// approximate towards `true`, so `false` is the reliable direction and `true`
/// is not a promise that `extract_text` returns anything. The four consequences
/// a caller sees are on `PdfElixide.Document.Page.has_text_layer/1`.
///
/// `ensure_page_in_range` is load-bearing for the same reason it is on
/// `document_page_label`: upstream does not bounds-check, so a bad index would
/// surface as whatever `get_page` fails with — a generic `InvalidPdf` or
/// `ObjectNotFound` — rather than a matchable `:out_of_range`.
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

/// Extracts form fields from the PDF document.
///
/// Through `form_tree` rather than `FormExtractor::extract_fields` directly, for
/// the two reasons that module gives. Uncached, unlike the editor's:
/// `document_authenticate` swaps the whole `PdfDocument`, so a cache here would
/// need an invalidation rule for that one call.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_form_fields(resource: ResourceArc<DocumentResource>) -> NifResult<Vec<FieldNif>> {
    resource.doc.with_read(|doc| {
        let (fields, signatures) = form_tree::extract_fields(doc)?;

        Ok(fields
            .into_iter()
            .filter(|field| !signatures.contains(&field.full_name))
            .filter_map(document_form_field_to_nif)
            .collect())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    /// Upstream canary for the local `has_xfa`, which exists only to shed
    /// upstream's vestigial `&mut` and must otherwise answer exactly what
    /// `XfaExtractor::has_xfa` answers. No Elixir test can make this comparison:
    /// nothing in the binding reaches the upstream function any more.
    ///
    /// The three fixtures are the three branches — `xfa.pdf` reaches `/XFA`
    /// through an indirect `/AcroForm` reference (the branch upstream's own C
    /// FFI shortcut skips, which is why that shortcut was not copied),
    /// `form.pdf` has an `/AcroForm` without `/XFA`, and `sample.pdf` has no
    /// `/AcroForm` at all.
    ///
    /// If upstream ever starts looking somewhere else for XFA, this fails — and
    /// then the copy is what has to be brought back into line, not the
    /// assertion.
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

    /// Upstream canary — a failure here is a signal about `pdf_oxide`, not a
    /// bug in this crate. See `test/pdf_elixide/upstream_drift_test.exs`.
    ///
    /// `extract_all_text_pages` reimplements upstream's `extract_all_text`
    /// rather than calling it, so everything `PdfElixide.Document.text/1`
    /// documents is a claim about a copy. This asserts the copy still matches
    /// the original, which no Elixir test can do: nothing in the binding
    /// reaches `extract_all_text` itself. If it fails, `:on_page_error`'s
    /// default is what has to be reconsidered, not the assertion.
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
}
