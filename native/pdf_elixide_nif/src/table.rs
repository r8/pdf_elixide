use pdf_oxide::{
    converters::ConversionOptions,
    pipeline::{HtmlOutputConverter, MarkdownOutputConverter, OutputConverter, TextPipelineConfig},
    structure::table_extractor::{Table, TableCell, TableRow},
};
use rustler::{Atom, NifMap, NifResult, ResourceArc};

use crate::{
    atoms,
    document::BoldMarkersNif,
    error::to_nif_err,
    geometry::{rect_to_nif, RectNif},
    resource::Closable,
    span::{span_to_nif, SpanNif},
    TableResource,
};

#[derive(NifMap)]
#[rustler(encode)]
pub struct TableNif {
    page: usize,
    bbox: Option<RectNif>,
    col_count: usize,
    has_header: bool,
    real_grid: bool,
    rows: Vec<TableRowNif>,
    /// Handle to the upstream `Table` itself, kept so the table can be rendered
    /// later by upstream's own converters (see `table_to_markdown` below).
    resource: ResourceArc<TableResource>,
}

#[derive(NifMap, Debug)]
pub struct TableRowNif {
    header: bool,
    cells: Vec<TableCellNif>,
}

#[derive(NifMap, Debug)]
pub struct TableCellNif {
    text: String,
    bbox: Option<RectNif>,
    colspan: u32,
    rowspan: u32,
    header: bool,
    mcids: Vec<u32>,
    spans: Vec<SpanNif>,
}

pub fn table_to_nif(table: Table, page: usize) -> TableNif {
    // `is_real_grid` borrows the rows, so evaluate it before consuming them.
    let real_grid = table.is_real_grid();
    // The decoded fields below consume the table, so the resource gets a clone.
    // Rendering needs the upstream value itself: its cells carry `TextSpan`s
    // whose glyph metrics decide bold markers and inter-token spacing, and those
    // do not survive a trip through the decoded map.
    let resource = ResourceArc::new(TableResource {
        table: Closable::new("Table", table.clone()),
    });

    TableNif {
        page,
        resource,
        bbox: table.bbox.map(rect_to_nif),
        col_count: table.col_count,
        has_header: table.has_header,
        real_grid,
        rows: table
            .rows
            .into_iter()
            .map(|row| table_row_to_nif(row, page))
            .collect(),
    }
}

fn table_row_to_nif(row: TableRow, page: usize) -> TableRowNif {
    TableRowNif {
        header: row.is_header,
        cells: row
            .cells
            .into_iter()
            .map(|cell| table_cell_to_nif(cell, page))
            .collect(),
    }
}

fn table_cell_to_nif(cell: TableCell, page: usize) -> TableCellNif {
    TableCellNif {
        text: cell.text,
        bbox: cell.bbox.map(rect_to_nif),
        colspan: cell.colspan,
        rowspan: cell.rowspan,
        header: cell.is_header,
        mcids: cell.mcids,
        spans: cell
            .spans
            .into_iter()
            .map(|span| span_to_nif(span, page))
            .collect(),
    }
}

/// The one conversion option a table renderer actually reads. Upstream's
/// Markdown table path consults `bold_marker_behavior` (through `is_bold_raw`)
/// and nothing else; its HTML table path reads no configuration at all.
#[derive(NifMap, Debug)]
pub struct TableMarkdownOptionsNif {
    pub bold_markers: BoldMarkersNif,
}

/// Renders a single table through upstream's own converter.
///
/// Upstream exposes no `Table::to_markdown`/`to_html` and keeps
/// `render_table_markdown`/`render_table_html` private, but
/// `OutputConverter::convert_with_tables` emits just the tables when handed no
/// spans — which is exactly how upstream's own tests exercise those renderers.
///
/// The config is built the way the whole-document path builds it — through
/// `TextPipelineConfig::from_conversion_options` — so a table rendered on its
/// own cannot drift from the same table rendered as part of its page.
fn render(
    converter: &dyn OutputConverter,
    table: &Table,
    options: ConversionOptions,
) -> NifResult<String> {
    let config = TextPipelineConfig::from_conversion_options(&options);

    converter
        .convert_with_tables(&[], std::slice::from_ref(table), &config)
        .map_err(to_nif_err)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn table_to_markdown(
    resource: ResourceArc<TableResource>,
    options: TableMarkdownOptionsNif,
) -> NifResult<String> {
    let table = resource.table.read()?;

    render(
        &MarkdownOutputConverter::new(),
        &table,
        ConversionOptions {
            bold_marker_behavior: options.bold_markers.into(),
            ..Default::default()
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn table_to_html(resource: ResourceArc<TableResource>) -> NifResult<String> {
    let table = resource.table.read()?;

    // Defaults throughout: the HTML table renderer reads no configuration at
    // all, and `preserve_layout` must stay false — upstream's HTML converter
    // discards the tables entirely and emits positioned `<div>`s instead when it
    // is set.
    render(
        &HtmlOutputConverter::new(),
        &table,
        ConversionOptions::default(),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn table_to_text(resource: ResourceArc<TableResource>) -> NifResult<String> {
    let table = resource.table.read()?;

    Ok(table.render_text())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn table_close(resource: ResourceArc<TableResource>) -> Atom {
    resource.table.close();

    atoms::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn table_closed(resource: ResourceArc<TableResource>) -> bool {
    resource.table.is_closed()
}
