use std::collections::{HashMap, HashSet};

use pdf_oxide::{
    elements::PathOperation,
    extractors::page_labels::{PageLabelRange, PageLabelStyle},
    writer::EmbeddedFont,
};
use unicode_bidi::{bidi_class, BidiClass};
use unicode_normalization::char::canonical_combining_class;
use unicode_properties::{GeneralCategory, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

use crate::{
    barcode::dark_runs,
    base14::Base14,
    page_label::{self, MAX_LETTERED},
};

mod table;

pub use table::{Cell, Table, Width};

// A fit test on accumulated f64 positions must not lose a line that fits
// exactly, so a box may cross the bottom margin, a line its width, and ink
// the page edge, by this much.
const FIT_TOLERANCE: f64 = 1.0e-6;

// Limit coordinate rounding so distinct lines and runs cannot merge on emission.
const PRECISION_STEPS: f64 = 131_072.0;

pub enum Face<'f> {
    Base14(&'static Base14),
    Embedded(Box<Embedded<'f>>),
}

pub struct Embedded<'f> {
    pub font: EmbeddedFont,
    // Check cmap coverage: `glyph_id` can substitute a different character.
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

    pub fn ascent_descent(&self, face: usize) -> (f64, f64) {
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

#[derive(Clone)]
pub struct Run {
    pub text: String,
    pub face: usize,
    pub color: Option<Rgb>,
    // Distinct link ids prevent separate input runs from merging.
    pub link: Option<usize>,
}

impl Run {
    fn styled(&self, text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            face: self.face,
            color: self.color,
            link: self.link,
        }
    }

    fn same_style(&self, other: &Run) -> bool {
        self.face == other.face && self.color == other.color && self.link == other.link
    }
}

pub enum Op {
    // A block that draws nothing, kept so later ops keep their numbers.
    Empty,
    // Positioned text that draws nothing. It needs no face, but starts the
    // first page as drawn text would.
    Blank,
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
    // Lines wrapped within a box whose bottom-left corner is at a point,
    // outside the flow.
    TextInRect {
        runs: Vec<Run>,
        face: usize,
        size: f64,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        align: Align,
    },
    // A path drawn as given, outside the flow.
    Path(Shape),
    Table(Table),
    Image(FlowImage),
    ImageInRect {
        image: usize,
        pixels: (f64, f64),
        rect: [f64; 4],
        fit: Fit,
    },
    Barcode {
        barcode: Barcode,
        width: f64,
        height: f64,
        align: Align,
        size: f64,
    },
    BarcodeInRect {
        barcode: Barcode,
        rect: [f64; 4],
    },
    Anchor(String),
    // Names the next flow content for the builder's bookmark of this number.
    Bookmark(usize),
    // A label range starting on the page the next content lands on; its
    // `start_page` is set there.
    PageLabels(PageLabelRange),
    // Running text from the page the next content lands on; `None` clears it.
    Header(Option<Running>),
    Footer(Option<Running>),
    Contents(Contents),
    LinkInRect {
        link: usize,
        rect: [f64; 4],
    },
    Watermark {
        mark: Watermark,
        every_page: bool,
    },
    // A form field on the current page, by its position in the builder's
    // field table.
    Field(usize),
}

pub struct Running {
    pub left: Vec<Run>,
    pub center: Vec<Run>,
    pub right: Vec<Run>,
    // The regular face whose metrics place the line.
    pub face: usize,
    pub size: f64,
}

pub struct Contents {
    pub entries: Vec<Entry>,
    pub face: usize,
    pub size: f64,
    pub indent: f64,
}

pub struct Entry {
    pub runs: Vec<Run>,
    pub level: usize,
    pub target: EntryTarget,
    pub link: usize,
}

// Where a bookmark points, for the page label its contents entry shows.
pub enum EntryTarget {
    Mark(usize),
    Page(usize),
    Anchor(String),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Artifact {
    Header,
    Footer,
}

impl Artifact {
    fn noun(self) -> &'static str {
        match self {
            Artifact::Header => "header",
            Artifact::Footer => "footer",
        }
    }
}

#[derive(Clone)]
pub struct Watermark {
    pub text: String,
    pub font: &'static str,
    pub size: f64,
    pub rotation: f64,
    pub color: Rgb,
    pub opacity: f64,
    // `None` centers it on whichever page it is drawn.
    pub center: Option<(f64, f64)>,
}

pub struct FlowImage {
    pub image: usize,
    pub pixels: (f64, f64),
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub fit: Fit,
    pub align: Align,
    pub size: f64,
}

pub struct Barcode {
    pub columns: usize,
    pub rows: usize,
    // One byte per module, row by row from the top, nonzero for dark.
    pub modules: Vec<u8>,
    // In modules, on each side; a linear symbol has none above or below.
    pub quiet_zone: f64,
    pub color: Rgb,
    pub background: Option<Rgb>,
    pub caption: Option<Caption>,
}

pub struct Caption {
    pub runs: Vec<Run>,
    pub face: usize,
    pub size: f64,
}

#[derive(Clone, Copy)]
pub enum Fit {
    Contain,
    Fill,
}

fn contained((pixel_width, pixel_height): (f64, f64), width: f64, height: f64) -> (f64, f64) {
    let scale = (width / pixel_width).min(height / pixel_height);
    (pixel_width * scale, pixel_height * scale)
}

#[derive(Clone, Copy)]
pub enum Align {
    Left,
    Center,
    Right,
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
    pub link: Option<usize>,
    pub artifact: Option<Artifact>,
}

pub struct Plan {
    pub pages: Vec<PagePlan>,
    // Each anchor's page and the top of the content it names.
    pub anchors: HashMap<String, (usize, f64)>,
    // The same for each bookmark that names flow content, by its number.
    pub bookmarks: HashMap<usize, (usize, f64)>,
    // Empty when no op sets labels; otherwise starting on page 0.
    pub labels: Vec<PageLabelRange>,
    // Watermarks drawn on every page, after the page's own items.
    pub watermarks: Vec<Watermark>,
}

pub struct PagePlan {
    pub width: f64,
    pub height: f64,
    // In the order the ops drew them, so later ops paint over earlier ones.
    pub items: Vec<Item>,
}

pub enum Item {
    Text(Placed),
    Path(Shape),
    Image(Picture),
    Link { link: usize, rect: [f64; 4] },
    Watermark(Watermark),
    Field(usize),
}

pub struct Picture {
    pub image: usize,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone)]
pub struct Shape {
    pub operations: Vec<PathOperation>,
    pub stroke: Option<Stroke>,
    pub fill: Option<Rgb>,
}

#[derive(Clone)]
pub struct Stroke {
    pub color: Rgb,
    pub width: f32,
    pub dash: Option<(Vec<f32>, f32)>,
}

const RULE_WIDTH: f32 = 0.5;
const RULE_GRAY: f32 = 0.5;

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
        within: Within,
    },
    // Rows that cannot be split, with the header rows repeated above them,
    // taller than a page's content height.
    TableTooTall {
        op: usize,
        page: usize,
        rows: (usize, usize),
        needed: f64,
        room: f64,
    },
    ColumnsTooWide {
        op: usize,
        page: usize,
        needed: f64,
        room: f64,
    },
    NoRoomForWeights {
        op: usize,
        page: usize,
    },
    Overflow {
        op: usize,
        page: usize,
        lines: usize,
        needed: f64,
        room: f64,
    },
    Imprecise {
        op: usize,
        page: usize,
        size: f64,
    },
    LinkImprecise {
        op: usize,
        page: usize,
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
    TooLarge {
        op: usize,
        page: usize,
        what: &'static str,
        options: &'static str,
        needed: (f64, f64),
        room: (f64, f64),
    },
    // `what` is "link" or "bookmark"; a bookmark given a target has no page.
    NoSuchPage {
        op: usize,
        page: Option<usize>,
        what: &'static str,
        target: usize,
        pages: usize,
    },
    NoSuchAnchor {
        op: usize,
        page: Option<usize>,
        what: &'static str,
        name: String,
    },
    // A page-scoped op that a later one of its kind replaces on the same page.
    Superseded {
        op: usize,
        page: usize,
        by: usize,
        what: &'static str,
    },
    LabelTooLarge {
        op: usize,
        page: usize,
        kind: LabelKind,
    },
    RunningTooTall {
        op: usize,
        page: usize,
        what: &'static str,
        line: f64,
        room: f64,
    },
    RunningTooWide {
        op: usize,
        page: usize,
        what: &'static str,
        part: &'static str,
        width: f64,
        room: f64,
    },
    RunningOverlap {
        op: usize,
        page: usize,
        what: &'static str,
        parts: (&'static str, &'static str),
    },
    ContentsUnsettled {
        op: usize,
    },
}

