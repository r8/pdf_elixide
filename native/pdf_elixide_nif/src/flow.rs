use std::collections::HashSet;

use pdf_oxide::writer::EmbeddedFont;
use unicode_bidi::{bidi_class, BidiClass};
use unicode_normalization::char::canonical_combining_class;
use unicode_properties::{GeneralCategory, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

use crate::base14::Base14;

// A fit test on accumulated f64 positions must not lose a line that fits
// exactly, so a box may cross the bottom margin, and flowing ink the page
// edge, by this much.
const FIT_TOLERANCE: f64 = 1.0e-6;

// Limit coordinate rounding so distinct lines and runs cannot merge on emission.
const PRECISION_STEPS: f64 = 131_072.0;

pub enum Face<'f> {
    Base14(&'static Base14),
    Embedded(Box<Embedded<'f>>),
}

pub struct Embedded<'f> {
    pub font: EmbeddedFont,
    // The characters the font's own cmap maps. Upstream's `glyph_id` also
    // answers for some it lacks, drawing `*` for `•` and `-` for a dash.
    pub coverage: HashSet<char>,
    // Glyph outlines, which `EmbeddedFont` does not expose.
    pub outlines: ttf_parser::Face<'f>,
}

pub struct Fonts<'f> {
    faces: Vec<Face<'f>>,
}

impl<'f> Fonts<'f> {
    pub fn new() -> Self {
        Self { faces: Vec::new() }
    }

    pub fn add(&mut self, face: Face<'f>) -> usize {
        self.faces.push(face);
        self.faces.len() - 1
    }

    pub fn key(&self, face: usize) -> String {
        match &self.faces[face] {
            Face::Base14(base14) => base14.name.to_string(),
            Face::Embedded(_) => embedded_key(face),
        }
    }

    fn display_name(&self, face: usize) -> &str {
        match &self.faces[face] {
            Face::Base14(base14) => base14.name,
            Face::Embedded(embedded) => &embedded.font.name,
        }
    }

    pub fn covers(&self, face: usize, c: char) -> bool {
        match &self.faces[face] {
            Face::Base14(base14) => base14.width(c).is_some(),
            Face::Embedded(embedded) => embedded.coverage.contains(&c),
        }
    }

    // Widths and metrics are in thousandths of an em. A character a face
    // cannot draw is refused before it is measured.
    fn char_units(&self, face: usize, c: char) -> f64 {
        match &self.faces[face] {
            Face::Base14(base14) => f64::from(base14.width(c).unwrap_or(0)),
            Face::Embedded(embedded) => f64::from(embedded.font.char_width(u32::from(c))),
        }
    }

    fn width(&self, face: usize, text: &str, size: f64) -> f64 {
        text.chars().map(|c| self.char_units(face, c)).sum::<f64>() * size / 1000.0
    }

    // A glyph's ink box in thousandths of an em from its origin, or `None`
    // when it draws nothing.
    fn char_bounds(&self, face: usize, c: char) -> Option<[f64; 4]> {
        match &self.faces[face] {
            Face::Base14(base14) => base14.bounds(c),
            Face::Embedded(embedded) => {
                let outlines = &embedded.outlines;
                let rect = outlines.glyph_bounding_box(outlines.glyph_index(c)?)?;
                let scale = 1000.0 / f64::from(outlines.units_per_em());
                Some(
                    [rect.x_min, rect.y_min, rect.x_max, rect.y_max]
                        .map(|value| f64::from(value) * scale),
                )
            }
        }
    }

    fn ascent_descent(&self, face: usize) -> (f64, f64) {
        match &self.faces[face] {
            Face::Base14(base14) => (base14.ascent, base14.descent),
            Face::Embedded(embedded) => (
                f64::from(embedded.font.ascender),
                f64::from(embedded.font.descender),
            ),
        }
    }
}

pub struct Margins {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
}

pub fn embedded_key(face: usize) -> String {
    format!("builder-face-{face}")
}

pub type Rgb = [f32; 3];

pub struct Run {
    pub text: String,
    pub face: usize,
    pub color: Option<Rgb>,
}

