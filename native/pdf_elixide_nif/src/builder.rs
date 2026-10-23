use std::collections::{HashMap, HashSet};

use pdf_oxide::{
    elements::{ContentElement, FontSpec, PathContent, TextContent, TextStyle},
    fonts::bundled::{DEJAVU_SANS, DEJAVU_SANS_BOLD},
    geometry::Rect,
    writer::{DocumentBuilder, EmbeddedFont, ImageData, PageSize},
};
use rustler::{Binary, NifMap, NifResult, NifTaggedEnum, NifUnitEnum};

use crate::{
    atoms, base14,
    color::{color_from_components, RgbNif},
    create::{create_from_bytes, decoded, keep_apart},
    editor::OpenedEditor,
    error::{tagged_err, to_nif_err},
    flow::{
        self, embedded_key, Align, Cell, Embedded, Face, Fit, FlowImage, Fonts, Item, Margins,
        Marker, Op, PagePlan, Picture, Refused, Run, Shape, Stroke, Table, Unordered, Width,
        Within,
    },
    paths::PathOpNif,
};

#[derive(NifMap)]
pub struct BuildNif<'a> {
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
    creator: Option<String>,
    page_size: (f64, f64),
    margin_top: f64,
    margin_bottom: f64,
    margin_left: f64,
    margin_right: f64,
    line_height: f64,
    families: Vec<FamilyNif<'a>>,
    images: Vec<Binary<'a>>,
    ops: Vec<OpNif>,
}

#[derive(NifMap)]
pub struct FamilyNif<'a> {
    regular: Binary<'a>,
    bold: Option<Binary<'a>>,
    italic: Option<Binary<'a>>,
    bold_italic: Option<Binary<'a>>,
}

#[derive(NifTaggedEnum)]
pub enum OpNif {
    Page((f64, f64)),
    Paragraph(ParagraphNif),
    Heading(ParagraphNif),
    List(ListNif),
    Space(f64),
    Rule(f64),
    TextAt(TextAtNif),
    TextInRect(TextInRectNif),
    Path(ShapeNif),
    Table(TableNif),
    Image(ImageNif),
    ImageInRect(ImageInRectNif),
}

#[derive(NifMap)]
pub struct ImageNif {
    image: usize,
    width: Option<f64>,
    height: Option<f64>,
    fit: FitNif,
    align: AlignNif,
    font_size: f64,
}

#[derive(NifMap)]
pub struct ImageInRectNif {
    image: usize,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    fit: FitNif,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum FitNif {
    Contain,
    Fill,
}

impl From<FitNif> for Fit {
    fn from(fit: FitNif) -> Self {
        match fit {
            FitNif::Contain => Fit::Contain,
            FitNif::Fill => Fit::Fill,
        }
    }
}

// Each distinct image arrives once and is decoded where an op first uses it,
// so a decoding error names that op.
struct Pictures<'s, 'b> {
    sources: &'s [Binary<'b>],
    decoded: Vec<Option<ImageData>>,
}

impl Pictures<'_, '_> {
    fn pixels(&mut self, op: usize, image: usize) -> NifResult<(f64, f64)> {
        let source = self.sources.get(image).ok_or(rustler::Error::BadArg)?;
        if self.decoded[image].is_none() {
            let data = decoded(&format!("the image of op {op}"), source.as_slice())?;
            self.decoded[image] = Some(data);
        }
        let data = self.decoded[image].as_ref().expect("decoded above");
        Ok((f64::from(data.width), f64::from(data.height)))
    }
}

#[derive(NifMap)]
pub struct TableNif {
    rows: Vec<Vec<CellNif>>,
    font: FontNif,
    font_size: f64,
    column_widths: Vec<WidthNif>,
    header_rows: usize,
    header_fill: Option<RgbNif>,
    padding: f64,
    stroke_color: Option<RgbNif>,
    stroke_width: f32,
}

#[derive(NifMap)]
pub struct CellNif {
    runs: Vec<RunNif>,
    column: usize,
    colspan: usize,
    rowspan: usize,
    align: AlignNif,
    fill_color: Option<RgbNif>,
}

#[derive(NifTaggedEnum, Clone, Copy)]
pub enum WidthNif {
    Points(f64),
    Weight(f64),
    Auto,
}

impl From<WidthNif> for Width {
    fn from(width: WidthNif) -> Self {
        match width {
            WidthNif::Points(points) => Width::Points(points),
            WidthNif::Weight(weight) => Width::Weight(weight),
            WidthNif::Auto => Width::Auto,
        }
    }
}

#[derive(NifMap)]
pub struct ShapeNif {
    operations: Vec<PathOpNif>,
    stroke_color: Option<RgbNif>,
    fill_color: Option<RgbNif>,
    stroke_width: f32,
    dash_pattern: Option<(Vec<f32>, f32)>,
}

impl From<ShapeNif> for Shape {
    fn from(shape: ShapeNif) -> Self {
        Shape {
            operations: shape.operations.into_iter().map(Into::into).collect(),
            stroke: shape.stroke_color.map(|c| Stroke {
                color: c.into(),
                width: shape.stroke_width,
                dash: shape.dash_pattern,
            }),
            fill: shape.fill_color.map(Into::into),
        }
    }
}