#[derive(Clone, Copy)]
pub enum LabelKind {
    Roman,
    Letters,
    Number,
}

#[derive(Clone, Copy)]
pub enum Within {
    Line,
    Box,
    Cell { row: usize, column: usize },
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

// The label column never shrinks; refuse if labels have not settled by this limit.
const MAX_PASSES: usize = 8;

// Labels past this have no Roman numeral, and a reader would draw thousands of
// `m`s for a large one.
pub const MAX_ROMAN: u64 = 3999;

// The Elixir side's cap on `:start`: the largest a 32-bit counter holds.
pub const MAX_NUMBER: u64 = 2_147_483_647;

// The labels the contents draws and the width its label column reserves.
#[derive(Default, PartialEq)]
struct Guess {
    labels: Vec<String>,
    reserve: f64,
}

pub fn lay_out(
    fonts: &Fonts,
    margins: &Margins,
    line_height: f64,
    first_page: (f64, f64),
    ops: &[Op],
) -> Result<Plan, Refused> {
    let contents = ops.iter().enumerate().find_map(|(index, op)| match op {
        Op::Contents(contents) => Some((index, contents)),
        _ => None,
    });
    let mut guess = Guess {
        labels: vec![String::new(); contents.map_or(0, |(_, c)| c.entries.len())],
        reserve: 0.0,
    };

    for _ in 0..MAX_PASSES {
        let mut layout = Layout::new(fonts, margins, line_height, first_page, &guess);
        layout.run(ops)?;
        let ranges = layout.label_ranges(ops)?;
        let Some((_, contents)) = contents else {
            return layout.finish(ops, ranges);
        };

        let labels = starting_at_zero(&ranges);
        let drawn: Vec<String> = contents
            .entries
            .iter()
            .map(|entry| layout.entry_label(entry, &labels))
            .collect();
        let reserve = drawn
            .iter()
            .map(|label| fonts.width(contents.face, label, contents.size))
            .fold(guess.reserve, f64::max);
        let next = Guess {
            labels: drawn,
            reserve,
        };
        if next == guess {
            return layout.finish(ops, ranges);
        }
        guess = next;
    }

    Err(Refused::ContentsUnsettled {
        op: contents.map_or(0, |(index, _)| index),
    })
}

// Pages before the first range are numbered from 1; a page label tree must
// say so for page 0.
fn starting_at_zero(ranges: &[(usize, PageLabelRange)]) -> Vec<PageLabelRange> {
    let mut labels: Vec<PageLabelRange> = ranges.iter().map(|(_, range)| range.clone()).collect();
    if labels.first().is_some_and(|range| range.start_page != 0) {
        labels.insert(0, PageLabelRange::new(0));
    }
    labels
}

// A contents label stands alone, so it is laid out as a line of its own:
// each run of whitespace as one space, none at either end.
fn drawn_label(label: String) -> String {
    label.split_whitespace().collect::<Vec<_>>().join(" ")
}

// A label in a header part keeps its spaces, which may separate it from the
// text around it; the part is normalized as a whole once filled in.
fn inline_label(label: String) -> String {
    label
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .collect()
}

// Replace `{page}` and `{pages}` in one pass, so a label holding either is
// drawn as written.
pub fn substitute(text: &str, label: &str, count: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find('{') {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        if let Some(after) = tail.strip_prefix("{page}") {
            out.push_str(label);
            rest = after;
        } else if let Some(after) = tail.strip_prefix("{pages}") {
            out.push_str(count);
            rest = after;
        } else {
            out.push('{');
            rest = &tail[1..];
        }
    }
    out.push_str(rest);
    out
}

// Refuse a page-scoped op that the next one of its kind replaces on the page
// it would start on, so that it would apply to no page.
fn superseded(
    starts: impl Iterator<Item = (usize, usize)>,
    what: &'static str,
) -> Result<(), Refused> {
    let mut previous: Option<(usize, usize)> = None;
    for (op, page) in starts {
        if let Some((before, before_page)) = previous {
            if before_page == page {
                return Err(Refused::Superseded {
                    op: before,
                    page,
                    by: op,
                    what,
                });
            }
        }
        previous = Some((op, page));
    }
    Ok(())
}

struct Block {
    op: usize,
    line: f64,
    above_baseline: f64,
    page: usize,
}

// A line's segments with the left end of its baseline.
type PositionedLine = (f64, f64, Vec<Segment>);

// The page positioned text goes on, whether it belongs to the flow, and what
// running text it is, if any.
#[derive(Clone, Copy)]
struct Spot {
    page: usize,
    flowing: bool,
    artifact: Option<Artifact>,
}

// Marks that name the top of the next flow content.
enum FlowMark {
    Anchor(String),
    Bookmark(usize),
}

struct Layout<'a> {
    fonts: &'a Fonts<'a>,
    margins: &'a Margins,
    line_height: f64,
    first_page: (f64, f64),
    guess: &'a Guess,
    pages: Vec<PagePlan>,
    // Top of the next line box.
    cursor: f64,
    // No line has been placed on the current page yet.
    fresh: bool,
    // Space owed after the previous block, dropped if a page break comes first.
    pending_space: f64,
    pending_flow: Vec<FlowMark>,
    // Page-scoped ops, by index, waiting for the next content of any kind.
    pending_pages: Vec<usize>,
    anchors: HashMap<String, (usize, f64)>,
    bookmarks: HashMap<usize, (usize, f64)>,
    // Each page-scoped op with the page it starts on, in op order.
    page_marks: Vec<(usize, usize)>,
    watermarks: Vec<Watermark>,
}