impl Run {
    fn styled(&self, text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            face: self.face,
            color: self.color,
        }
    }

    fn same_style(&self, other: &Run) -> bool {
        self.face == other.face && self.color == other.color
    }
}

pub enum Op {
    // A block that draws nothing, kept so later ops keep their numbers.
    Empty,
    Page {
        width: f64,
        height: f64,
    },
    // A heading is a paragraph kept on the page of the line after it.
    Paragraph {
        runs: Vec<Run>,
        face: usize,
        size: f64,
        keep_with_next: bool,
    },
    List {
        items: Vec<Vec<Run>>,
        face: usize,
        size: f64,
        marker: Marker,
        start: usize,
    },
    Space(f64),
    Rule {
        size: f64,
    },
    // One line with its baseline starting at a point, outside the flow.
    TextAt {
        runs: Vec<Run>,
        size: f64,
        x: f64,
        y: f64,
    },
}

#[derive(Clone, Copy)]
pub enum Marker {
    Bullet,
    Decimal,
    LowerRoman,
    LowerAlpha,
}

impl Marker {
    fn label(self, number: usize) -> String {
        match self {
            Marker::Bullet => "\u{2022}".to_string(),
            Marker::Decimal => format!("{number}."),
            Marker::LowerRoman => format!("{}.", roman(number)),
            Marker::LowerAlpha => format!("{}.", alpha(number)),
        }
    }
}

// Numbers past 3999 have no Roman numeral; the Elixir side refuses them.
fn roman(mut number: usize) -> String {
    const NUMERALS: [(usize, &str); 13] = [
        (1000, "m"),
        (900, "cm"),
        (500, "d"),
        (400, "cd"),
        (100, "c"),
        (90, "xc"),
        (50, "l"),
        (40, "xl"),
        (10, "x"),
        (9, "ix"),
        (5, "v"),
        (4, "iv"),
        (1, "i"),
    ];
    let mut out = String::new();
    for (value, numeral) in NUMERALS {
        while number >= value {
            out.push_str(numeral);
            number -= value;
        }
    }
    out
}

// a … z, then aa … az, ba …, as spreadsheet columns are lettered.
fn alpha(mut number: usize) -> String {
    let mut letters = Vec::new();
    while number > 0 {
        number -= 1;
        letters.push(char::from(b'a' + (number % 26) as u8));
        number /= 26;
    }
    letters.iter().rev().collect()
}

pub struct Placed {
    pub x: f64,
    pub baseline: f64,
    pub width: f64,
    pub text: String,
    pub face: usize,
    pub size: f64,
    pub color: Option<Rgb>,
}

pub struct PagePlan {
    pub width: f64,
    pub height: f64,
    // In the order the ops drew them, so later ops paint over earlier ones.
    pub items: Vec<Item>,
}

pub enum Item {
    Text(Placed),
    Rule(RuleLine),
}

pub struct RuleLine {
    pub from: f64,
    pub to: f64,
    pub y: f64,
}

pub enum Refused {
    LineTooTall {
        op: usize,
        page: usize,
        line: f64,
        room: f64,
    },
    NoWidth {
        op: usize,
        page: usize,
    },
    ClusterTooWide {
        op: usize,
        page: usize,
        cluster: String,
        width: f64,
        room: f64,
    },
    Imprecise {
        op: usize,
        page: usize,
        size: f64,
    },
    Undrawable {
        op: usize,
        page: usize,
        character: char,
        face: String,
        built_in: bool,
    },
    Unordered {
        op: usize,
        page: usize,
        character: char,
        reason: Unordered,
    },
    CounterOverflow {
        op: usize,
        page: usize,
    },
    OffPage {
        op: usize,
        page: usize,
        flowing: bool,
    },
}

// Text is drawn character by character in logical order, with no bidi
// reordering and no shaping, so these come out reversed, unjoined or with
// letters misplaced.
#[derive(Clone, Copy)]
pub enum Unordered {
    RightToLeft,
    NeedsShaping,
}