#[derive(NifMap)]
pub struct TextAtNif {
    runs: Vec<RunNif>,
    font: FontNif,
    font_size: f64,
    x: f64,
    y: f64,
}

#[derive(NifMap)]
pub struct TextInRectNif {
    runs: Vec<RunNif>,
    font: FontNif,
    font_size: f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    align: AlignNif,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum AlignNif {
    Left,
    Center,
    Right,
}

impl From<AlignNif> for Align {
    fn from(align: AlignNif) -> Self {
        match align {
            AlignNif::Left => Align::Left,
            AlignNif::Center => Align::Center,
            AlignNif::Right => Align::Right,
        }
    }
}

#[derive(NifMap)]
pub struct ListNif {
    items: Vec<Vec<RunNif>>,
    font: FontNif,
    font_size: f64,
    marker: MarkerNif,
    start: usize,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum MarkerNif {
    Bullet,
    Decimal,
    LowerRoman,
    LowerAlpha,
}

impl From<MarkerNif> for Marker {
    fn from(marker: MarkerNif) -> Self {
        match marker {
            MarkerNif::Bullet => Marker::Bullet,
            MarkerNif::Decimal => Marker::Decimal,
            MarkerNif::LowerRoman => Marker::LowerRoman,
            MarkerNif::LowerAlpha => Marker::LowerAlpha,
        }
    }
}

#[derive(NifMap)]
pub struct ParagraphNif {
    runs: Vec<RunNif>,
    font: FontNif,
    font_size: f64,
}

#[derive(NifMap)]
pub struct RunNif {
    text: String,
    bold: bool,
    italic: bool,
    color: Option<RgbNif>,
}

#[derive(NifTaggedEnum, Clone, Copy)]
pub enum FontNif {
    Auto,
    Helvetica,
    Times,
    Courier,
    DejavuSans,
    Family(usize),
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Family {
    Helvetica,
    Times,
    Courier,
    DejaVu,
    Caller(usize),
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Style {
    Regular,
    Bold,
    Italic,
    BoldItalic,
}

impl Style {
    fn of(bold: bool, italic: bool) -> Self {
        match (bold, italic) {
            (false, false) => Style::Regular,
            (true, false) => Style::Bold,
            (false, true) => Style::Italic,
            (true, true) => Style::BoldItalic,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Style::Regular => "regular",
            Style::Bold => "bold",
            Style::Italic => "italic",
            Style::BoldItalic => "bold italic",
        }
    }

    fn key(self) -> &'static str {
        match self {
            Style::Regular => ":regular",
            Style::Bold => ":bold",
            Style::Italic => ":italic",
            Style::BoldItalic => ":bold_italic",
        }
    }
}

fn base14_name(family: Family, style: Style) -> Option<&'static str> {
    Some(match (family, style) {
        (Family::Helvetica, Style::Regular) => "Helvetica",
        (Family::Helvetica, Style::Bold) => "Helvetica-Bold",
        (Family::Helvetica, Style::Italic) => "Helvetica-Oblique",
        (Family::Helvetica, Style::BoldItalic) => "Helvetica-BoldOblique",
        (Family::Times, Style::Regular) => "Times-Roman",
        (Family::Times, Style::Bold) => "Times-Bold",
        (Family::Times, Style::Italic) => "Times-Italic",
        (Family::Times, Style::BoldItalic) => "Times-BoldItalic",
        (Family::Courier, Style::Regular) => "Courier",
        (Family::Courier, Style::Bold) => "Courier-Bold",
        (Family::Courier, Style::Italic) => "Courier-Oblique",
        (Family::Courier, Style::BoldItalic) => "Courier-BoldOblique",
        _ => return None,
    })
}

// The bytes each embedded face is registered from when the document is
// written; `EmbeddedFont` cannot be cloned, so the layout keeps its own parse.
struct Faces<'f, 'a> {
    families: &'f [FamilyNif<'a>],
    fonts: Fonts<'f>,
    sources: Vec<(usize, &'f [u8])>,
    index: HashMap<(Family, Style), usize>,
}

impl<'f> Faces<'f, '_> {
    fn face(&mut self, op: usize, family: Family, style: Style) -> NifResult<usize> {
        if let Some(&face) = self.index.get(&(family, style)) {
            return Ok(face);
        }

        let face = match family {
            Family::Caller(position) => {
                let family = &self.families[position];
                let bytes = match style {
                    Style::Regular => Some(&family.regular),
                    Style::Bold => family.bold.as_ref(),
                    Style::Italic => family.italic.as_ref(),
                    Style::BoldItalic => family.bold_italic.as_ref(),
                }
                .ok_or_else(|| {
                    unsupported(format!(
                        "op {op}: its FontFamily has no {} face; pass {} to \
                         FontFamily.new/1, or set the text without that style",
                        style.label(),
                        style.key()
                    ))
                })?;
                self.embed(op, style, bytes.as_slice())?
            }
            Family::DejaVu => {
                let bytes: &'static [u8] = match style {
                    Style::Regular => DEJAVU_SANS,
                    Style::Bold => DEJAVU_SANS_BOLD,
                    Style::Italic | Style::BoldItalic => {
                        return Err(unsupported(format!(
                            "op {op}: :dejavu_sans has no {} face; pass a FontFamily that \
                             has one, or set the text without that style",
                            style.label()
                        )));
                    }
                };
                self.embed(op, style, bytes)?
            }
            builtin => {
                let name = base14_name(builtin, style).expect("every base-14 style is named");
                self.fonts.add(Face::Base14(
                    base14::face(name).expect("named faces are base-14"),
                ))
            }
        };

