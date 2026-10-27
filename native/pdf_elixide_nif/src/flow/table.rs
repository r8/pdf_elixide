use std::ops::Range;

use pdf_oxide::elements::PathOperation;

use super::{
    boxed_lines, references, tokens, units, wrap, Align, Item, Layout, PositionedLine, Refused,
    Rgb, Run, Segment, Shape, Stroke, Token, Within, FIT_TOLERANCE, NO_EXTENT,
};

pub struct Table {
    pub rows: Vec<Vec<Cell>>,
    // The face whose metrics place every cell's lines.
    pub face: usize,
    pub size: f64,
    pub widths: Vec<Width>,
    pub header_rows: usize,
    pub header_fill: Option<Rgb>,
    pub padding: f64,
    pub stroke: Option<Stroke>,
}

// A cell starts at `column` of its row; the Elixir side has checked that the
// cells and their spans tile the grid.
pub struct Cell {
    pub runs: Vec<Run>,
    pub column: usize,
    pub colspan: usize,
    pub rowspan: usize,
    pub align: Align,
    pub fill: Option<Rgb>,
}

#[derive(Clone, Copy)]
pub enum Width {
    Points(f64),
    Weight(f64),
    Auto,
}

// A table measured against the page it starts on, which every page it
// continues onto repeats.
struct Measured<'t> {
    table: &'t Table,
    // Each column's left edge, then the table's right edge.
    edges: Vec<f64>,
    heights: Vec<f64>,
    // Each cell's wrapped lines, indexed as `Table::rows`.
    lines: Vec<Vec<Vec<Vec<Segment>>>>,
    // Body rows, grouped so that no rowspan crosses from one group into the
    // next.
    units: Vec<Range<usize>>,
    header: f64,
    line: f64,
    above_baseline: f64,
}

impl Measured<'_> {
    // The least of a unit that can start a page: a group whole, a lone row
    // one line of it.
    fn least(&self, unit: &Range<usize>) -> f64 {
        let height = self.unit_height(unit);
        if unit.len() == 1 {
            height.min(self.line + 2.0 * self.table.padding)
        } else {
            height
        }
    }

    fn unit_height(&self, unit: &Range<usize>) -> f64 {
        self.heights[unit.clone()].iter().sum()
    }

    // The notes referenced from lines `lines` of every cell in `rows`.
    fn notes_in(&self, rows: Range<usize>, lines: Range<usize>) -> Vec<usize> {
        self.lines[rows]
            .iter()
            .flatten()
            .flat_map(|cell| {
                let end = lines.end.min(cell.len());
                cell[lines.start.min(end)..end].iter()
            })
            .flat_map(|segments| references(segments))
            .collect()
    }

    // The notes on the part of a unit that `least` counts.
    fn lead_notes(&self, unit: &Range<usize>) -> Vec<usize> {
        if self.least(unit) < self.unit_height(unit) {
            self.notes_in(unit.clone(), 0..1)
        } else {
            self.notes_in(unit.clone(), 0..usize::MAX)
        }
    }

    fn has_notes(&self, row: usize, from: usize) -> bool {
        !self.notes_in(row..row + 1, from..usize::MAX).is_empty()
    }
}

// What the table draws on one page, painted fills first and the grid last so
// that no fill covers a neighbor's border or text.
#[derive(Default)]
struct Drawn {
    boxes: Vec<([f64; 4], Option<Rgb>)>,
    lines: Vec<PositionedLine>,
}