impl<'a> Layout<'a> {
    fn new(
        fonts: &'a Fonts<'a>,
        margins: &'a Margins,
        line_height: f64,
        first_page: (f64, f64),
        guess: &'a Guess,
    ) -> Self {
        Layout {
            fonts,
            margins,
            line_height,
            first_page,
            guess,
            pages: Vec::new(),
            cursor: 0.0,
            fresh: true,
            pending_space: 0.0,
            pending_flow: Vec::new(),
            pending_pages: Vec::new(),
            anchors: HashMap::new(),
            bookmarks: HashMap::new(),
            page_marks: Vec::new(),
            watermarks: Vec::new(),
        }
    }

    fn run(&mut self, ops: &[Op]) -> Result<(), Refused> {
        for (index, op) in ops.iter().enumerate() {
            match op {
                Op::Empty => {}
                Op::Blank => self.positioned(),
                Op::Page { width, height } => self.new_page(*width, *height),
                Op::Paragraph {
                    runs,
                    face,
                    size,
                    keep_with_next,
                } => {
                    // The lookahead measures headings against the current page.
                    self.ensure_page();
                    let kept = keep_with_next.then(|| self.kept_after(&ops[index + 1..], *size));
                    self.paragraph(index, runs, *face, *size, kept)?;
                }
                Op::List {
                    items,
                    face,
                    size,
                    marker,
                    start,
                } => self.list(index, items, *face, *size, *marker, *start)?,
                Op::Space(points) => self.space(*points),
                Op::Rule { size } => self.rule(*size),
                Op::TextAt { runs, size, x, y } => {
                    self.positioned();
                    self.text_at(index, runs, *size, *x, *y)?
                }
                Op::TextInRect {
                    runs,
                    face,
                    size,
                    x,
                    y,
                    width,
                    height,
                    align,
                } => {
                    self.positioned();
                    self.text_in_rect(index, runs, *face, *size, [*x, *y, *width, *height], *align)?
                }
                Op::Path(shape) => {
                    self.positioned();
                    self.path(shape)
                }
                Op::Table(table) => self.table(index, table)?,
                Op::Image(image) => self.image(index, image)?,
                Op::ImageInRect {
                    image,
                    pixels,
                    rect,
                    fit,
                } => {
                    self.positioned();
                    self.image_in_rect(*image, *pixels, *rect, *fit)
                }
                Op::Barcode {
                    barcode,
                    width,
                    height,
                    align,
                    size,
                } => self.barcode(index, barcode, (*width, *height), *align, *size)?,
                Op::BarcodeInRect { barcode, rect } => {
                    self.positioned();
                    self.draw_barcode(index, barcode, *rect)?
                }
                Op::Anchor(name) => self.pending_flow.push(FlowMark::Anchor(name.clone())),
                Op::Bookmark(number) => self.pending_flow.push(FlowMark::Bookmark(*number)),
                Op::PageLabels(_) | Op::Header(_) | Op::Footer(_) => self.pending_pages.push(index),
                Op::Contents(contents) => self.contents(index, contents)?,
                Op::LinkInRect { link, rect } => {
                    self.positioned();
                    self.link_in_rect(index, *link, *rect)?
                }
                Op::Watermark {
                    mark,
                    every_page: true,
                } => self.watermarks.push(mark.clone()),
                Op::Watermark {
                    mark,
                    every_page: false,
                } => {
                    self.positioned();
                    self.page_mut().items.push(Item::Watermark(mark.clone()));
                }
                Op::Field(field) => {
                    self.positioned();
                    self.page_mut().items.push(Item::Field(*field));
                }
            }
        }

        // A mark with no content after it names where the flow ends.
        self.ensure_page();
        self.resolve_anchors();
        Ok(())
    }