        self.index.insert((family, style), face);
        Ok(face)
    }

    fn embed(&mut self, op: usize, style: Style, bytes: &'f [u8]) -> NifResult<usize> {
        let font = parse(op, style, bytes)?;
        let outlines = ttf_parser::Face::parse(bytes, 0)
            .map_err(|reason| unsupported(format!("a face parsed once failed again: {reason}")))?;
        let coverage = coverage(&outlines);
        let face = self.fonts.add(Face::Embedded(Box::new(Embedded {
            font,
            coverage,
            outlines,
        })));
        self.sources.push((face, bytes));
        Ok(face)
    }
}

fn parse(op: usize, style: Style, bytes: &[u8]) -> NifResult<EmbeddedFont> {
    // The parser reads the first face of a collection and says nothing, so a
    // bold face taken from one would silently be its regular.
    if bytes.starts_with(b"ttcf") {
        return Err(unsupported(format!(
            "op {op}: its {} face is a font collection (.ttc); pass a single .ttf or \
             .otf face",
            style.key()
        )));
    }

    load(bytes).map_err(|reason| {
        unsupported(format!(
            "op {op}: its {} face is not a font this library can read: {reason}",
            style.key()
        ))
    })
}

fn load(bytes: &[u8]) -> Result<EmbeddedFont, String> {
    let name = postscript_name(bytes).unwrap_or_else(|| "EmbeddedFont".to_string());
    let mut font = EmbeddedFont::from_data(Some(name), bytes.to_vec())?;
    if let Ok(face) = ttf_parser::Face::parse(bytes, 0) {
        font.extend_glyph_lookup(supplementary_glyphs(&face));
    }
    Ok(font)
}

// Populate supplementary cmap entries omitted by the embedded-font lookup.
fn supplementary_glyphs(face: &ttf_parser::Face<'_>) -> HashMap<u32, u16> {
    coverage(face)
        .into_iter()
        .filter(|&c| c > '\u{FFFF}')
        .filter_map(|c| Some((u32::from(c), face.glyph_index(c)?.0)))
        .collect()
}

// PDF names are written unescaped, so retain only characters needing no escape.
fn postscript_name(bytes: &[u8]) -> Option<String> {
    let face = ttf_parser::Face::parse(bytes, 0).ok()?;
    let name: String = face
        .names()
        .into_iter()
        .filter(|name| name.name_id == ttf_parser::name_id::POST_SCRIPT_NAME)
        .find_map(|name| name.to_string())?
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '+'))
        .take(63)
        .collect();

    (!name.is_empty()).then_some(name)
}

fn coverage(face: &ttf_parser::Face<'_>) -> HashSet<char> {
    let mut covered = HashSet::new();
    if let Some(cmap) = face.tables().cmap {
        for subtable in cmap.subtables {
            if subtable.is_unicode() {
                subtable.codepoints(|code| {
                    let mapped = subtable.glyph_index(code).is_some_and(|glyph| glyph.0 != 0);
                    if let (true, Some(c)) = (mapped, char::from_u32(code)) {
                        covered.insert(c);
                    }
                });
            }
        }
    }
    covered
}

fn unsupported(message: String) -> rustler::Error {
    tagged_err(atoms::unsupported(), message)
}

fn family_of(font: FontNif, auto: Family) -> Family {
    match font {
        FontNif::Auto => auto,
        FontNif::Helvetica => Family::Helvetica,
        FontNif::Times => Family::Times,
        FontNif::Courier => Family::Courier,
        FontNif::DejavuSans => Family::DejaVu,
        FontNif::Family(position) => Family::Caller(position),
    }
}

fn auto_family(ops: &[OpNif]) -> Family {
    let helvetica = base14::face("Helvetica").expect("Helvetica is a base-14 face");
    let needs_unicode = ops
        .iter()
        .filter_map(|op| match op {
            OpNif::Paragraph(ParagraphNif {
                font: FontNif::Auto,
                runs,
                ..
            })
            | OpNif::Heading(ParagraphNif {
                font: FontNif::Auto,
                runs,
                ..
            }) => Some(vec![runs]),
            OpNif::TextAt(TextAtNif {
                font: FontNif::Auto,
                runs,
                ..
            })
            | OpNif::TextInRect(TextInRectNif {
                font: FontNif::Auto,
                runs,
                ..
            }) => Some(vec![runs]),
            OpNif::List(ListNif {
                font: FontNif::Auto,
                items,
                ..
            }) => Some(items.iter().collect()),
            OpNif::Table(TableNif {
                font: FontNif::Auto,
                rows,
                ..
            }) => Some(rows.iter().flatten().map(|cell| &cell.runs).collect()),
            _ => None,
        })
        .flatten()
        .flatten()
        .flat_map(|run| run.text.chars())
        .any(|c| !c.is_whitespace() && helvetica.width(c).is_none());

    if needs_unicode {
        Family::DejaVu
    } else {
        Family::Helvetica
    }
}

