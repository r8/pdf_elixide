use std::ops::Range;

use pdf_oxide::elements::PathOperation;

use super::{
    references, side_by_side, wrap, Item, Layout, Refused, Run, Segment, Shape, Stroke, Within,
    FIT_TOLERANCE, RULE_GRAY, RULE_WIDTH,
};

pub struct Columns {
    pub paragraphs: Vec<Vec<Run>>,
    pub face: usize,
    pub size: f64,
    pub count: usize,
    pub gap: f64,
    pub rule: bool,
    pub balance: bool,
}

impl Layout<'_> {
    pub(super) fn columns(&mut self, op: usize, columns: &Columns) -> Result<(), Refused> {
        let Columns {
            paragraphs,
            face,
            size,
            count,
            gap,
            rule,
            balance,
        } = columns;
        let (size, count, gap) = (*size, *count, *gap);
        let texts: Vec<&[Run]> = paragraphs.iter().map(Vec::as_slice).collect();
        let block = self.block(op, &texts, &[], *face, size)?;

        let left = self.margins.left;
        let room = self.page().width - left - self.margins.right;
        // Spelled as the Elixir check spells it, so both refuse the same layouts.
        let width = (room - gap * (count - 1) as f64) / count as f64;
        if width <= 0.0 {
            return Err(Refused::NoColumnWidth {
                op,
                page: block.page,
                count,
                gap,
                room,
            });
        }

        // Each line with the space above it, which a column top drops.
        let mut lines: Vec<(f64, Vec<Segment>)> = Vec::new();
        for (index, runs) in paragraphs.iter().enumerate() {
            let wrapped =
                wrap(self.fonts, runs, size, width).map_err(|(cluster, cluster_width)| {
                    Refused::ClusterTooWide {
                        op,
                        page: block.page,
                        cluster,
                        width: cluster_width,
                        room: width,
                        within: Within::Column,
                    }
                })?;
            for (line, segments) in wrapped.into_iter().enumerate() {
                let above = if index > 0 && line == 0 {
                    0.5 * size
                } else {
                    0.0
                };
                lines.push((above, segments));
            }
        }
        let gaps: Vec<f64> = lines.iter().map(|&(above, _)| above).collect();
        let notes: Vec<Vec<usize>> = lines
            .iter()
            .map(|(_, segments)| references(segments).collect())
            .collect();
        let line = block.line;

        let mut start = 0;
        while start < lines.len() {
            if !self.fresh {
                let spaced = self.cursor - self.pending_space;
                if self.fits(spaced, line + self.notes_height(op, &notes[start])?) {
                    self.cursor = spaced;
                } else {
                    self.break_page();
                }
            }
            self.pending_space = 0.0;
            self.resolve_anchors();

            let top = self.cursor;
            let available = top - self.floor();
            let (take, cap) =
                self.share(op, &gaps[start..], &notes[start..], line, count, available)?;
            let rest = &gaps[start..start + take];
            let (mut filled, _) = fill(rest, line, count, cap);
            if *balance
                && start + take == lines.len()
                && filled.last().is_some_and(|column| column.end == rest.len())
            {
                (filled, _) = fill(rest, line, count, balanced(rest, line, count, cap));
            }
            let placed = filled.last().map_or(0, |column| column.end);
            let placed_notes: Vec<usize> = notes[start..start + placed].concat();

            let mut tallest: f64 = 0.0;
            for (column, range) in filled.iter().enumerate() {
                let x = left + column as f64 * (width + gap);
                let mut y = top;
                for at in range.clone() {
                    if at != range.start {
                        y -= rest[at];
                    }
                    let segments = std::mem::take(&mut lines[start + at].1);
                    let baseline = y - block.above_baseline;
                    self.emit_line(op, baseline, side_by_side(x, segments).collect(), size)?;
                    y -= line;
                }
                tallest = tallest.max(top - y);
            }

            if *rule {
                for column in 1..filled.len() {
                    let x = (left + column as f64 * (width + gap) - gap / 2.0) as f32;
                    self.page_mut().items.push(Item::Path(Shape {
                        operations: vec![
                            PathOperation::MoveTo(x, top as f32),
                            PathOperation::LineTo(x, (top - tallest) as f32),
                        ],
                        stroke: Some(Stroke {
                            color: [RULE_GRAY; 3],
                            width: RULE_WIDTH,
                            dash: None,
                        }),
                        fill: None,
                    }));
                }
            }

            self.reserve(op, tallest, &placed_notes)?;
            self.cursor = top - tallest;
            self.fresh = false;
            start += placed;
            if start < lines.len() {
                self.break_page();
            }
        }

        self.pending_space = 0.5 * size;
        Ok(())
    }

    // How many of the remaining lines this page takes, and the column height
    // they fill to above the notes they reference. Columns and notes both
    // grow with the lines taken, so the most that fit is found by bisection.
    fn share(
        &self,
        op: usize,
        above: &[f64],
        notes: &[Vec<usize>],
        line: f64,
        count: usize,
        available: f64,
    ) -> Result<(usize, f64), Refused> {
        if notes.iter().all(Vec::is_empty) {
            return Ok((above.len(), available));
        }
        let notes_for = |taken: usize| self.notes_height(op, &notes[..taken].concat());
        let fits = |taken: usize| -> Result<bool, Refused> {
            Ok(
                least_height(&above[..taken], line, count) + notes_for(taken)?
                    <= available + FIT_TOLERANCE,
            )
        };

        if !fits(1)? {
            // The page has turned already when the first line did not fit.
            let needed = line + notes_for(1)?;
            return Err(Refused::NotesTooTall {
                op,
                page: self.pages.len() - 1,
                needed,
                room: self.page().height - self.margins.top - self.margins.bottom,
            });
        }
        let (mut low, mut high) = (1, above.len());
        while low < high {
            let middle = low + (high - low).div_ceil(2);
            if fits(middle)? {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        Ok((low, available - notes_for(low)?))
    }
}

// Return column ranges and the least height rejected by the fit comparison.
fn fill(above: &[f64], line: f64, count: usize, cap: f64) -> (Vec<Range<usize>>, f64) {
    // A count far above the lines must not size the allocation.
    let mut columns = Vec::with_capacity(count.min(above.len()));
    let mut refused = f64::INFINITY;
    let mut start = 0;
    while columns.len() < count && start < above.len() {
        let mut end = start + 1;
        let mut used = line;
        while end < above.len() {
            let grown = used + above[end] + line;
            if grown > cap + FIT_TOLERANCE {
                refused = refused.min(grown);
                break;
            }
            used = grown;
            end += 1;
        }
        columns.push(start..end);
        start = end;
    }
    (columns, refused)
}

// The tallest column when `above`'s lines are balanced. A cap can exceed it:
// the lower bound counts a gap that a column top drops.
fn least_height(above: &[f64], line: f64, count: usize) -> f64 {
    let (columns, _) = fill(
        above,
        line,
        count,
        balanced(above, line, count, f64::INFINITY),
    );
    columns
        .iter()
        .map(|column| {
            above[column.start + 1..column.end]
                .iter()
                .fold(line, |used, space| used + space + line)
        })
        .fold(0.0, f64::max)
}

// Use fill's exact rejected heights so each step advances despite rounding.
// Stop at the known fitting available height: rounded fits can be non-monotonic.
fn balanced(above: &[f64], line: f64, count: usize, available: f64) -> f64 {
    // Below any working height, even if the widest spaces fall at column tops.
    let total: f64 = above.iter().map(|space| space + line).sum();
    let widest = above.iter().copied().fold(0.0, f64::max);
    let mut cap = ((total - widest * (count - 1) as f64) / count as f64).max(line);
    loop {
        if cap >= available {
            return available;
        }
        let (columns, refused) = fill(above, line, count, cap);
        if columns
            .last()
            .is_some_and(|column| column.end == above.len())
        {
            return cap;
        }
        cap = refused;
    }
}