// Scripts whose letters reorder, join or form conjuncts left to right with no
// spacing vowel sign or virama to show it. The right-to-left ones (Arabic,
// Syriac, N'Ko and so on) are caught by bidi class.
const SHAPED_BLOCKS: &[(u32, u32)] = &[
    (0x0900, 0x0DFF), // Devanagari through Sinhala
    (0x0F00, 0x0FFF), // Tibetan
    (0x1000, 0x109F), // Myanmar
    (0x1100, 0x11FF), // Hangul Jamo
    (0x1780, 0x18AF), // Khmer, Mongolian
    (0x19E0, 0x19FF), // Khmer Symbols
    (0x1A20, 0x1AAF), // Tai Tham
    (0x1B00, 0x1BBF), // Balinese, Sundanese
    (0xA840, 0xA87F), // Phags-pa
    (0xA8E0, 0xA8FF), // Devanagari Extended
    (0xA960, 0xA97F), // Hangul Jamo Extended-A
    (0xA980, 0xA9FF), // Javanese, Myanmar Extended-B
    (0xAA60, 0xAA7F), // Myanmar Extended-A
    (0xD7B0, 0xD7FF), // Hangul Jamo Extended-B
];

fn unordered(c: char) -> Option<Unordered> {
    if matches!(
        bidi_class(c),
        BidiClass::R | BidiClass::AL | BidiClass::RLE | BidiClass::RLO | BidiClass::RLI
    ) {
        return Some(Unordered::RightToLeft);
    }

    let code = u32::from(c);
    // A spacing vowel sign may be drawn before its consonant, and a virama
    // forms conjuncts, in every script that has one. Thai and Lao use theirs
    // only to mark a bare consonant.
    let shaped_mark = c.general_category() == GeneralCategory::SpacingMark
        || (canonical_combining_class(c) == 9 && !(0x0E00..=0x0EFF).contains(&code));

    (shaped_mark
        || SHAPED_BLOCKS
            .iter()
            .any(|&(first, last)| (first..=last).contains(&code)))
    .then_some(Unordered::NeedsShaping)
}

pub fn lay_out(
    fonts: &Fonts,
    margins: &Margins,
    line_height: f64,
    first_page: (f64, f64),
    ops: &[Op],
) -> Result<Vec<PagePlan>, Refused> {
    let mut layout = Layout {
        fonts,
        margins,
        line_height,
        first_page,
        pages: Vec::new(),
        cursor: 0.0,
        fresh: true,
        pending_space: 0.0,
    };

    for (index, op) in ops.iter().enumerate() {
        match op {
            Op::Empty => {}
            Op::Page { width, height } => layout.new_page(*width, *height),
            Op::Paragraph {
                runs,
                face,
                size,
                keep_with_next,
            } => {
                // The lookahead measures headings against the current page.
                layout.ensure_page();
                let kept = keep_with_next.then(|| layout.kept_after(&ops[index + 1..], *size));
                layout.paragraph(index, runs, *face, *size, kept)?;
            }
            Op::List {
                items,
                face,
                size,
                marker,
                start,
            } => layout.list(index, items, *face, *size, *marker, *start)?,
            Op::Space(points) => layout.space(*points),
            Op::Rule { size } => layout.rule(*size),
            Op::TextAt { runs, size, x, y } => layout.text_at(index, runs, *size, *x, *y)?,
        }
    }

    layout.ensure_page();
    Ok(layout.pages)
}

// What a block's checks establish before any of its lines is placed.
struct Block {
    op: usize,
    line: f64,
    above_baseline: f64,
    page: usize,
}

struct Layout<'a> {
    fonts: &'a Fonts<'a>,
    margins: &'a Margins,
    line_height: f64,
    first_page: (f64, f64),
    pages: Vec<PagePlan>,
    // Top of the next line box.
    cursor: f64,
    // No line has been placed on the current page yet.
    fresh: bool,
    // Space owed after the previous block, dropped if a page break comes first.
    pending_space: f64,
}

