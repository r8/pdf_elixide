use pdf_oxide::structure::table_extractor::{Table, TableCell, TableRow};
use rustler::NifMap;

use crate::{
    geometry::{rect_to_nif, RectNif},
    span::{span_to_nif, SpanNif},
};

#[derive(NifMap, Debug)]
pub struct TableNif {
    page: usize,
    bbox: Option<RectNif>,
    col_count: usize,
    has_header: bool,
    real_grid: bool,
    rows: Vec<TableRowNif>,
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

    TableNif {
        page,
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