impl Layout<'_> {
    pub(super) fn table(&mut self, op: usize, table: &Table) -> Result<(), Refused> {
        self.ensure_page();
        let page = self.pages.len() - 1;
        let line = table.size * self.line_height;
        self.precise(op, page, table.size, table.size.min(line))?;
        let texts: Vec<&[Run]> = table
            .rows
            .iter()
            .flatten()
            .map(|cell| cell.runs.as_slice())
            .collect();
        self.drawable(op, page, &texts, &[])?;
        self.check_notes(op, &texts)?;

        let measured = self.measure(op, table)?;
        let (first, lead) = measured.units.first().map_or((0.0, Vec::new()), |unit| {
            (measured.least(unit), measured.lead_notes(unit))
        });
        if !self.fresh {
            let spaced = self.cursor - self.pending_space;
            let notes = self.notes_height(op, &lead)?;
            if self.fits(spaced, measured.header + first + notes) {
                self.cursor = spaced;
            } else {
                self.break_page();
            }
        }
        self.pending_space = 0.0;
        self.resolve_anchors();

        let mut drawn = Drawn::default();
        self.place_rows(&measured, 0..table.header_rows, &mut drawn);
        for unit in &measured.units {
            let height = measured.unit_height(unit);
            let notes = measured.notes_in(unit.clone(), 0..usize::MAX);
            if self.fits(self.cursor, height + self.notes_height(op, &notes)?) {
                self.reserve(op, height, &notes)?;
                self.place_rows(&measured, unit.clone(), &mut drawn);
            } else if unit.len() > 1 {
                self.turn_page(op, &measured, &mut drawn)?;
                self.reserve(op, height, &notes)?;
                self.place_rows(&measured, unit.clone(), &mut drawn);
            } else {
                self.split_row(op, &measured, unit.start, &mut drawn)?;
            }
        }
        self.paint(op, &measured, drawn)?;

        self.fresh = false;
        self.pending_space = 0.5 * table.size;
        Ok(())
    }

    // What a heading before the table must keep with: the header rows and
    // the start of the first body row, and the notes it references. A table
    // that will be refused counts as one row of one line.
    pub(super) fn table_lead(&self, table: &Table) -> (f64, Vec<usize>) {
        let fallback = table.size * self.line_height + 2.0 * table.padding;
        self.measure(0, table)
            .map_or((fallback, Vec::new()), |measured| {
                measured
                    .units
                    .first()
                    .map_or((measured.header, Vec::new()), |unit| {
                        (
                            measured.header + measured.least(unit),
                            measured.lead_notes(unit),
                        )
                    })
            })
    }

    fn measure<'t>(&self, op: usize, table: &'t Table) -> Result<Measured<'t>, Refused> {
        let page = self.pages.len() - 1;
        let padding = table.padding;
        let line = table.size * self.line_height;
        let left = self.margins.left;
        let room = self.content_width(op, page, left)?;

        let mut edges = vec![left];
        for width in self.column_widths(op, page, table, room)? {
            edges.push(edges[edges.len() - 1] + width);
        }

        let lines = table
            .rows
            .iter()
            .enumerate()
            .map(|(row, cells)| {
                cells
                    .iter()
                    .map(|cell| {
                        let width =
                            edges[cell.column + cell.colspan] - edges[cell.column] - 2.0 * padding;
                        wrap(self.fonts, &cell.runs, table.size, width).map_err(
                            |(cluster, cluster_width)| Refused::ClusterTooWide {
                                op,
                                page,
                                cluster,
                                width: cluster_width,
                                room: width,
                                within: Within::Cell {
                                    row,
                                    column: cell.column,
                                },
                            },
                        )
                    })
                    .collect::<Result<Vec<_>, _>>()
            })
            .collect::<Result<Vec<_>, _>>()?;

        let cell_height = |lines: &[Vec<Segment>]| lines.len().max(1) as f64 * line + 2.0 * padding;
        let mut heights = vec![0.0; table.rows.len()];
        let mut spans = Vec::new();
        for (row, cells) in table.rows.iter().enumerate() {
            for (cell, lines) in cells.iter().zip(&lines[row]) {
                if cell.rowspan == 1 {
                    heights[row] = f64::max(heights[row], cell_height(lines));
                } else {
                    spans.push((row + cell.rowspan - 1, row, cell_height(lines)));
                }
            }
        }
        // A spanning cell taller than its rows lengthens the last of them,
        // settled from the spans that end first.
        spans.sort_by_key(|&(last, first, _)| (last, first));
        for (last, first, height) in spans {
            let have: f64 = heights[first..=last].iter().sum();
            if height > have {
                heights[last] += height - have;
            }
        }

        let mut units = Vec::new();
        let mut start = table.header_rows;
        while start < table.rows.len() {
            let mut end = start + 1;
            let mut row = start;
            while row < end {
                for cell in &table.rows[row] {
                    end = end.max(row + cell.rowspan);
                }
                row += 1;
            }
            units.push(start..end);
            start = end;
        }

        let measured = Measured {
            table,
            edges,
            header: heights[..table.header_rows].iter().sum(),
            heights,
            lines,
            units,
            line,
            above_baseline: self.above_baseline(table.face, table.size, line),
        };

        let page_room = self.page().height - self.margins.top - self.margins.bottom;
        let tallest = measured
            .units
            .iter()
            .map(|unit| (unit, measured.least(unit)))
            .max_by(|a, b| a.1.total_cmp(&b.1));
        let (rows, needed) = match tallest {
            Some((unit, least)) => ((unit.start, unit.end - 1), measured.header + least),
            None => ((0, table.header_rows.saturating_sub(1)), measured.header),
        };
        if needed > page_room + FIT_TOLERANCE {
            return Err(Refused::TableTooTall {
                op,
                page,
                rows,
                needed,
                room: page_room,
            });
        }

        // On a page of its own, each unit must take its notes, and a row that
        // splits must take each next line with the notes it references, or
        // the row would turn pages without placing anything.
        let note_line = self.note_line();
        for unit in &measured.units {
            let parts: Vec<(f64, Vec<usize>)> = if unit.len() > 1 {
                vec![(
                    measured.unit_height(unit),
                    measured.notes_in(unit.clone(), 0..usize::MAX),
                )]
            } else {
                let longest = measured.lines[unit.start]
                    .iter()
                    .map(Vec::len)
                    .max()
                    .unwrap_or(0);
                (0..longest)
                    .map(|at| {
                        (
                            measured.line + 2.0 * padding,
                            measured.notes_in(unit.clone(), at..at + 1),
                        )
                    })
                    .collect()
            };
            for (height, notes) in parts {
                let rows = self.note_rows(op, &notes, true)?;
                let needed = measured.header + height + rows as f64 * note_line;
                if rows > 0 && needed > page_room + FIT_TOLERANCE {
                    return Err(Refused::NotesTooTall {
                        op,
                        page,
                        needed,
                        room: page_room,
                    });
                }
            }
        }

        Ok(measured)
    }

    fn column_widths(
        &self,
        op: usize,
        page: usize,
        table: &Table,
        room: f64,
    ) -> Result<Vec<f64>, Refused> {
        let padding = 2.0 * table.padding;
        let size = table.size;
        let mut natural = vec![0.0_f64; table.widths.len()];
        let mut least = vec![0.0_f64; table.widths.len()];
        for cell in table.rows.iter().flatten() {
            if cell.colspan != 1 || !matches!(table.widths[cell.column], Width::Auto) {
                continue;
            }
            let lines = wrap(self.fonts, &cell.runs, size, f64::INFINITY).unwrap_or_default();
            for segments in lines {
                let width: f64 = segments.iter().map(|segment| segment.width).sum();
                natural[cell.column] = natural[cell.column].max(width);
            }
            // Measured as `split_word` breaks a word, so a mark counts with
            // the character before it.
            for token in tokens(&cell.runs) {
                let Token::Word(pieces) = token else { continue };
                for unit in units(&pieces) {
                    let width: f64 = unit.iter().map(|span| span.width(self.fonts, size)).sum();
                    least[cell.column] = least[cell.column].max(width);
                }
            }
        }

        let (mut fixed, mut weights, mut natural_sum, mut least_sum) = (0.0, 0.0, 0.0, 0.0);
        for (column, width) in table.widths.iter().enumerate() {
            match *width {
                Width::Points(points) => fixed += points,
                Width::Weight(weight) => weights += weight,
                Width::Auto => {
                    natural[column] = natural[column].max(least[column]) + padding;
                    least[column] += padding;
                    natural_sum += natural[column];
                    least_sum += least[column];
                }
            }
        }

        let left = room - fixed - natural_sum;
        let scale = if left >= -FIT_TOLERANCE {
            1.0
        } else if weights > 0.0 {
            return Err(Refused::NoRoomForWeights { op, page });
        } else if fixed + least_sum > room + FIT_TOLERANCE {
            return Err(Refused::ColumnsTooWide {
                op,
                page,
                needed: fixed + least_sum,
                room,
            });
        } else if natural_sum > least_sum {
            (room - fixed - least_sum) / (natural_sum - least_sum)
        } else {
            0.0
        };

        table
            .widths
            .iter()
            .enumerate()
            .map(|(column, width)| match *width {
                Width::Points(points) => Ok(points),
                Width::Auto => Ok(least[column] + (natural[column] - least[column]) * scale),
                Width::Weight(weight) => {
                    let share = left.max(0.0) * weight / weights;
                    if share > padding {
                        Ok(share)
                    } else {
                        Err(Refused::NoRoomForWeights { op, page })
                    }
                }
            })
            .collect()
    }

    fn place_rows(&mut self, measured: &Measured, rows: Range<usize>, drawn: &mut Drawn) {
        let mut top = self.cursor;
        for row in rows {
            for (cell, lines) in measured.table.rows[row].iter().zip(&measured.lines[row]) {
                let height = measured.heights[row..row + cell.rowspan].iter().sum();
                place_cell(measured, row, cell, lines.clone(), [top, height], drawn);
            }
            top -= measured.heights[row];
            self.cursor = top;
            self.fresh = false;
        }
    }

    fn split_row(
        &mut self,
        op: usize,
        measured: &Measured,
        row: usize,
        drawn: &mut Drawn,
    ) -> Result<(), Refused> {
        let padding = 2.0 * measured.table.padding;
        let mut from = vec![0; measured.table.rows[row].len()];
        // Lines placed from each cell, until a cell runs out.
        let mut done = 0;
        let mut turned = false;
        loop {
            // A row with no text is still drawn one line tall.
            let remaining = measured.lines[row]
                .iter()
                .zip(&from)
                .map(|(lines, &from)| lines.len() - from)
                .max()
                .unwrap_or(0)
                .max(1);
            let room = self.cursor - self.floor() - padding + FIT_TOLERANCE;
            let mut fit = (room / measured.line).floor().max(0.0) as usize;
            if measured.has_notes(row, done) {
                fit = fit.min(remaining);
                while fit > 0 {
                    let notes = measured.notes_in(row..row + 1, done..done + fit);
                    if fit as f64 * measured.line + self.notes_height(op, &notes)? <= room {
                        break;
                    }
                    fit -= 1;
                }
            }

            let count = fit.min(remaining);
            if count > 0 {
                let notes = measured.notes_in(row..row + 1, done..done + count);
                self.reserve(op, count as f64 * measured.line + padding, &notes)?;
                self.place_fragment(measured, row, &mut from, count, drawn);
                done += count;
                if count == remaining {
                    return Ok(());
                }
            } else if turned {
                // `measure` has refused a line too tall with its notes for a
                // page of its own; this keeps the loop finite regardless.
                let notes = measured.notes_in(row..row + 1, done..done + 1);
                let rows = self.note_rows(op, &notes, true)?;
                return Err(Refused::NotesTooTall {
                    op,
                    page: self.pages.len() - 1,
                    needed: measured.header
                        + measured.line
                        + padding
                        + rows as f64 * self.note_line(),
                    room: self.page().height - self.margins.top - self.margins.bottom,
                });
            }
            self.turn_page(op, measured, drawn)?;
            turned = true;
        }
    }

    fn place_fragment(
        &mut self,
        measured: &Measured,
        row: usize,
        from: &mut [usize],
        count: usize,
        drawn: &mut Drawn,
    ) {
        let top = self.cursor;
        let height = count.max(1) as f64 * measured.line + 2.0 * measured.table.padding;
        let cells = measured.table.rows[row].iter().zip(&measured.lines[row]);
        for ((cell, lines), from) in cells.zip(from.iter_mut()) {
            let to = (*from + count).min(lines.len());
            let part = lines[*from..to].to_vec();
            *from = to;
            place_cell(measured, row, cell, part, [top, height], drawn);
        }
        self.cursor = top - height;
        self.fresh = false;
    }

    fn turn_page(
        &mut self,
        op: usize,
        measured: &Measured,
        drawn: &mut Drawn,
    ) -> Result<(), Refused> {
        self.paint(op, measured, std::mem::take(drawn))?;
        self.break_page();
        self.place_rows(measured, 0..measured.table.header_rows, drawn);
        Ok(())
    }

    fn paint(&mut self, op: usize, measured: &Measured, drawn: Drawn) -> Result<(), Refused> {
        let table = measured.table;
        let page = self.page_mut();
        for &(rect, fill) in &drawn.boxes {
            if let Some(fill) = fill {
                page.items.push(Item::Path(Shape {
                    operations: rectangle(rect),
                    stroke: None,
                    fill: Some(fill),
                }));
            }
        }
        self.place_positioned(op, drawn.lines, table.size, NO_EXTENT, true)?;
        if let Some(stroke) = &table.stroke {
            let page = self.page_mut();
            for &(rect, _) in &drawn.boxes {
                page.items.push(Item::Path(Shape {
                    operations: rectangle(rect),
                    stroke: Some(stroke.clone()),
                    fill: None,
                }));
            }
        }
        Ok(())
    }
}

fn place_cell(
    measured: &Measured,
    row: usize,
    cell: &Cell,
    lines: Vec<Vec<Segment>>,
    [top, height]: [f64; 2],
    drawn: &mut Drawn,
) {
    let table = measured.table;
    let padding = table.padding;
    let left = measured.edges[cell.column];
    let width = measured.edges[cell.column + cell.colspan] - left;
    let fill = cell
        .fill
        .or(table.header_fill.filter(|_| row < table.header_rows));
    drawn
        .boxes
        .push(([left, top - height, width, height], fill));
    drawn.lines.extend(boxed_lines(
        lines,
        [left + padding, top - padding, width - 2.0 * padding],
        cell.align,
        measured.above_baseline,
        measured.line,
    ));
}

fn rectangle([x, y, width, height]: [f64; 4]) -> Vec<PathOperation> {
    vec![PathOperation::Rectangle(
        x as f32,
        y as f32,
        width as f32,
        height as f32,
    )]
}