impl Layout<'_> {
    fn ensure_page(&mut self) {
        if self.pages.is_empty() {
            let (width, height) = self.first_page;
            self.new_page(width, height);
        }
    }

    fn page(&self) -> &PagePlan {
        self.pages
            .last()
            .expect("a page exists once ensure_page has run")
    }

    fn new_page(&mut self, width: f64, height: f64) {
        self.pages.push(PagePlan {
            width,
            height,
            items: Vec::new(),
        });
        self.cursor = height - self.margins.top;
        self.fresh = true;
        self.pending_space = 0.0;
    }

    fn break_page(&mut self) {
        let (width, height) = (self.page().width, self.page().height);
        self.new_page(width, height);
    }

    fn block(
        &mut self,
        op: usize,
        texts: &[&[Run]],
        extra: &[(usize, &str)],
        face: usize,
        size: f64,
    ) -> Result<Block, Refused> {
        self.ensure_page();

        let page = self.page();
        let page_index = self.pages.len() - 1;
        // Spelled as the Elixir check spells it, so both refuse the same lines.
        let line = size * self.line_height;
        let room = page.height - self.margins.top - self.margins.bottom;
        if line > room {
            return Err(Refused::LineTooTall {
                op,
                page: page_index,
                line,
                room,
            });
        }

        if page.width.max(page.height) > size.min(line) * PRECISION_STEPS {
            return Err(Refused::Imprecise {
                op,
                page: page_index,
                size,
            });
        }

        self.drawable(op, page_index, texts, extra)?;

        let (ascent, descent) = self.fonts.ascent_descent(face);
        let half_leading = (line - (ascent - descent) * size / 1000.0) / 2.0;

        Ok(Block {
            op,
            line,
            above_baseline: half_leading + ascent * size / 1000.0,
            page: page_index,
        })
    }

    // Every character drawn, the runs' and any marker's, must be laid out in
    // order and present in its face.
    fn drawable(
        &self,
        op: usize,
        page_index: usize,
        texts: &[&[Run]],
        extra: &[(usize, &str)],
    ) -> Result<(), Refused> {
        let drawn = || {
            texts
                .iter()
                .flat_map(|runs| runs.iter())
                .flat_map(|run| run.text.chars().map(move |c| (run.face, c)))
                .chain(
                    extra
                        .iter()
                        .flat_map(|&(face, text)| text.chars().map(move |c| (face, c))),
                )
        };

        if let Some((character, reason)) =
            drawn().find_map(|(_, c)| unordered(c).map(|reason| (c, reason)))
        {
            return Err(Refused::Unordered {
                op,
                page: page_index,
                character,
                reason,
            });
        }

        // A base-14 font would draw `?` and an embedded one an empty box.
        // Whitespace is drawn as a space in its run's face, and `\n` not at all.
        if let Some((face, character)) = drawn()
            .filter(|&(_, c)| c != '\n')
            .map(|(face, c)| (face, if c.is_whitespace() { ' ' } else { c }))
            .find(|&(face, c)| !self.fonts.covers(face, c))
        {
            return Err(Refused::Undrawable {
                op,
                page: page_index,
                character,
                face: self.fonts.display_name(face).to_string(),
                built_in: matches!(self.fonts.faces[face], Face::Base14(_)),
            });
        }

        Ok(())
    }

    fn content_width(&self, op: usize, page: usize, left: f64) -> Result<f64, Refused> {
        let width = self.page().width - left - self.margins.right;
        if width <= 0.0 {
            return Err(Refused::NoWidth { op, page });
        }
        Ok(width)
    }

    fn wrapped(
        &self,
        op: usize,
        page: usize,
        runs: &[Run],
        size: f64,
        width: f64,
    ) -> Result<Vec<Vec<Segment>>, Refused> {
        wrap(self.fonts, runs, size, width).map_err(|(cluster, cluster_width)| {
            Refused::ClusterTooWide {
                op,
                page,
                cluster,
                width: cluster_width,
                room: width,
            }
        })
    }

    fn paragraph(
        &mut self,
        op: usize,
        runs: &[Run],
        face: usize,
        size: f64,
        kept: Option<f64>,
    ) -> Result<(), Refused> {
        let block = self.block(op, &[runs], &[], face, size)?;
        let left = self.margins.left;
        let width = self.content_width(op, block.page, left)?;
        let lines = self.wrapped(op, block.page, runs, size, width)?;

        if let Some(kept) = kept {
            let needed = lines.len() as f64 * block.line + kept;
            if !self.fresh && !self.fits(self.cursor - self.pending_space, needed) {
                self.break_page();
            }
        }

        for segments in lines {
            self.place_line(&block, segments, size, left, None)?;
        }

        self.pending_space = 0.5 * size;
        Ok(())
    }

    // Reserve following headings and spacing through the next content line,
    // looking through blocks that draw nothing.
    fn kept_after(&self, following: &[Op], size: f64) -> f64 {
        let mut gap = 0.5 * size;
        let mut total = 0.0;
        for op in following {
            match op {
                Op::Empty => {}
                Op::Space(points) => gap += points,
                Op::Paragraph {
                    runs,
                    size,
                    keep_with_next: true,
                    ..
                } => {
                    total += gap + self.line_count(runs, *size) as f64 * size * self.line_height;
                    gap = 0.5 * size;
                }
                Op::Paragraph { size, .. } | Op::List { size, .. } => {
                    return total + gap + size * self.line_height;
                }
                Op::Rule { size } => return total + gap + size,
                Op::Page { .. } => return total,
                Op::TextAt { .. } => {}
            }
        }
        total
    }

    // A heading too wide to wrap is refused when it is placed; here it counts
    // as one line.
    fn line_count(&self, runs: &[Run], size: f64) -> usize {
        let width = self.page().width - self.margins.left - self.margins.right;
        wrap(self.fonts, runs, size, width).map_or(1, |lines| lines.len())
    }

    fn list(
        &mut self,
        op: usize,
        items: &[Vec<Run>],
        face: usize,
        size: f64,
        marker: Marker,
        start: usize,
    ) -> Result<(), Refused> {
        self.ensure_page();
        let labels = (0..items.len())
            .map(|offset| start.checked_add(offset).map(|number| marker.label(number)))
            .collect::<Option<Vec<String>>>()
            .ok_or(Refused::CounterOverflow {
                op,
                page: self.pages.len() - 1,
            })?;
        let texts: Vec<&[Run]> = items.iter().map(Vec::as_slice).collect();
        let extra: Vec<(usize, &str)> = labels.iter().map(|label| (face, label.as_str())).collect();
        let block = self.block(op, &texts, &extra, face, size)?;

        // Markers are right-aligned in a column as wide as the widest, so the
        // text of every item starts at the same x.
        let gap = 0.5 * size;
        let widest = labels
            .iter()
            .map(|label| self.fonts.width(face, label, size))
            .fold(0.0, f64::max);
        let text_x = self.margins.left + 1.5 * size + widest + gap;
        let width = self.content_width(op, block.page, text_x)?;

        for (item, label) in items.iter().zip(labels) {
            let label_width = self.fonts.width(face, &label, size);
            let marker = Segment {
                text: label,
                face,
                color: None,
                width: label_width,
            };
            let mut lines = self.wrapped(op, block.page, item, size, width)?.into_iter();
            let first = lines.next().unwrap_or_default();
            self.place_line(
                &block,
                first,
                size,
                text_x,
                Some((text_x - gap - label_width, marker)),
            )?;
            for segments in lines {
                self.place_line(&block, segments, size, text_x, None)?;
            }
        }

        self.pending_space = 0.5 * size;
        Ok(())
    }

    fn text_at(
        &mut self,
        op: usize,
        runs: &[Run],
        size: f64,
        x: f64,
        y: f64,
    ) -> Result<(), Refused> {
        self.ensure_page();
        let page_index = self.pages.len() - 1;
        let (width, height) = (self.page().width, self.page().height);

        // Spelled as the Elixir check spells it.
        if width.max(height) > size * PRECISION_STEPS {
            return Err(Refused::Imprecise {
                op,
                page: page_index,
                size,
            });
        }
        self.drawable(op, page_index, &[runs], &[])?;

        let off_page = || Refused::OffPage {
            op,
            page: page_index,
            flowing: false,
        };
        let segments = wrap(self.fonts, runs, size, f64::INFINITY)
            .map_err(|_| off_page())?
            .into_iter()
            .next()
            .unwrap_or_default();

        // Neither the line's box nor any glyph's ink, which can overhang its
        // advance or rise above the ascent, may cross the edge.
        let mut extent = [x, y, x, y];
        let mut pen = x;
        for segment in &segments {
            let (ascent, descent) = self.fonts.ascent_descent(segment.face);
            extent[1] = extent[1].min(y + descent * size / 1000.0);
            extent[3] = extent[3].max(y + ascent * size / 1000.0);
            pen = self.add_ink(&mut extent, segment, pen, y, size);
        }
        extent[2] = extent[2].max(pen);

        if extent[0] < 0.0 || extent[1] < 0.0 || extent[2] > width || extent[3] > height {
            return Err(off_page());
        }

        let page = self.pages.last_mut().expect("text_at ensured a page");
        let mut at = x;
        for segment in segments {
            page.items.push(Item::Text(Placed {
                x: at,
                baseline: y,
                width: segment.width,
                text: segment.text,
                face: segment.face,
                size,
                color: segment.color,
            }));
            at += segment.width;
        }
        Ok(())
    }

    // Widens `extent` to the ink of `segment` drawn from `pen` on `baseline`,
    // returning the pen after it.
    fn add_ink(
        &self,
        extent: &mut [f64; 4],
        segment: &Segment,
        mut pen: f64,
        baseline: f64,
        size: f64,
    ) -> f64 {
        for c in segment.text.chars() {
            if let Some([left, bottom, right, top]) = self.fonts.char_bounds(segment.face, c) {
                extent[0] = extent[0].min(pen + left * size / 1000.0);
                extent[1] = extent[1].min(baseline + bottom * size / 1000.0);
                extent[2] = extent[2].max(pen + right * size / 1000.0);
                extent[3] = extent[3].max(baseline + top * size / 1000.0);
            }
            pen += self.fonts.char_units(segment.face, c) * size / 1000.0;
        }
        pen
    }

    fn space(&mut self, points: f64) {
        if !self.fresh {
            self.pending_space += points;
        }
    }

    fn rule(&mut self, size: f64) {
        self.ensure_page();
        if !self.fresh {
            let spaced = self.cursor - self.pending_space;
            if self.fits(spaced, size) {
                self.cursor = spaced;
            } else {
                self.break_page();
            }
        }
        self.pending_space = 0.0;

        let (left, right) = (self.margins.left, self.margins.right);
        let y = self.cursor - size / 2.0;
        let page = self.pages.last_mut().expect("rule ensured a page");
        page.items.push(Item::Rule(RuleLine {
            from: left,
            to: page.width - right,
            y,
        }));

        self.cursor -= size;
        self.fresh = false;
    }

    fn fits(&self, top: f64, line: f64) -> bool {
        top - line >= self.margins.bottom - FIT_TOLERANCE
    }

    fn place_line(
        &mut self,
        block: &Block,
        segments: Vec<Segment>,
        size: f64,
        x: f64,
        marker: Option<(f64, Segment)>,
    ) -> Result<(), Refused> {
        if !self.fresh {
            let spaced = self.cursor - self.pending_space;
            self.pending_space = 0.0;
            // A page never breaks before its first line, so a line the refusal
            // above let through always lands somewhere.
            if self.fits(spaced, block.line) {
                self.cursor = spaced;
            } else {
                self.break_page();
            }
        }

        let baseline = self.cursor - block.above_baseline;
        let mut x = x;
        let placed: Vec<(f64, Segment)> = marker
            .into_iter()
            .chain(segments.into_iter().map(|segment| {
                let at = x;
                x += segment.width;
                (at, segment)
            }))
            .collect();

        // The line's box and advances are inside the margins, but a glyph's
        // ink can overhang its advance or rise above the ascent.
        let mut ink = [
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        for (at, segment) in &placed {
            self.add_ink(&mut ink, segment, *at, baseline, size);
        }
        let (width, height) = (self.page().width, self.page().height);
        if ink[0] < -FIT_TOLERANCE
            || ink[1] < -FIT_TOLERANCE
            || ink[2] > width + FIT_TOLERANCE
            || ink[3] > height + FIT_TOLERANCE
        {
            return Err(Refused::OffPage {
                op: block.op,
                page: self.pages.len() - 1,
                flowing: true,
            });
        }

        let page = self.pages.last_mut().expect("the block ensured a page");
        for (at, segment) in placed {
            page.items.push(Item::Text(Placed {
                x: at,
                baseline,
                width: segment.width,
                text: segment.text,
                face: segment.face,
                size,
                color: segment.color,
            }));
        }

        self.cursor -= block.line;
        self.fresh = false;
        Ok(())
    }
}