fn runs(
    op: usize,
    runs: Vec<RunNif>,
    font: FontNif,
    auto: Family,
    faces: &mut Faces<'_, '_>,
) -> NifResult<Vec<Run>> {
    let family = family_of(font, auto);
    let from_auto = matches!(font, FontNif::Auto);

    runs.into_iter()
        .filter(|run| !run.text.is_empty())
        .map(|run| {
            // DejaVu Sans has no italic, so `:auto` sets it upright.
            let italic = run.italic && !(from_auto && family == Family::DejaVu);
            Ok(Run {
                face: faces.face(op, family, Style::of(run.bold, italic))?,
                color: run.color.map(Into::into),
                text: run.text,
            })
        })
        .collect()
}

fn ops(
    ops: Vec<OpNif>,
    faces: &mut Faces<'_, '_>,
    pictures: &mut Pictures<'_, '_>,
) -> NifResult<Vec<Op>> {
    let auto = auto_family(&ops);

    ops.into_iter()
        .enumerate()
        .map(|(index, op)| match op {
            OpNif::Page((width, height)) => Ok(Op::Page { width, height }),
            // Skipped before its faces resolve, so it needs none.
            OpNif::Paragraph(ParagraphNif { runs, .. })
            | OpNif::Heading(ParagraphNif { runs, .. })
                if flow::draws_nothing(runs.iter().map(|run| run.text.as_str())) =>
            {
                Ok(Op::Empty)
            }
            OpNif::List(ListNif { items, .. }) if items.is_empty() => Ok(Op::Empty),
            OpNif::Table(TableNif { rows, .. }) if rows.is_empty() => Ok(Op::Empty),
            OpNif::TextAt(TextAtNif { runs, .. })
            | OpNif::TextInRect(TextInRectNif { runs, .. })
                if flow::draws_nothing(runs.iter().map(|run| run.text.as_str())) =>
            {
                Ok(Op::Blank)
            }
            OpNif::Paragraph(paragraph) => Ok(Op::Paragraph {
                face: faces.face(index, family_of(paragraph.font, auto), Style::Regular)?,
                runs: runs(index, paragraph.runs, paragraph.font, auto, faces)?,
                size: paragraph.font_size,
                keep_with_next: false,
            }),
            // A heading's runs arrive bold, and its line box is the bold face's.
            OpNif::Heading(heading) => Ok(Op::Paragraph {
                face: faces.face(index, family_of(heading.font, auto), Style::Bold)?,
                runs: runs(index, heading.runs, heading.font, auto, faces)?,
                size: heading.font_size,
                keep_with_next: true,
            }),
            OpNif::List(list) => Ok(Op::List {
                face: faces.face(index, family_of(list.font, auto), Style::Regular)?,
                items: list
                    .items
                    .into_iter()
                    .map(|item| runs(index, item, list.font, auto, faces))
                    .collect::<NifResult<_>>()?,
                size: list.font_size,
                marker: list.marker.into(),
                start: list.start,
            }),
            OpNif::Space(points) => Ok(Op::Space(points)),
            OpNif::Rule(size) => Ok(Op::Rule { size }),
            OpNif::TextAt(text) => Ok(Op::TextAt {
                runs: runs(index, text.runs, text.font, auto, faces)?,
                size: text.font_size,
                x: text.x,
                y: text.y,
            }),
            OpNif::TextInRect(text) => Ok(Op::TextInRect {
                face: faces.face(index, family_of(text.font, auto), Style::Regular)?,
                runs: runs(index, text.runs, text.font, auto, faces)?,
                size: text.font_size,
                x: text.x,
                y: text.y,
                width: text.width,
                height: text.height,
                align: text.align.into(),
            }),
            OpNif::Path(shape) => Ok(Op::Path(shape.into())),
            OpNif::Table(table) => table_op(index, table, auto, faces),
            OpNif::Image(image) => Ok(Op::Image(FlowImage {
                pixels: pictures.pixels(index, image.image)?,
                image: image.image,
                width: image.width,
                height: image.height,
                fit: image.fit.into(),
                align: image.align.into(),
                size: image.font_size,
            })),
            OpNif::ImageInRect(image) => Ok(Op::ImageInRect {
                pixels: pictures.pixels(index, image.image)?,
                image: image.image,
                rect: [image.x, image.y, image.width, image.height],
                fit: image.fit.into(),
            }),
        })
        .collect()
}