    // Runs before any label is formatted: `format_label` adds in `u32` unchecked.
    fn label_ranges(&self, ops: &[Op]) -> Result<Vec<(usize, PageLabelRange)>, Refused> {
        let ranges: Vec<(usize, PageLabelRange)> = self
            .page_marks
            .iter()
            .filter_map(|&(op, page)| match &ops[op] {
                Op::PageLabels(range) => Some((
                    op,
                    PageLabelRange {
                        start_page: page,
                        ..range.clone()
                    },
                )),
                _ => None,
            })
            .collect();

        for (index, (op, range)) in ranges.iter().enumerate() {
            let last = ranges
                .get(index + 1)
                .map_or(self.pages.len(), |(_, next)| next.start_page)
                .saturating_sub(1)
                .max(range.start_page);
            let kind = match range.style {
                PageLabelStyle::RomanLower | PageLabelStyle::RomanUpper => LabelKind::Roman,
                PageLabelStyle::AlphaLower | PageLabelStyle::AlphaUpper => LabelKind::Letters,
                _ => LabelKind::Number,
            };
            let limit = match kind {
                LabelKind::Roman => MAX_ROMAN,
                LabelKind::Letters => MAX_LETTERED,
                LabelKind::Number => MAX_NUMBER,
            };
            let start = u64::from(range.start_value);
            if start + (last - range.start_page) as u64 > limit {
                let page = range.start_page + (limit + 1).saturating_sub(start) as usize;
                return Err(Refused::LabelTooLarge {
                    op: *op,
                    page,
                    kind,
                });
            }
        }

        Ok(ranges)
    }

    fn entry_label(&self, entry: &Entry, labels: &[PageLabelRange]) -> String {
        let page = match &entry.target {
            EntryTarget::Mark(bookmark) => self.bookmarks.get(bookmark).map(|&(page, _)| page),
            EntryTarget::Page(page) => Some(*page).filter(|&page| page < self.pages.len()),
            EntryTarget::Anchor(name) => self.anchors.get(name).map(|&(page, _)| page),
        };
        // A missing target is refused before anything is written, and
        // `label_ranges` has refused a label too long to write.
        page.and_then(|page| page_label::label(labels, page).ok())
            .map(drawn_label)
            .unwrap_or_default()
    }

    fn finish(mut self, ops: &[Op], ranges: Vec<(usize, PageLabelRange)>) -> Result<Plan, Refused> {
        superseded(
            ranges.iter().map(|(op, range)| (*op, range.start_page)),
            "page_labels/3",
        )?;
        let labels = starting_at_zero(&ranges);
        // `label_ranges` has refused a label too long to write.
        let texts: Vec<String> = (0..self.pages.len())
            .map(|page| inline_label(page_label::label(&labels, page).unwrap_or_default()))
            .collect();
        self.furnish(ops, Artifact::Header, &texts)?;
        self.furnish(ops, Artifact::Footer, &texts)?;

        Ok(Plan {
            pages: self.pages,
            anchors: self.anchors,
            bookmarks: self.bookmarks,
            labels,
            watermarks: self.watermarks,
        })
    }

    fn furnish(
        &mut self,
        ops: &[Op],
        artifact: Artifact,
        labels: &[String],
    ) -> Result<(), Refused> {
        let starts: Vec<(usize, usize, &Option<Running>)> = self
            .page_marks
            .iter()
            .filter_map(|&(op, page)| match (&ops[op], artifact) {
                (Op::Header(running), Artifact::Header)
                | (Op::Footer(running), Artifact::Footer) => Some((op, page, running)),
                _ => None,
            })
            .collect();
        let what = match artifact {
            Artifact::Header => "header/2",
            Artifact::Footer => "footer/2",
        };
        superseded(starts.iter().map(|&(op, page, _)| (op, page)), what)?;

        let count = self.pages.len().to_string();
        for (index, &(op, start, running)) in starts.iter().enumerate() {
            let Some(running) = running else { continue };
            let end = starts
                .get(index + 1)
                .map_or(self.pages.len(), |&(_, next, _)| next);
            for (page, label) in labels.iter().enumerate().take(end).skip(start) {
                self.place_running(op, page, running, artifact, label, &count)?;
            }
        }
        Ok(())
    }