struct Segment {
    text: String,
    face: usize,
    color: Option<Rgb>,
    width: f64,
}

enum Token {
    Word(Vec<Run>),
    Space(Run),
    Break,
}

fn tokens(runs: &[Run]) -> Vec<Token> {
    let mut out = Vec::new();
    let mut word: Vec<Run> = Vec::new();

    let flush = |word: &mut Vec<Run>, out: &mut Vec<Token>| {
        if !word.is_empty() {
            out.push(Token::Word(std::mem::take(word)));
        }
    };

    for run in runs {
        for c in run.text.chars() {
            if c == '\n' {
                flush(&mut word, &mut out);
                out.push(Token::Break);
            } else if c.is_whitespace() {
                flush(&mut word, &mut out);
                if !matches!(out.last(), Some(Token::Space(_))) {
                    out.push(Token::Space(run.styled(" ")));
                }
            } else {
                match word.last_mut() {
                    Some(piece) if piece.same_style(run) => piece.text.push(c),
                    _ => word.push(run.styled(c)),
                }
            }
        }
    }
    flush(&mut word, &mut out);

    out
}

// `wrap` makes a line of every word and every `\n`, at any width, so text
// with neither draws nothing.
pub fn draws_nothing<'t>(texts: impl IntoIterator<Item = &'t str>) -> bool {
    texts
        .into_iter()
        .flat_map(str::chars)
        .all(|c| c != '\n' && c.is_whitespace())
}