fn table_op(
    index: usize,
    table: TableNif,
    auto: Family,
    faces: &mut Faces<'_, '_>,
) -> NifResult<Op> {
    let font = table.font;
    let rows = table
        .rows
        .into_iter()
        .map(|cells| {
            cells
                .into_iter()
                .map(|cell| {
                    Ok(Cell {
                        runs: runs(index, cell.runs, font, auto, faces)?,
                        column: cell.column,
                        colspan: cell.colspan,
                        rowspan: cell.rowspan,
                        align: cell.align.into(),
                        fill: cell.fill_color.map(Into::into),
                    })
                })
                .collect::<NifResult<Vec<_>>>()
        })
        .collect::<NifResult<Vec<_>>>()?;

    Ok(Op::Table(Table {
        face: faces.face(index, family_of(font, auto), Style::Regular)?,
        rows,
        size: table.font_size,
        widths: table.column_widths.into_iter().map(Into::into).collect(),
        header_rows: table.header_rows,
        header_fill: table.header_fill.map(Into::into),
        padding: table.padding,
        stroke: table.stroke_color.map(|color| Stroke {
            color: color.into(),
            width: table.stroke_width,
            dash: None,
        }),
    }))
}

fn refused(refusal: Refused) -> rustler::Error {
    let message = match refusal {
        Refused::LineTooTall {
            op,
            page,
            line,
            room,
        } => format!(
            "op {op} on page {page}: a line {line} points tall (font size × line height) \
             does not fit the {room}-point content height; reduce the font size, the \
             line height or the margins"
        ),
        Refused::NoWidth { op, page } => {
            format!("op {op} on page {page}: the left and right margins leave no room for text")
        }
        Refused::ClusterTooWide {
            op,
            page,
            cluster,
            width,
            room,
            within: Within::Line,
        } => format!(
            "op {op} starting on page {page}: {cluster:?} is {width} points wide, wider than \
             the {room}-point line; reduce the font size or the left and right margins"
        ),
        Refused::ClusterTooWide {
            op,
            page,
            cluster,
            width,
            room,
            within: Within::Box,
        } => format!(
            "op {op} on page {page}: {cluster:?} is {width} points wide, wider than the \
             {room}-point box; reduce the font size or widen the box"
        ),
        Refused::ClusterTooWide {
            op,
            page,
            cluster,
            width,
            room,
            within: Within::Cell { row, column },
        } => format!(
            "op {op} on page {page}: {cluster:?} is {width} points wide, wider than the \
             {room}-point text width of the cell at row {row}, column {column}; reduce the \
             font size or the padding, or widen the column"
        ),
        Refused::TableTooTall {
            op,
            page,
            rows: (first, last),
            needed,
            room,
        } => {
            let rows = if first == last {
                format!("row {first}")
            } else {
                format!("rows {first} to {last}")
            };
            format!(
                "op {op} on page {page}: the table needs {needed} points to start {rows} \
                 below its header rows, more than the {room}-point content height; a row \
                 breaks across pages only between lines, and rows a cell spans stay \
                 together, so reduce the font size, the padding or the header rows, or \
                 shorten the text in those rows"
            )
        }
        Refused::ColumnsTooWide {
            op,
            page,
            needed,
            room,
        } => format!(
            "op {op} on page {page}: the table's columns need at least {needed} points, more \
             than the {room}-point content width; narrow the fixed columns, reduce the font \
             size or the padding, or widen the margins"
        ),
        Refused::NoRoomForWeights { op, page } => format!(
            "op {op} on page {page}: the table's fixed and :auto columns leave its weighted \
             columns no room for text; narrow the fixed columns or give the :auto ones points"
        ),
        Refused::Overflow {
            op,
            page,
            lines,
            needed,
            room,
        } => format!(
            "op {op} on page {page}: the text takes {lines} lines, {needed} points, more than \
             the {room}-point box holds; enlarge the box, reduce the font size or the line \
             height, or shorten the text"
        ),
        Refused::Imprecise { op, page, size } => format!(
            "op {op} on page {page}: the page is too large to place {size}-point text \
             precisely; use a smaller page or larger text"
        ),
        Refused::Undrawable {
            op,
            page,
            character,
            face,
            built_in: true,
        } => format!(
            "op {op} on page {page}: {face} cannot draw {character:?} (U+{:04X}); the \
             built-in fonts draw only Windows-1252 characters, so pass a FontFamily that \
             covers it, or font: :auto",
            u32::from(character)
        ),
        Refused::Undrawable {
            op,
            page,
            character,
            face,
            built_in: false,
        } => format!(
            "op {op} on page {page}: {face} has no glyph for {character:?} (U+{:04X}); \
             pass a FontFamily that covers it",
            u32::from(character)
        ),
        Refused::Unordered {
            op,
            page,
            character,
            reason,
        } => {
            let why = match reason {
                Unordered::RightToLeft => {
                    "is right-to-left text, which would be drawn left to right"
                }
                Unordered::NeedsShaping => {
                    "is in a script that needs shaping, which would be drawn with its letters \
                     unjoined or out of place"
                }
            };
            format!(
                "op {op} on page {page}: {character:?} (U+{:04X}) {why}; the builder lays out \
                 only text that reads left to right without shaping",
                u32::from(character)
            )
        }
        Refused::OffPage {
            op,
            page,
            flowing: false,
        } => format!(
            "op {op} on page {page}: the text would extend past the edge of the page; \
             move it or make it shorter"
        ),
        Refused::OffPage {
            op,
            page,
            flowing: true,
        } => format!(
            "op {op} on page {page}: an accent or italic overhang would extend past the \
             edge of the page; widen the margins or increase the line height"
        ),
        Refused::CounterOverflow { op, page } => {
            format!("op {op} on page {page}: the list's numbering overflows; use a smaller :start")
        }
        Refused::ImageTooLarge {
            op,
            page,
            needed: (width, height),
            room: (room_width, room_height),
        } => format!(
            "op {op} on page {page}: an image {width} × {height} points does not fit the \
             {room_width} × {room_height}-point content area; give a smaller :width or \
             :height, or reduce the margins"
        ),
    };

    unsupported(message)
}