    fn place_running(
        &mut self,
        op: usize,
        page: usize,
        running: &Running,
        artifact: Artifact,
        label: &str,
        count: &str,
    ) -> Result<(), Refused> {
        let what = artifact.noun();
        let size = running.size;
        // Spelled as the Elixir check spells it, so both refuse the same lines.
        let line = size * self.line_height;
        let room = match artifact {
            Artifact::Header => self.margins.top,
            Artifact::Footer => self.margins.bottom,
        };
        if line > room {
            return Err(Refused::RunningTooTall {
                op,
                page,
                what,
                line,
                room,
            });
        }
        let (width, height) = (self.pages[page].width, self.pages[page].height);
        if width.max(height) > size.min(line) * PRECISION_STEPS {
            return Err(Refused::Imprecise { op, page, size });
        }

        let parts: Vec<(&'static str, Vec<Run>)> = [
            ("left", &running.left),
            ("center", &running.center),
            ("right", &running.right),
        ]
        .into_iter()
        .map(|(part, runs)| {
            let runs: Vec<Run> = runs
                .iter()
                .map(|run| run.styled(substitute(&run.text, label, count)))
                .filter(|run| !run.text.is_empty())
                .collect();
            (part, runs)
        })
        .filter(|(_, runs)| !draws_nothing(runs.iter().map(|run| run.text.as_str())))
        .collect();
        let texts: Vec<&[Run]> = parts.iter().map(|(_, runs)| runs.as_slice()).collect();
        self.drawable(op, page, &texts, &[])?;

        let (left, right) = (self.margins.left, width - self.margins.right);
        let top = match artifact {
            Artifact::Header => height - (room - line) / 2.0,
            Artifact::Footer => (room + line) / 2.0,
        };
        let baseline = top - self.above_baseline(running.face, size, line);

        let mut lines: Vec<PositionedLine> = Vec::new();
        let mut previous: Option<(&'static str, f64)> = None;
        for (part, runs) in parts {
            // One line, laid out as `text_at` lays out its own, so any run of
            // whitespace is drawn and measured as one space.
            let segments = wrap(self.fonts, &runs, size, f64::INFINITY)
                .map_err(|_| Refused::RunningTooWide {
                    op,
                    page,
                    what,
                    part,
                    width: f64::INFINITY,
                    room: right - left,
                })?
                .into_iter()
                .next()
                .unwrap_or_default();
            let advance: f64 = segments.iter().map(|segment| segment.width).sum();
            let x = match part {
                "left" => left,
                // Halved separately, as in a box.
                "center" => width / 2.0 - advance / 2.0,
                _ => right - advance,
            };
            if x < left - FIT_TOLERANCE || x + advance > right + FIT_TOLERANCE {
                return Err(Refused::RunningTooWide {
                    op,
                    page,
                    what,
                    part,
                    width: advance,
                    room: right - left,
                });
            }
            if let Some((before, end)) = previous {
                if end > x + FIT_TOLERANCE {
                    return Err(Refused::RunningOverlap {
                        op,
                        page,
                        what,
                        parts: (before, part),
                    });
                }
            }
            previous = Some((part, x + advance));
            lines.push((x, baseline, segments));
        }

        let spot = Spot {
            page,
            flowing: false,
            artifact: Some(artifact),
        };
        self.place_positioned_on(spot, op, lines, size, NO_EXTENT)
    }

    fn ensure_page(&mut self) {
        if self.pages.is_empty() {
            let (width, height) = self.first_page;
            self.new_page(width, height);
        }
    }

    // Before content placed outside the flow: it lands on the current page.
    fn positioned(&mut self) {
        self.ensure_page();
        self.resolve_page_marks();
    }

    fn page(&self) -> &PagePlan {
        self.pages
            .last()
            .expect("a page exists once ensure_page has run")
    }

    fn page_mut(&mut self) -> &mut PagePlan {
        self.pages
            .last_mut()
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

    // Resolve only after the next flow content's page-break decision.
    fn resolve_anchors(&mut self) {
        let at = (self.pages.len() - 1, self.cursor);
        for mark in self.pending_flow.drain(..) {
            match mark {
                FlowMark::Anchor(name) => {
                    self.anchors.entry(name).or_insert(at);
                }
                FlowMark::Bookmark(number) => {
                    self.bookmarks.insert(number, at);
                }
            }
        }
        self.resolve_page_marks();
    }

    fn resolve_page_marks(&mut self) {
        let page = self.pages.len() - 1;
        self.page_marks
            .extend(self.pending_pages.drain(..).map(|op| (op, page)));
    }

    fn contents(&mut self, op: usize, contents: &Contents) -> Result<(), Refused> {
        let Contents {
            entries,
            face,
            size,
            indent,
        } = contents;
        let (face, size, indent) = (*face, *size, *indent);
        let guess = self.guess;
        let texts: Vec<&[Run]> = entries.iter().map(|entry| entry.runs.as_slice()).collect();
        let extra: Vec<(usize, &str)> = guess
            .labels
            .iter()
            .map(|label| (face, label.as_str()))
            .collect();
        let block = self.block(op, &texts, &extra, face, size)?;

        let gap = size;
        let right = self.page().width - self.margins.right;
        for (entry, label) in entries.iter().zip(&guess.labels) {
            let x = self.margins.left + entry.level.saturating_sub(1) as f64 * indent;
            let width = right - x - guess.reserve - gap;
            let page = self.pages.len() - 1;
            if width <= 0.0 {
                return Err(Refused::NoWidth { op, page });
            }
            let lines = self.wrapped(op, page, &entry.runs, size, width)?;
            let last = lines.len().saturating_sub(1);
            for (index, segments) in lines.into_iter().enumerate() {
                let label = (index == last && !label.is_empty()).then(|| {
                    let label_width = self.fonts.width(face, label, size);
                    let segment = Segment {
                        text: label.clone(),
                        face,
                        color: None,
                        link: Some(entry.link),
                        width: label_width,
                    };
                    (right - label_width, segment)
                });
                self.place_line(&block, segments, size, x, label)?;
            }
        }

        self.pending_space = 0.5 * size;
        Ok(())
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

        self.precise(op, page_index, size, size.min(line))?;
        self.drawable(op, page_index, texts, extra)?;

        Ok(Block {
            op,
            line,
            above_baseline: self.above_baseline(face, size, line),
            page: page_index,
        })
    }

    fn above_baseline(&self, face: usize, size: f64, line: f64) -> f64 {
        let (ascent, descent) = self.fonts.ascent_descent(face);
        let half_leading = (line - (ascent - descent) * size / 1000.0) / 2.0;
        half_leading + ascent * size / 1000.0
    }

    // Spelled as the Elixir checks spell it, so both refuse the same text.
    fn precise(&self, op: usize, page: usize, size: f64, step: f64) -> Result<(), Refused> {
        let (width, height) = (self.page().width, self.page().height);
        if width.max(height) > step * PRECISION_STEPS {
            return Err(Refused::Imprecise { op, page, size });
        }
        Ok(())
    }

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
                within: Within::Line,
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
                Op::Contents(contents) => return total + gap + contents.size * self.line_height,
                Op::Table(table) => return total + gap + self.table_lead(table),
                Op::Image(image) => return total + gap + self.image_size(image).1,
                Op::Barcode { height, .. } => return total + gap + height,
                Op::Page { .. } => return total,
                Op::Blank
                | Op::TextAt { .. }
                | Op::TextInRect { .. }
                | Op::Path(_)
                | Op::ImageInRect { .. }
                | Op::BarcodeInRect { .. }
                | Op::Anchor(_)
                | Op::Bookmark(_)
                | Op::PageLabels(_)
                | Op::Header(_)
                | Op::Footer(_)
                | Op::LinkInRect { .. }
                | Op::Watermark { .. }
                | Op::Field(_) => {}
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
                link: None,
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
        self.precise(op, page_index, size, size)?;
        self.drawable(op, page_index, &[runs], &[])?;

        let segments = wrap(self.fonts, runs, size, f64::INFINITY)
            .map_err(|_| Refused::OffPage {
                op,
                page: page_index,
                flowing: false,
            })?
            .into_iter()
            .next()
            .unwrap_or_default();

        self.place_positioned(op, vec![(x, y, segments)], size, [x, y, x, y], false)
    }

    fn text_in_rect(
        &mut self,
        op: usize,
        runs: &[Run],
        face: usize,
        size: f64,
        [x, y, width, height]: [f64; 4],
        align: Align,
    ) -> Result<(), Refused> {
        self.ensure_page();
        let page_index = self.pages.len() - 1;
        let line = size * self.line_height;
        self.precise(op, page_index, size, size.min(line))?;
        self.drawable(op, page_index, &[runs], &[])?;

        let lines = wrap(self.fonts, runs, size, width).map_err(|(cluster, cluster_width)| {
            Refused::ClusterTooWide {
                op,
                page: page_index,
                cluster,
                width: cluster_width,
                room: width,
                within: Within::Box,
            }
        })?;

        let needed = lines.len() as f64 * line;
        if needed > height + FIT_TOLERANCE {
            return Err(Refused::Overflow {
                op,
                page: page_index,
                lines: lines.len(),
                needed,
                room: height,
            });
        }

        let above_baseline = self.above_baseline(face, size, line);
        let placed = boxed_lines(lines, [x, y + height, width], align, above_baseline, line);
        self.place_positioned(op, placed, size, NO_EXTENT, false)
    }

    // Neither a line's box nor any glyph's ink, which can overhang its
    // advance or rise above the ascent, may cross the page edge.
    fn place_positioned(
        &mut self,
        op: usize,
        lines: Vec<PositionedLine>,
        size: f64,
        extent: [f64; 4],
        flowing: bool,
    ) -> Result<(), Refused> {
        let spot = Spot {
            page: self.pages.len() - 1,
            flowing,
            artifact: None,
        };
        self.place_positioned_on(spot, op, lines, size, extent)
    }

    fn place_positioned_on(
        &mut self,
        Spot {
            page: page_index,
            flowing,
            artifact,
        }: Spot,
        op: usize,
        lines: Vec<PositionedLine>,
        size: f64,
        mut extent: [f64; 4],
    ) -> Result<(), Refused> {
        for (x, baseline, segments) in &lines {
            let mut pen = *x;
            for segment in segments {
                let (ascent, descent) = self.fonts.ascent_descent(segment.face);
                extent[0] = extent[0].min(pen);
                extent[1] = extent[1].min(baseline + descent * size / 1000.0);
                extent[3] = extent[3].max(baseline + ascent * size / 1000.0);
                pen = self.add_ink(&mut extent, segment, pen, *baseline, size);
            }
            if !segments.is_empty() {
                extent[2] = extent[2].max(pen);
            }
        }

        let (width, height) = (self.pages[page_index].width, self.pages[page_index].height);
        if extent[0] < -FIT_TOLERANCE
            || extent[1] < -FIT_TOLERANCE
            || extent[2] > width + FIT_TOLERANCE
            || extent[3] > height + FIT_TOLERANCE
        {
            return Err(Refused::OffPage {
                op,
                page: page_index,
                flowing,
            });
        }

        let page = &mut self.pages[page_index];
        for (x, baseline, segments) in lines {
            let mut at = x;
            for segment in segments {
                page.items.push(Item::Text(Placed {
                    x: at,
                    baseline,
                    width: segment.width,
                    text: segment.text,
                    face: segment.face,
                    size,
                    color: segment.color,
                    link: segment.link,
                    artifact,
                }));
                at += segment.width;
            }
        }
        Ok(())
    }

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

    fn path(&mut self, shape: &Shape) {
        self.ensure_page();
        let page = self.page_mut();
        page.items.push(Item::Path(shape.clone()));
    }

    fn content_area(&self) -> (f64, f64) {
        let page = self.page();
        (
            page.width - self.margins.left - self.margins.right,
            page.height - self.margins.top - self.margins.bottom,
        )
    }

    fn image_size(&self, image: &FlowImage) -> (f64, f64) {
        let (pixel_width, pixel_height) = image.pixels;
        match (image.width, image.height, image.fit) {
            (None, None, _) => {
                let (room_width, room_height) = self.content_area();
                if pixel_width <= room_width && pixel_height <= room_height {
                    image.pixels
                } else {
                    contained(image.pixels, room_width, room_height)
                }
            }
            (Some(width), None, _) => (width, width * pixel_height / pixel_width),
            (None, Some(height), _) => (height * pixel_width / pixel_height, height),
            (Some(width), Some(height), Fit::Fill) => (width, height),
            (Some(width), Some(height), Fit::Contain) => contained(image.pixels, width, height),
        }
    }

    fn image(&mut self, op: usize, image: &FlowImage) -> Result<(), Refused> {
        self.ensure_page();
        let (width, height) = self.image_size(image);
        let what = ("an image", ":width or :height");
        let (x, y) = self.place_block(op, what, (width, height), image.align, image.size)?;
        self.page_mut().items.push(Item::Image(Picture {
            image: image.image,
            x,
            y,
            width,
            height,
        }));
        Ok(())
    }

    fn barcode(
        &mut self,
        op: usize,
        barcode: &Barcode,
        (width, height): (f64, f64),
        align: Align,
        size: f64,
    ) -> Result<(), Refused> {
        self.ensure_page();
        let options = if barcode.rows > 1 {
            ":size"
        } else {
            ":width or :height"
        };
        let (x, y) = self.place_block(op, ("a barcode", options), (width, height), align, size)?;
        self.draw_barcode(op, barcode, [x, y, width, height])
    }

    // Returns the block's bottom-left corner.
    fn place_block(
        &mut self,
        op: usize,
        (what, options): (&'static str, &'static str),
        (width, height): (f64, f64),
        align: Align,
        size: f64,
    ) -> Result<(f64, f64), Refused> {
        let page = self.pages.len() - 1;
        let room = self.content_width(op, page, self.margins.left)?;
        let (_, room_height) = self.content_area();
        if width > room + FIT_TOLERANCE || height > room_height + FIT_TOLERANCE {
            return Err(Refused::TooLarge {
                op,
                page,
                what,
                options,
                needed: (width, height),
                room: (room, room_height),
            });
        }

        if !self.fresh {
            let spaced = self.cursor - self.pending_space;
            if self.fits(spaced, height) {
                self.cursor = spaced;
            } else {
                self.break_page();
            }
        }
        self.resolve_anchors();

        let left = self.margins.left;
        let x = match align {
            Align::Left => left,
            Align::Center => left + room / 2.0 - width / 2.0,
            Align::Right => left + room - width,
        };
        self.cursor -= height;
        self.fresh = false;
        self.pending_space = 0.5 * size;
        Ok((x, self.cursor))
    }

    // Fill all dark runs in one path to avoid seams between abutting modules.
    fn draw_barcode(
        &mut self,
        op: usize,
        barcode: &Barcode,
        [x, y, width, height]: [f64; 4],
    ) -> Result<(), Refused> {
        let caption_height = barcode
            .caption
            .as_ref()
            .map_or(0.0, |caption| caption.size * self.line_height);
        let bars_height = height - caption_height;
        let rectangle = |x: f64, y: f64, width: f64, height: f64| {
            PathOperation::Rectangle(x as f32, y as f32, width as f32, height as f32)
        };

        if let Some(background) = barcode.background {
            self.page_mut().items.push(Item::Path(Shape {
                operations: vec![rectangle(x, y, width, height)],
                stroke: None,
                fill: Some(background),
            }));
        }

        let across = barcode.quiet_zone;
        let down = if barcode.rows > 1 { across } else { 0.0 };
        let module_width = width / (barcode.columns as f64 + 2.0 * across);
        let module_height = bars_height / (barcode.rows as f64 + 2.0 * down);
        let top = y + height;
        let operations = dark_runs(barcode.columns, &barcode.modules)
            .into_iter()
            .map(|(column, row, length)| {
                rectangle(
                    x + (across + column as f64) * module_width,
                    top - (down + row as f64 + 1.0) * module_height,
                    length as f64 * module_width,
                    module_height,
                )
            })
            .collect();
        self.page_mut().items.push(Item::Path(Shape {
            operations,
            stroke: None,
            fill: Some(barcode.color),
        }));

        match &barcode.caption {
            Some(caption) => self.caption(op, caption, [x, y, width, caption_height]),
            None => Ok(()),
        }
    }

    // Placed as written rather than wrapped, so its spaces match the encoded data.
    fn caption(
        &mut self,
        op: usize,
        caption: &Caption,
        [x, y, width, line]: [f64; 4],
    ) -> Result<(), Refused> {
        let page = self.pages.len() - 1;
        let size = caption.size;
        self.precise(op, page, size, size.min(line))?;
        self.drawable(op, page, &[&caption.runs], &[])?;

        let segments: Vec<Segment> = caption
            .runs
            .iter()
            .map(|run| Segment {
                text: run.text.clone(),
                face: run.face,
                color: run.color,
                link: run.link,
                width: self.fonts.width(run.face, &run.text, size),
            })
            .collect();
        let advance: f64 = segments.iter().map(|segment| segment.width).sum();
        if advance > width + FIT_TOLERANCE {
            return Err(Refused::ClusterTooWide {
                op,
                page,
                cluster: caption.runs.iter().map(|run| run.text.as_str()).collect(),
                width: advance,
                room: width,
                within: Within::Box,
            });
        }

        let above_baseline = self.above_baseline(caption.face, size, line);
        let placed = boxed_lines(
            vec![segments],
            [x, y + line, width],
            Align::Center,
            above_baseline,
            line,
        );
        self.place_positioned(op, placed, size, NO_EXTENT, false)
    }

    fn image_in_rect(&mut self, image: usize, pixels: (f64, f64), rect: [f64; 4], fit: Fit) {
        self.ensure_page();
        let [x, y, width, height] = rect;
        let picture = match fit {
            Fit::Fill => Picture {
                image,
                x,
                y,
                width,
                height,
            },
            Fit::Contain => {
                let (drawn_width, drawn_height) = contained(pixels, width, height);
                Picture {
                    image,
                    x: x + width / 2.0 - drawn_width / 2.0,
                    y: y + height / 2.0 - drawn_height / 2.0,
                    width: drawn_width,
                    height: drawn_height,
                }
            }
        };
        self.page_mut().items.push(Item::Image(picture));
    }

    // Clip before narrowing: a distant origin can round away the visible area.
    fn link_in_rect(&mut self, op: usize, link: usize, rect: [f64; 4]) -> Result<(), Refused> {
        self.ensure_page();
        let [x, y, width, height] = rect;
        let (page_width, page_height) = (self.page().width, self.page().height);
        let (left, bottom) = (x.max(0.0), y.max(0.0));
        let (right, top) = ((x + width).min(page_width), (y + height).min(page_height));
        // The writer rounds a fractional coordinate to five decimal places.
        const WRITTEN_STEP: f32 = 1.0e-5;
        let narrow = |from: f64, to: f64| (to as f32 - from as f32) < WRITTEN_STEP;
        if narrow(left, right) || narrow(bottom, top) {
            return Err(Refused::LinkImprecise {
                op,
                page: self.pages.len() - 1,
            });
        }
        self.page_mut().items.push(Item::Link {
            link,
            rect: [left, bottom, right - left, top - bottom],
        });
        Ok(())
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
        self.resolve_anchors();

        let (left, right) = (self.margins.left, self.margins.right);
        let y = (self.cursor - size / 2.0) as f32;
        let page = self.page_mut();
        let to = page.width - right;
        page.items.push(Item::Path(Shape {
            operations: vec![
                PathOperation::MoveTo(left as f32, y),
                PathOperation::LineTo(to as f32, y),
            ],
            stroke: Some(Stroke {
                color: [RULE_GRAY; 3],
                width: RULE_WIDTH,
                dash: None,
            }),
            fill: None,
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
        self.resolve_anchors();

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

        let page = self.page_mut();
        for (at, segment) in placed {
            page.items.push(Item::Text(Placed {
                x: at,
                baseline,
                width: segment.width,
                text: segment.text,
                face: segment.face,
                size,
                color: segment.color,
                link: segment.link,
                artifact: None,
            }));
        }

        self.cursor -= block.line;
        self.fresh = false;
        Ok(())
    }
}

#[derive(Clone)]
struct Segment {
    text: String,
    face: usize,
    color: Option<Rgb>,
    link: Option<usize>,
    width: f64,
}

// An extent that holds nothing yet, so only what is drawn is measured.
const NO_EXTENT: [f64; 4] = [
    f64::INFINITY,
    f64::INFINITY,
    f64::NEG_INFINITY,
    f64::NEG_INFINITY,
];

fn boxed_lines(
    lines: Vec<Vec<Segment>>,
    [x, top, width]: [f64; 3],
    align: Align,
    above_baseline: f64,
    line: f64,
) -> Vec<PositionedLine> {
    let mut top = top;
    let mut placed = Vec::with_capacity(lines.len());
    for segments in lines {
        let advance: f64 = segments.iter().map(|segment| segment.width).sum();
        let left = match align {
            Align::Left => x,
            // Halved separately: in a very wide box, `width - advance`
            // rounds the advance away.
            Align::Center => x + width / 2.0 - advance / 2.0,
            Align::Right => x + width - advance,
        };
        placed.push((left, top - above_baseline, segments));
        top -= line;
    }
    placed
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
                link: piece.link,
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
    // Advances summed one by one can exceed a width they fill exactly.
    let limit = max_width + FIT_TOLERANCE;
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

                if !line.pieces.is_empty() && line.width + space_width + width <= limit {
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
                    if width <= limit {
                        for piece in pieces {
                            line.push(fonts, piece, size);
                        }
                    } else {
                        for chunk in split_word(fonts, pieces, size, limit)? {
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

    use super::{
        lay_out, substitute, unordered, Embedded, Face, Fonts, Margins, Op, Refused, Run, Unordered,
    };

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
                link: None,
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

    #[test]
    fn placeholders_are_replaced_once_and_other_braces_kept() {
        assert_eq!(substitute("{page}/{pages}", "iv", "9"), "iv/9");
        assert_eq!(
            substitute("{{page}} {pagesx {page", "1", "2"),
            "{1} {pagesx {page"
        );
        assert_eq!(substitute("{page}", "{pages}", "2"), "{pages}");
    }
}