#[derive(Default)]
struct Line {
    pieces: Vec<Run>,
    width: f64,
}

impl Line {
    fn push(&mut self, fonts: &Fonts, piece: Run, size: f64) {
        self.width += fonts.width(piece.face, &piece.text, size);
        match self.pieces.last_mut() {
            Some(last) if last.same_style(&piece) => last.text.push_str(&piece.text),
            _ => self.pieces.push(piece),
        }
    }

    fn segments(self, fonts: &Fonts, size: f64) -> Vec<Segment> {
        self.pieces
            .into_iter()
            .map(|piece| Segment {
                width: fonts.width(piece.face, &piece.text, size),
                text: piece.text,
                face: piece.face,
                color: piece.color,
            })
            .collect()
    }
}

type TooWide = (String, f64);

fn wrap(
    fonts: &Fonts,
    runs: &[Run],
    size: f64,
    max_width: f64,
) -> Result<Vec<Vec<Segment>>, TooWide> {
    let mut lines = Vec::new();
    let mut line = Line::default();
    let mut space: Option<Run> = None;

    let finish = |line: &mut Line, lines: &mut Vec<Vec<Segment>>| {
        lines.push(std::mem::take(line).segments(fonts, size));
    };

    for token in tokens(runs) {
        match token {
            Token::Break => {
                finish(&mut line, &mut lines);
                space = None;
            }
            Token::Space(run) => {
                if !line.pieces.is_empty() {
                    space = Some(run);
                }
            }
            Token::Word(pieces) => {
                let width: f64 = pieces
                    .iter()
                    .map(|p| fonts.width(p.face, &p.text, size))
                    .sum();
                let space_width = space
                    .as_ref()
                    .map_or(0.0, |run| fonts.width(run.face, &run.text, size));

                if !line.pieces.is_empty() && line.width + space_width + width <= max_width {
                    if let Some(run) = space.take() {
                        line.push(fonts, run, size);
                    }
                    for piece in pieces {
                        line.push(fonts, piece, size);
                    }
                } else {
                    if !line.pieces.is_empty() {
                        finish(&mut line, &mut lines);
                    }
                    if width <= max_width {
                        for piece in pieces {
                            line.push(fonts, piece, size);
                        }
                    } else {
                        for chunk in split_word(fonts, pieces, size, max_width)? {
                            if !line.pieces.is_empty() {
                                finish(&mut line, &mut lines);
                            }
                            for piece in chunk {
                                line.push(fonts, piece, size);
                            }
                        }
                    }
                }
                space = None;
            }
        }
    }

    if !line.pieces.is_empty() {
        finish(&mut line, &mut lines);
    }

    Ok(lines)
}