fn emit(
    meta: Meta,
    fonts: &Fonts,
    sources: &[(usize, &[u8])],
    images: &[Option<ImageData>],
    plan: Vec<PagePlan>,
) -> NifResult<Vec<u8>> {
    let mut doc = DocumentBuilder::new();
    if let Some(title) = meta.title {
        doc = doc.title(title);
    }
    if let Some(author) = meta.author {
        doc = doc.author(author);
    }
    if let Some(subject) = meta.subject {
        doc = doc.subject(subject);
    }
    if let Some(creator) = meta.creator {
        doc = doc.creator(creator);
    }
    for &(face, bytes) in sources {
        let font = load(bytes)
            .map_err(|reason| unsupported(format!("a face parsed once failed again: {reason}")))?;
        doc = doc.register_embedded_font(embedded_key(face), font);
    }

    for page in plan {
        let mut builder = doc.page(PageSize::Custom(page.width as f32, page.height as f32));
        for item in page.items {
            builder = match item {
                Item::Text(placed) => {
                    let mut style = TextStyle::default();
                    if let Some(color) = placed.color {
                        style.color = color_from_components(color);
                    }
                    let text = TextContent::new(
                        placed.text,
                        Rect::new(
                            placed.x as f32,
                            placed.baseline as f32,
                            placed.width as f32,
                            placed.size as f32,
                        ),
                        FontSpec {
                            name: fonts.key(placed.face),
                            size: placed.size as f32,
                        },
                        style,
                    );
                    builder.element(ContentElement::Text(text))
                }
                Item::Path(shape) => builder.element(ContentElement::Path(path_content(shape))),
                Item::Image(Picture {
                    image,
                    x,
                    y,
                    width,
                    height,
                }) => {
                    let data = images[image]
                        .clone()
                        .expect("an image is decoded where an op uses it");
                    builder.image_with(
                        data,
                        Rect::new(x as f32, y as f32, width as f32, height as f32),
                    )
                }
            };
        }
        builder.done();
    }

    doc.build().map(label_opentype_fonts).map_err(to_nif_err)
}

// Assigned field by field so a field upstream adds keeps its default.
fn path_content(shape: Shape) -> PathContent {
    let mut path = PathContent::from_operations(shape.operations);
    path.fill_color = shape.fill.map(color_from_components);
    path.stroke_color = None;
    if let Some(stroke) = shape.stroke {
        path.stroke_color = Some(color_from_components(stroke.color));
        path.stroke_width = stroke.width;
        path.dash_pattern = stroke.dash;
    }
    path
}

// The writer embeds a CFF face as the whole OpenType file but labels it bare
// CFF. The label is renamed in place, padded so no offset in the file moves.
// The writer escapes a newline in every string, so the pattern can only open a
// stream, and it is taken only where that stream holds an OpenType font and
// ends where its `/Length` says.
fn label_opentype_fonts(mut pdf: Vec<u8>) -> Vec<u8> {
    const BARE_CFF: &[u8] = b"/Subtype /CIDFontType0C>>\nstream\n";
    const OPENTYPE: &[u8] = b"/Subtype /OpenType     >>\nstream\n";

    let mut from = 0;
    while let Some(found) = pdf[from..]
        .windows(BARE_CFF.len())
        .position(|window| window == BARE_CFF)
        .map(|offset| from + offset)
    {
        let data = found + BARE_CFF.len();
        let ends = stream_length(&pdf[..found])
            .and_then(|length| pdf.get(data + length..))
            .is_some_and(|rest| rest.starts_with(b"\nendstream"));
        if ends && pdf[data..].starts_with(b"OTTO") {
            pdf[found..data].copy_from_slice(OPENTYPE);
        }
        from = data;
    }
    pdf
}

// The `/Length` that opens the dictionary ending at `before`'s end.
fn stream_length(before: &[u8]) -> Option<usize> {
    let digits = before
        .iter()
        .rev()
        .take_while(|byte| byte.is_ascii_digit())
        .count();
    let (head, number) = before.split_at(before.len() - digits);
    if !head.ends_with(b"<</Length ") {
        return None;
    }
    std::str::from_utf8(number).ok()?.parse().ok()
}