fn split_word(
    fonts: &Fonts,
    pieces: Vec<Run>,
    size: f64,
    max_width: f64,
) -> Result<Vec<Vec<Run>>, TooWide> {
    // Clusters are found across the whole word, since a style change can fall
    // inside one; each cluster keeps its styled spans together.
    let word: String = pieces.iter().map(|piece| piece.text.as_str()).collect();
    let mut starts = Vec::with_capacity(pieces.len());
    let mut offset = 0;
    for piece in &pieces {
        starts.push(offset);
        offset += piece.text.len();
    }

    let mut chunks: Vec<Vec<Run>> = Vec::new();
    let mut chunk: Vec<Run> = Vec::new();
    let mut width = 0.0;

    for (cluster_start, cluster) in word.grapheme_indices(true) {
        let cluster_end = cluster_start + cluster.len();
        let spans: Vec<Run> = pieces
            .iter()
            .zip(&starts)
            .filter_map(|(piece, &start)| {
                let from = cluster_start.max(start);
                let to = cluster_end.min(start + piece.text.len());
                (from < to).then(|| piece.styled(&word[from..to]))
            })
            .collect();
        let cluster_width: f64 = spans
            .iter()
            .map(|span| fonts.width(span.face, &span.text, size))
            .sum();

        if cluster_width > max_width {
            return Err((cluster.to_string(), cluster_width));
        }
        if !chunk.is_empty() && width + cluster_width > max_width {
            chunks.push(std::mem::take(&mut chunk));
            width = 0.0;
        }
        width += cluster_width;
        for span in spans {
            match chunk.last_mut() {
                Some(last) if last.same_style(&span) => last.text.push_str(&span.text),
                _ => chunk.push(span),
            }
        }
    }
    if !chunk.is_empty() {
        chunks.push(chunk);
    }

    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use pdf_oxide::{fonts::bundled::DEJAVU_SANS, writer::EmbeddedFont};

    use super::{lay_out, unordered, Embedded, Face, Fonts, Margins, Op, Refused, Run, Unordered};

    // DejaVu Sans with its cmap cut down to `covered`, as a font with no space
    // glyph would have it.
    fn laid_out(text: &str, covered: &str) -> Result<(), Refused> {
        let mut fonts = Fonts::new();
        fonts.add(Face::Embedded(Box::new(Embedded {
            font: EmbeddedFont::from_data(None, DEJAVU_SANS.to_vec()).expect("parses"),
            coverage: covered.chars().collect::<HashSet<char>>(),
            outlines: ttf_parser::Face::parse(DEJAVU_SANS, 0).expect("parses"),
        })));
        let margins = Margins {
            top: 72.0,
            bottom: 72.0,
            left: 72.0,
            right: 72.0,
        };
        let paragraph = Op::Paragraph {
            runs: vec![Run {
                text: text.to_string(),
                face: 0,
                color: None,
            }],
            face: 0,
            size: 12.0,
            keep_with_next: false,
        };

        lay_out(&fonts, &margins, 1.5, (612.0, 792.0), &[paragraph]).map(|_| ())
    }

    #[test]
    fn whitespace_needs_the_space_it_is_drawn_as() {
        for text in ["a b", "a\tb"] {
            let refused = laid_out(text, "ab");
            assert!(matches!(
                refused,
                Err(Refused::Undrawable { character: ' ', .. })
            ));
            assert!(laid_out(text, "ab ").is_ok());
        }
        assert!(laid_out("a\nb", "ab").is_ok());
    }

    #[test]
    fn a_virama_needs_shaping_except_in_thai_and_lao() {
        assert!(matches!(
            unordered('\u{11442}'),
            Some(Unordered::NeedsShaping)
        ));
        assert!(unordered('\u{0E3A}').is_none());
        assert!(unordered('\u{0EBA}').is_none());
        assert!(unordered('\u{0301}').is_none());
    }
}