struct Meta {
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
    creator: Option<String>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_builder<'a>(build: BuildNif<'a>) -> NifResult<OpenedEditor> {
    let margins = Margins {
        top: build.margin_top,
        bottom: build.margin_bottom,
        left: build.margin_left,
        right: build.margin_right,
    };
    let meta = Meta {
        title: build.title,
        author: build.author,
        subject: build.subject,
        creator: build.creator,
    };
    let page_size = build.page_size;
    let line_height = build.line_height;
    let families = &build.families;
    let images = &build.images;
    let op_nifs = build.ops;

    // Fonts are parsed inside, so a panic in the font parser is contained too.
    create_from_bytes(move || {
        let mut faces = Faces {
            families,
            fonts: Fonts::new(),
            sources: Vec::new(),
            index: HashMap::new(),
        };
        let mut pictures = Pictures {
            sources: images,
            decoded: vec![None; images.len()],
        };
        let ops = ops(op_nifs, &mut faces, &mut pictures)?;
        keep_apart(pictures.decoded.iter_mut().flatten());
        let plan =
            flow::lay_out(&faces.fonts, &margins, line_height, page_size, &ops).map_err(refused)?;

        emit(meta, &faces.fonts, &faces.sources, &pictures.decoded, plan)
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{
        elements::{
            ContentElement, FontSpec, LineCap, LineJoin, PathContent, PathOperation,
            StructureElement, TextContent, TextStyle,
        },
        fonts::bundled::DEJAVU_SANS,
        geometry::Rect,
        object::Object,
        writer::{
            DocumentBuilder, EmbeddedFont, FontManager, PageSize, StreamingColumn,
            StreamingTableConfig, Table, TableCell, TextLayout,
        },
        PdfDocument,
    };

    use crate::metadata::read_metadata;

    fn fixture(name: &str) -> Vec<u8> {
        let path = format!("{}/../../test/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
        std::fs::read(path).expect("fixture exists")
    }

    fn text_element(text: &str, font: &str, y: f32) -> ContentElement {
        ContentElement::Text(TextContent::new(
            text,
            Rect::new(72.0, y, 200.0, 12.0),
            FontSpec {
                name: font.into(),
                size: 12.0,
            },
            TextStyle::default(),
        ))
    }

    fn structure(kind: &str, children: Vec<ContentElement>) -> ContentElement {
        ContentElement::Structure(StructureElement {
            structure_type: kind.into(),
            children,
            ..StructureElement::default()
        })
    }

    #[test]
    fn upstream_still_draws_tagged_embedded_text_on_the_base14_path() {
        let font = EmbeddedFont::from_data(None, DEJAVU_SANS.to_vec()).expect("parses");
        let mut builder = DocumentBuilder::new()
            .tagged_pdf_ua1()
            .register_embedded_font("F", font);
        builder
            .page(PageSize::Letter)
            .element(text_element("Привет top", "F", 700.0))
            .element(structure(
                "P",
                vec![text_element("Привет tagged", "F", 680.0)],
            ))
            .done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");
        let text = doc.extract_text(0).expect("extracts");

        assert!(text.contains("Привет top"));
        assert!(!text.contains("Привет tagged"));
    }

    #[test]
    fn upstream_still_lists_only_top_level_structure_in_the_parent_tree() {
        let mut builder = DocumentBuilder::new().tagged_pdf_ua1();
        builder
            .page(PageSize::Letter)
            .element(structure(
                "L",
                vec![
                    structure("LI", vec![text_element("one", "Helvetica", 700.0)]),
                    structure("LI", vec![text_element("two", "Helvetica", 680.0)]),
                ],
            ))
            .done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");
        let entry = |dict: &Object, key: &str| {
            let value = dict.as_dict().and_then(|dict| dict.get(key)).expect(key);
            doc.resolve_references(value, 1).expect("resolves")
        };
        let root = entry(&doc.catalog().expect("has a catalog"), "StructTreeRoot");
        let nums = entry(&entry(&root, "ParentTree"), "Nums");
        let nums = nums.as_array().expect("is an array");

        // Three marked-content IDs on page 0, one entry for them.
        assert_eq!(nums.len(), 2);
        assert_eq!(nums[1].as_array().map(Vec::len), Some(1));
    }

    #[test]
    fn upstream_still_ignores_keywords_in_the_document_builder() {
        let mut builder = DocumentBuilder::new().keywords("kw");
        builder.page(PageSize::Letter).text("Hello").done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");

        assert_eq!(read_metadata(&doc).keywords, None);
    }

    #[test]
    fn upstream_still_ignores_line_cap_and_join_on_a_path() {
        let mut path = PathContent::from_operations(vec![
            PathOperation::MoveTo(0.0, 0.0),
            PathOperation::LineTo(10.0, 10.0),
        ]);
        path.line_cap = LineCap::Round;
        path.line_join = LineJoin::Round;
        let mut builder = DocumentBuilder::new();
        builder
            .page(PageSize::Letter)
            .element(ContentElement::Path(path))
            .done();
        let pdf = builder.build().expect("builds");
        let contains = |op: &[u8]| pdf.windows(op.len()).any(|window| window == op);

        assert!(contains(b"\nS\n"));
        assert!(!contains(b"1 J\n"));
        assert!(!contains(b"1 j\n"));
    }

    #[test]
    fn upstream_still_measures_base14_text_with_approximate_widths() {
        let manager = FontManager::new();

        assert_eq!(manager.char_width('\'', "Helvetica", 1000.0), 222.0);
        assert_eq!(manager.char_width('—', "Helvetica", 1000.0), 500.0);
    }

    // The collection is the fixture's regular face, then its bold.
    #[test]
    fn upstream_still_reads_only_the_first_face_of_a_collection() {
        let collection = EmbeddedFont::from_data(None, fixture("font_collection.ttc"))
            .expect("a collection parses");
        let regular = EmbeddedFont::from_data(None, fixture("font_truetype.ttf")).expect("parses");
        let m = u32::from('M');

        assert_eq!(collection.char_width(m), regular.char_width(m));
        assert_eq!(collection.name, "Unknown");
    }

    #[test]
    fn upstream_still_wraps_embedded_fonts_with_helvetica_widths() {
        let layout = TextLayout::new();
        let helvetica = FontManager::new().text_width("MMMM", "Helvetica", 12.0);
        let [(_, width)] = layout.wrap_text("MMMM", "DejaVuSans", 12.0, 1000.0)[..] else {
            panic!("one line");
        };

        assert_eq!(width, helvetica);
    }

    // Each row is 20 points, so 35 rows run from the top margin to below the
    // bottom one but stay on the page.
    #[test]
    fn upstream_still_draws_a_table_past_the_bottom_margin() {
        let rows = (0..35)
            .map(|row| vec![TableCell::text(format!("row {row}"))])
            .collect();
        let mut builder = DocumentBuilder::new();
        builder
            .page(PageSize::Letter)
            .table(Table::new(rows))
            .done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");
        let chars = doc.extract_chars(0).expect("extracts");

        assert_eq!(doc.page_count().expect("counts"), 1);
        assert!(chars.iter().any(|c| c.bbox.y < 72.0));
    }

    // A row under a span still names every column.
    #[test]
    fn upstream_still_finishes_a_short_rowspan_group() {
        let config = StreamingTableConfig::new()
            .column(StreamingColumn::new("a"))
            .column(StreamingColumn::new("b"))
            .max_rowspan(3);
        let mut builder = DocumentBuilder::new();
        let mut table = builder.page(PageSize::Letter).streaming_table(config);
        table
            .push_row(|row| {
                row.span_cell("spanned", 3).cell("one");
            })
            .expect("pushes");
        table
            .push_row(|row| {
                row.cell("").cell("two");
            })
            .expect("pushes");
        table.finish().done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");
        let text = doc.extract_text(0).expect("extracts");

        assert!(text.contains("spanned") && text.contains("two"));
    }

    #[test]
    fn upstream_still_names_a_font_unknown_when_its_mac_record_comes_first() {
        let font = EmbeddedFont::from_data(None, DEJAVU_SANS.to_vec()).expect("parses");

        assert_eq!(font.name, "Unknown");
        assert_eq!(
            super::postscript_name(DEJAVU_SANS).as_deref(),
            Some("DejaVuSans")
        );
    }

    #[test]
    fn upstream_still_substitutes_a_glyph_the_font_lacks() {
        let bytes = fixture("font_truetype.ttf");
        let font = EmbeddedFont::from_data(None, bytes.clone()).expect("parses");
        let face = ttf_parser::Face::parse(&bytes, 0).expect("parses");

        assert!(!super::coverage(&face).contains(&'•'));
        assert_eq!(font.glyph_id(u32::from('•')), font.glyph_id(u32::from('*')));
    }

    #[test]
    fn upstream_still_maps_only_part_of_the_cmap_beyond_the_bmp() {
        let font = EmbeddedFont::from_data(None, DEJAVU_SANS.to_vec()).expect("parses");
        let face = ttf_parser::Face::parse(DEJAVU_SANS, 0).expect("parses");

        assert!(face.glyph_index('\u{10300}').is_some());
        assert_eq!(font.glyph_id(0x10300), None);
        assert_eq!(font.glyph_id(0x1D5A0), font.glyph_id(u32::from('A')));
    }

    #[test]
    fn upstream_still_labels_an_opentype_font_as_bare_cff() {
        let font = EmbeddedFont::from_data(None, fixture("font_cff_regular.otf")).expect("parses");
        let mut builder = DocumentBuilder::new().register_embedded_font("F", font);
        builder
            .page(PageSize::Letter)
            .font("F", 12.0)
            .text("a")
            .done();
        let pdf = builder.build().expect("builds");
        let bare = b"/Subtype /CIDFontType0C>>\nstream\nOTTO";

        assert!(pdf.windows(bare.len()).any(|window| window == bare));
    }

    #[test]
    fn only_a_stream_that_ends_at_its_length_is_relabeled() {
        let stream = |length: usize| {
            format!("<</Length {length}/Subtype /CIDFontType0C>>\nstream\nOTTOdata\nendstream")
                .into_bytes()
        };

        assert!(String::from_utf8(super::label_opentype_fonts(stream(8)))
            .expect("ascii")
            .contains("/Subtype /OpenType     >>"));
        assert_eq!(super::label_opentype_fonts(stream(9)), stream(9));
    }

    #[test]
    fn upstream_still_draws_a_missing_glyph_as_gid_zero() {
        let font = EmbeddedFont::from_data(None, DEJAVU_SANS.to_vec()).expect("parses");
        assert_eq!(font.glyph_id(u32::from('中')), None);

        let mut builder = DocumentBuilder::new().register_embedded_font("F", font);
        builder
            .page(PageSize::Letter)
            .font("F", 12.0)
            .text("a中b")
            .done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");

        assert!(!doc.extract_text(0).expect("extracts").contains('中'));
    }
}
