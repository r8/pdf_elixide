use std::collections::{HashMap, HashSet};

use pdf_oxide::{
    editor::{DocumentEditor, FormFieldValue, SaveOptions},
    elements::{ContentElement, FontSpec, PathContent, TextContent, TextStyle},
    fonts::bundled::{DEJAVU_SANS, DEJAVU_SANS_BOLD},
    geometry::Rect,
    writer::{
        Annotation, DocumentBuilder, EmbeddedFont, FitMode, FluentPageBuilder, ImageData,
        LinkAction, LinkAnnotation, PageSize, WatermarkAnnotation,
    },
};
use rustler::{Binary, NifMap, NifResult, NifTaggedEnum, NifUnitEnum};

use crate::{
    atoms,
    base14::{self, Base14},
    color::{color_from_components, RgbNif},
    create::{create_from_bytes, decoded, keep_apart},
    editor::OpenedEditor,
    error::{tagged_err, to_nif_err},
    flow::{
        self, embedded_key, Align, Barcode, Caption, Cell, Embedded, Face, Fit, FlowImage, Fonts,
        Item, Margins, Marker, Op, Picture, Placed, Plan, Refused, Run, Shape, Stroke, Table,
        Unordered, Watermark, Width, Within,
    },
    open_editor::OpenEditor,
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
    ops: Vec<OpNif<'a>>,
}

#[derive(NifMap)]
pub struct FamilyNif<'a> {
    regular: Binary<'a>,
    bold: Option<Binary<'a>>,
    italic: Option<Binary<'a>>,
    bold_italic: Option<Binary<'a>>,
}

#[derive(NifTaggedEnum)]
pub enum OpNif<'a> {
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
    Barcode(BarcodeNif<'a>),
    BarcodeInRect(BarcodeInRectNif<'a>),
    Anchor(String),
    LinkInRect(LinkInRectNif),
    Watermark(WatermarkNif),
    Field(FieldNif),
}

#[derive(NifMap)]
pub struct FieldNif {
    name: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    required: bool,
    read_only: bool,
    tooltip: Option<String>,
    kind: FieldKindNif,
}

#[derive(NifTaggedEnum)]
pub enum FieldKindNif {
    Text(TextFieldNif),
    CheckBox(bool),
    ComboBox(ComboBoxNif),
    ListBox(ListBoxNif),
    PushButton(String),
    Signature,
}

#[derive(NifMap)]
pub struct TextFieldNif {
    value: Option<String>,
    default_value: Option<String>,
}

#[derive(NifMap)]
pub struct ComboBoxNif {
    options: Vec<String>,
    selected: Option<String>,
}

#[derive(NifMap)]
pub struct ListBoxNif {
    options: Vec<String>,
    selected: Vec<String>,
    multi_select: bool,
}

#[derive(NifTaggedEnum, Clone)]
pub enum LinkNif {
    Uri(String),
    Page(usize),
    Anchor(String),
}

#[derive(NifMap)]
pub struct LinkInRectNif {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    link: LinkNif,
}

#[derive(NifMap)]
pub struct WatermarkNif {
    text: String,
    pages: PagesNif,
    center: Option<(f64, f64)>,
    rotation: f64,
    font: WatermarkFontNif,
    bold: bool,
    font_size: f64,
    color: RgbNif,
    opacity: f64,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum PagesNif {
    Current,
    All,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum WatermarkFontNif {
    Helvetica,
    Times,
    Courier,
}

// Flow link ids index this table; retain the originating op for refusals.
struct Link {
    op: usize,
    target: LinkNif,
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

#[derive(NifMap)]
pub struct BarcodeNif<'a> {
    barcode: SymbolNif<'a>,
    width: f64,
    height: f64,
    align: AlignNif,
    font_size: f64,
}

#[derive(NifMap)]
pub struct BarcodeInRectNif<'a> {
    barcode: SymbolNif<'a>,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(NifMap)]
pub struct SymbolNif<'a> {
    columns: usize,
    rows: usize,
    modules: Binary<'a>,
    quiet_zone: f64,
    color: RgbNif,
    background: Option<RgbNif>,
    caption: Option<ParagraphNif>,
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
    link: Option<LinkNif>,
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

fn auto_family(ops: &[OpNif<'_>]) -> Family {
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
            OpNif::Barcode(BarcodeNif { barcode, .. })
            | OpNif::BarcodeInRect(BarcodeInRectNif { barcode, .. }) => match &barcode.caption {
                Some(ParagraphNif {
                    font: FontNif::Auto,
                    runs,
                    ..
                }) => Some(vec![runs]),
                _ => None,
            },
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
    links: &mut Vec<Link>,
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
                link: run.link.map(|target| linked(links, op, target)),
                text: run.text,
            })
        })
        .collect()
}

fn linked(links: &mut Vec<Link>, op: usize, target: LinkNif) -> usize {
    links.push(Link { op, target });
    links.len() - 1
}

fn watermark(mark: WatermarkNif) -> Watermark {
    let family = match mark.font {
        WatermarkFontNif::Helvetica => Family::Helvetica,
        WatermarkFontNif::Times => Family::Times,
        WatermarkFontNif::Courier => Family::Courier,
    };
    Watermark {
        text: mark.text,
        font: base14_name(family, Style::of(mark.bold, false)).expect("a built-in family"),
        size: mark.font_size,
        rotation: mark.rotation,
        color: mark.color.into(),
        opacity: mark.opacity,
        center: mark.center,
    }
}

fn ops(
    ops: Vec<OpNif<'_>>,
    faces: &mut Faces<'_, '_>,
    pictures: &mut Pictures<'_, '_>,
    links: &mut Vec<Link>,
    fields: &mut Vec<FieldNif>,
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
                runs: runs(index, paragraph.runs, paragraph.font, auto, faces, links)?,
                size: paragraph.font_size,
                keep_with_next: false,
            }),
            // A heading's runs arrive bold, and its line box is the bold face's.
            OpNif::Heading(heading) => Ok(Op::Paragraph {
                face: faces.face(index, family_of(heading.font, auto), Style::Bold)?,
                runs: runs(index, heading.runs, heading.font, auto, faces, links)?,
                size: heading.font_size,
                keep_with_next: true,
            }),
            OpNif::List(list) => Ok(Op::List {
                face: faces.face(index, family_of(list.font, auto), Style::Regular)?,
                items: list
                    .items
                    .into_iter()
                    .map(|item| runs(index, item, list.font, auto, faces, links))
                    .collect::<NifResult<_>>()?,
                size: list.font_size,
                marker: list.marker.into(),
                start: list.start,
            }),
            OpNif::Space(points) => Ok(Op::Space(points)),
            OpNif::Rule(size) => Ok(Op::Rule { size }),
            OpNif::TextAt(text) => Ok(Op::TextAt {
                runs: runs(index, text.runs, text.font, auto, faces, links)?,
                size: text.font_size,
                x: text.x,
                y: text.y,
            }),
            OpNif::TextInRect(text) => Ok(Op::TextInRect {
                face: faces.face(index, family_of(text.font, auto), Style::Regular)?,
                runs: runs(index, text.runs, text.font, auto, faces, links)?,
                size: text.font_size,
                x: text.x,
                y: text.y,
                width: text.width,
                height: text.height,
                align: text.align.into(),
            }),
            OpNif::Path(shape) => Ok(Op::Path(shape.into())),
            OpNif::Table(table) => table_op(index, table, auto, faces, links),
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
            OpNif::Barcode(barcode) => Ok(Op::Barcode {
                barcode: symbol(index, barcode.barcode, auto, faces, links)?,
                width: barcode.width,
                height: barcode.height,
                align: barcode.align.into(),
                size: barcode.font_size,
            }),
            OpNif::BarcodeInRect(barcode) => Ok(Op::BarcodeInRect {
                barcode: symbol(index, barcode.barcode, auto, faces, links)?,
                rect: [barcode.x, barcode.y, barcode.width, barcode.height],
            }),
            OpNif::Anchor(name) => Ok(Op::Anchor(name)),
            OpNif::LinkInRect(area) => Ok(Op::LinkInRect {
                link: linked(links, index, area.link),
                rect: [area.x, area.y, area.width, area.height],
            }),
            OpNif::Watermark(mark) => Ok(Op::Watermark {
                every_page: matches!(mark.pages, PagesNif::All),
                mark: watermark(mark),
            }),
            OpNif::Field(field) => {
                fields.push(field);
                Ok(Op::Field(fields.len() - 1))
            }
        })
        .collect()
}

fn symbol(
    index: usize,
    symbol: SymbolNif<'_>,
    auto: Family,
    faces: &mut Faces<'_, '_>,
    links: &mut Vec<Link>,
) -> NifResult<Barcode> {
    if symbol.modules.len() != symbol.columns * symbol.rows {
        return Err(rustler::Error::BadArg);
    }
    let caption = symbol
        .caption
        .map(|caption| -> NifResult<Caption> {
            Ok(Caption {
                face: faces.face(index, family_of(caption.font, auto), Style::Regular)?,
                runs: runs(index, caption.runs, caption.font, auto, faces, links)?,
                size: caption.font_size,
            })
        })
        .transpose()?;

    Ok(Barcode {
        columns: symbol.columns,
        rows: symbol.rows,
        modules: symbol.modules.as_slice().to_vec(),
        quiet_zone: symbol.quiet_zone,
        color: symbol.color.into(),
        background: symbol.background.map(Into::into),
        caption,
    })
}

fn table_op(
    index: usize,
    table: TableNif,
    auto: Family,
    faces: &mut Faces<'_, '_>,
    links: &mut Vec<Link>,
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
                        runs: runs(index, cell.runs, font, auto, faces, links)?,
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
        Refused::LinkImprecise { op, page } => format!(
            "op {op} on page {page}: where the link's area overlaps the page it is under \
             0.00001 points across once written, or the page is too large to place it \
             precisely; enlarge the area or use a smaller page"
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
        Refused::TooLarge {
            op,
            page,
            what,
            options,
            needed: (width, height),
            room: (room_width, room_height),
        } => format!(
            "op {op} on page {page}: {what} {width} × {height} points does not fit the \
             {room_width} × {room_height}-point content area; give a smaller {options}, \
             or reduce the margins"
        ),
        Refused::NoSuchPage {
            op,
            page,
            target,
            pages,
        } => format!(
            "op {op} on page {page}: the link points to page {target}, but the document has \
             {pages} page{}, numbered from 0; link to a page that exists",
            if pages == 1 { "" } else { "s" }
        ),
        Refused::NoSuchAnchor { op, page, name } => format!(
            "op {op} on page {page}: the link points to anchor {name:?}, which no anchor/2 \
             call names; add the anchor or correct the name"
        ),
    };

    unsupported(message)
}

fn emit(
    meta: Meta,
    fonts: &Fonts,
    sources: &[(usize, &[u8])],
    images: &[Option<ImageData>],
    plan: Plan,
    links: &[Link],
    fields: &[FieldNif],
) -> NifResult<Vec<u8>> {
    check_targets(&plan, links).map_err(refused)?;

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

    let Plan {
        pages,
        anchors,
        watermarks,
    } = plan;
    for page in pages {
        let mut builder = doc.page(PageSize::Custom(page.width as f32, page.height as f32));
        let mut annotations = PageLinks::default();
        for item in page.items {
            builder = match item {
                Item::Text(placed) => {
                    if let Some(link) = placed.link {
                        annotations.text(link, text_box(fonts, &placed));
                    }
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
                Item::Link {
                    link,
                    rect: [x, y, width, height],
                } => {
                    let (left, bottom) = (x as f32, y as f32);
                    annotations.area(
                        link,
                        Rect::new(
                            left,
                            bottom,
                            span(left, (x + width) as f32),
                            span(bottom, (y + height) as f32),
                        ),
                    );
                    builder
                }
                Item::Watermark(mark) => {
                    annotations.watermark(mark);
                    builder
                }
                Item::Field(field) => form_field(builder, &fields[field]),
            };
        }
        for mark in &watermarks {
            annotations.watermark(mark.clone());
        }
        for annotation in annotations.build(links, &anchors, (page.width, page.height)) {
            builder = builder.add_annotation(annotation);
        }
        builder.done();
    }

    let pdf = doc.build().map(label_opentype_fonts).map_err(to_nif_err)?;
    fill(pdf, fields).map_err(to_nif_err)
}

// The page builder's own field writer, because it is the one that writes each
// widget's print flag, tooltip, border and caption; the editor's drops them.
fn form_field<'a>(builder: FluentPageBuilder<'a>, field: &FieldNif) -> FluentPageBuilder<'a> {
    let name = field.name.clone();
    let [x, y, width, height] = [field.x, field.y, field.width, field.height].map(|n| n as f32);
    let builder = match &field.kind {
        FieldKindNif::Text(text) => {
            builder.text_field(name, x, y, width, height, text.default_value.clone())
        }
        &FieldKindNif::CheckBox(checked) => builder.checkbox(name, x, y, width, height, checked),
        FieldKindNif::ComboBox(combo) => builder.combo_box(
            name,
            x,
            y,
            width,
            height,
            combo.options.clone(),
            combo.selected.clone(),
        ),
        FieldKindNif::ListBox(list) => builder.list_box(
            name,
            x,
            y,
            width,
            height,
            list.options.clone(),
            single_selection(list).cloned(),
            list.multi_select,
        ),
        FieldKindNif::PushButton(caption) => {
            builder.push_button(name, x, y, width, height, caption.clone())
        }
        FieldKindNif::Signature => builder.signature_field(name, x, y, width, height),
    };
    // Each modifier applies to the field queued last on the page.
    let builder = if field.required {
        builder.required()
    } else {
        builder
    };
    let builder = if field.read_only {
        builder.read_only()
    } else {
        builder
    };
    match &field.tooltip {
        Some(tooltip) => builder.tooltip(tooltip.clone()),
        None => builder,
    }
}

fn single_selection(list: &ListBoxNif) -> Option<&String> {
    match list.selected.as_slice() {
        [selected] if !list.multi_select => Some(selected),
        _ => None,
    }
}

// Values the page builder cannot write: it sets a text field's default only,
// and a list's selection only as one string.
fn fill(pdf: Vec<u8>, fields: &[FieldNif]) -> pdf_oxide::Result<Vec<u8>> {
    let values: Vec<_> = fields
        .iter()
        .filter_map(|field| match &field.kind {
            FieldKindNif::Text(TextFieldNif {
                value: Some(value), ..
            }) => Some((&field.name, FormFieldValue::Text(value.clone()))),
            FieldKindNif::ListBox(list) if list.multi_select && !list.selected.is_empty() => {
                Some((
                    &field.name,
                    FormFieldValue::MultiChoice(list.selected.clone()),
                ))
            }
            _ => None,
        })
        .collect();
    if values.is_empty() {
        return Ok(pdf);
    }

    // An upstream full rewrite drops `/Info`; the editor's own saves put it back.
    let mut editor = OpenEditor::new(DocumentEditor::from_bytes(pdf)?);
    for (name, value) in values {
        editor.set_form_field_value(name, value)?;
    }
    editor.resupply_info()?;
    editor.save_to_bytes_with_options(SaveOptions::full_rewrite())
}

// Refuse missing targets before the writer silently drops their destinations.
fn check_targets(plan: &Plan, links: &[Link]) -> Result<(), Refused> {
    for (page, plan_page) in plan.pages.iter().enumerate() {
        for item in &plan_page.items {
            let link = match item {
                Item::Text(Placed {
                    link: Some(link), ..
                })
                | Item::Link { link, .. } => *link,
                _ => continue,
            };
            let op = links[link].op;
            match &links[link].target {
                &LinkNif::Page(target) if target >= plan.pages.len() => {
                    return Err(Refused::NoSuchPage {
                        op,
                        page,
                        target,
                        pages: plan.pages.len(),
                    });
                }
                LinkNif::Anchor(name) if !plan.anchors.contains_key(name) => {
                    return Err(Refused::NoSuchAnchor {
                        op,
                        page,
                        name: name.clone(),
                    });
                }
                _ => {}
            }
        }
    }
    Ok(())
}

fn text_box(fonts: &Fonts, placed: &Placed) -> [f64; 4] {
    let (ascent, descent) = fonts.ascent_descent(placed.face);
    [
        placed.x,
        placed.baseline + descent * placed.size / 1000.0,
        placed.x + placed.width,
        placed.baseline + ascent * placed.size / 1000.0,
    ]
}

enum Pending {
    Text(usize),
    Area(usize, Rect),
    Watermark(Watermark),
}

// Preserve paint order while grouping a run's fragments into one link per page.
#[derive(Default)]
struct PageLinks {
    pending: Vec<Pending>,
    boxes: HashMap<usize, Vec<[f64; 4]>>,
}

impl PageLinks {
    fn text(&mut self, link: usize, frame: [f64; 4]) {
        let boxes = self.boxes.entry(link).or_default();
        if boxes.is_empty() {
            self.pending.push(Pending::Text(link));
        }
        boxes.push(frame);
    }

    fn area(&mut self, link: usize, rect: Rect) {
        self.pending.push(Pending::Area(link, rect));
    }

    fn watermark(&mut self, mark: Watermark) {
        self.pending.push(Pending::Watermark(mark));
    }

    fn build(
        mut self,
        links: &[Link],
        anchors: &HashMap<String, (usize, f64)>,
        page: (f64, f64),
    ) -> Vec<Annotation> {
        self.pending
            .into_iter()
            .map(|pending| match pending {
                Pending::Text(link) => {
                    let boxes = self.boxes.remove(&link).unwrap_or_default();
                    // Quadrilaterals run counterclockwise from the lower left.
                    let quads: Vec<f32> = boxes
                        .iter()
                        .flat_map(|&[l, b, r, t]| [l, b, r, b, r, t, l, t])
                        .map(|value| value as f32)
                        .collect();
                    Annotation::Link(
                        link_annotation(&links[link].target, enclosing(&quads), anchors)
                            .with_quad_points(quads),
                    )
                }
                Pending::Area(link, rect) => {
                    Annotation::Link(link_annotation(&links[link].target, rect, anchors))
                }
                Pending::Watermark(mark) => {
                    Annotation::Watermark(watermark_annotation(&mark, page))
                }
            })
            .collect()
    }
}

fn enclosing(points: &[f32]) -> Rect {
    let (mut left, mut bottom) = (f32::INFINITY, f32::INFINITY);
    let (mut right, mut top) = (f32::NEG_INFINITY, f32::NEG_INFINITY);
    for &[x, y] in points.as_chunks::<2>().0 {
        left = left.min(x);
        right = right.max(x);
        bottom = bottom.min(y);
        top = top.max(y);
    }
    Rect::new(left, bottom, span(left, right), span(bottom, top))
}

fn span(from: f32, to: f32) -> f32 {
    // Round outward: a quad outside the serialized rect makes readers ignore it.
    let mut size = to - from;
    while from + size < to {
        size = size.next_up();
    }
    size
}

// Targets were checked against the layout, so every page and anchor exists.
fn link_annotation(
    target: &LinkNif,
    rect: Rect,
    anchors: &HashMap<String, (usize, f64)>,
) -> LinkAnnotation {
    match target {
        LinkNif::Uri(uri) => LinkAnnotation::uri(rect, uri.as_str()),
        LinkNif::Page(page) => LinkAnnotation::goto_page(rect, *page),
        LinkNif::Anchor(name) => {
            let (page, y) = anchors[name];
            let mut link = LinkAnnotation::goto_page(rect, page);
            link.action = LinkAction::GoTo {
                page,
                fit: Some(FitMode::XYZ {
                    left: None,
                    top: Some(y as f32),
                    zoom: None,
                }),
            };
            link
        }
    }
}

fn watermark_annotation(mark: &Watermark, (width, height): (f64, f64)) -> WatermarkAnnotation {
    let face = base14::face(mark.font).expect("a watermark font is base-14");
    let center = mark.center.unwrap_or((width / 2.0, height / 2.0));
    let [x, y, w, h] = watermark_rect(face, &mark.text, mark.size, mark.rotation, center);
    let [r, g, b] = mark.color;

    WatermarkAnnotation::new(mark.text.as_str())
        .with_rect(Rect::new(x as f32, y as f32, w as f32, h as f32))
        .with_rotation(mark.rotation as f32)
        .with_opacity(mark.opacity as f32)
        .with_font(mark.font, mark.size as f32)
        .with_color(r, g, b)
}

// Compensate for the appearance's estimated text origin while keeping the
// rotated ink inside its box and both origin clamps inactive.
fn watermark_rect(
    face: &Base14,
    text: &str,
    size: f64,
    rotation: f64,
    (center_x, center_y): (f64, f64),
) -> [f64; 4] {
    // Measure the curly quotes that the watermark actually draws.
    let drawn = text.chars().map(|c| match c {
        '\'' => '\u{2019}',
        '`' => '\u{2018}',
        c => c,
    });
    let mut ink = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    let mut pen = 0.0;
    for c in drawn {
        if let Some([left, bottom, right, top]) = face.bounds(c) {
            ink = [
                ink[0].min(pen + left),
                ink[1].min(bottom),
                ink[2].max(pen + right),
                ink[3].max(top),
            ];
        }
        pen += f64::from(face.width(c).unwrap_or(0));
    }
    let [left, bottom, right, top] = ink.map(|value| value * size / 1000.0);

    let estimate = text.len() as f64 * size / 2.0;
    // Where the ink's center sits from the box's center before the turn.
    let dx = (left + right) / 2.0 - estimate / 2.0;
    let dy = (bottom + top) / 2.0 - size / 2.0;
    let (sin, cos) = rotation.to_radians().sin_cos();
    let (ox, oy) = (cos * dx - sin * dy, sin * dx + cos * dy);
    let (half_width, half_height) = ((right - left) / 2.0, (top - bottom) / 2.0);
    let reach_x = half_width * cos.abs() + half_height * sin.abs();
    let reach_y = half_width * sin.abs() + half_height * cos.abs();

    let w = 2.0 * (ox.abs() + reach_x).max(estimate / 2.0);
    let h = 2.0 * (oy.abs() + reach_y).max(size / 2.0);
    [center_x - w / 2.0 - ox, center_y - h / 2.0 - oy, w, h]
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
        let mut links = Vec::new();
        let mut fields = Vec::new();
        let ops = ops(op_nifs, &mut faces, &mut pictures, &mut links, &mut fields)?;
        keep_apart(pictures.decoded.iter_mut().flatten());
        let plan =
            flow::lay_out(&faces.fonts, &margins, line_height, page_size, &ops).map_err(refused)?;

        emit(
            meta,
            &faces.fonts,
            &faces.sources,
            &pictures.decoded,
            plan,
            &links,
            &fields,
        )
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use pdf_oxide::{
        editor::DocumentEditor,
        elements::{
            ContentElement, FontSpec, LineCap, LineJoin, PathContent, PathOperation,
            StructureElement, TextContent, TextStyle,
        },
        fonts::bundled::DEJAVU_SANS,
        geometry::Rect,
        object::Object,
        writer::{
            form_fields::TextFieldWidget, Annotation, DocumentBuilder, EmbeddedFont, FontManager,
            FreeTextAnnotation, LinkAnnotation, PageSize, StampAnnotation, StampType,
            StreamingColumn, StreamingTableConfig, Table, TableCell, TextAnnotation, TextLayout,
            TextMarkupAnnotation, WatermarkAnnotation,
        },
        PdfDocument, TextMarkupType,
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

    fn contains(pdf: &[u8], pattern: &[u8]) -> bool {
        pdf.windows(pattern.len()).any(|window| window == pattern)
    }

    fn annotated(pages: usize, annotation: impl Into<Annotation>) -> Vec<u8> {
        let mut builder = DocumentBuilder::new();
        builder
            .page(PageSize::Letter)
            .add_annotation(annotation)
            .done();
        for _ in 1..pages {
            builder.page(PageSize::Letter).done();
        }
        builder.build().expect("builds")
    }

    fn area() -> Rect {
        Rect::new(72.0, 700.0, 100.0, 12.0)
    }

    #[test]
    fn upstream_still_writes_no_appearance_for_markup_notes_stamps_or_freetext() {
        let mut builder = DocumentBuilder::new();
        builder
            .page(PageSize::Letter)
            .add_annotation(TextMarkupAnnotation::from_rect(
                TextMarkupType::Highlight,
                area(),
            ))
            .add_annotation(TextAnnotation::new(area(), "note"))
            .add_annotation(StampAnnotation::new(area(), StampType::Approved))
            .add_annotation(FreeTextAnnotation::new(area(), "free"))
            .done();
        let pdf = builder.build().expect("builds");

        assert!(contains(&pdf, b"/Highlight") && contains(&pdf, b"/FreeText"));
        assert!(!contains(&pdf, b"/AP"));
    }

    #[test]
    fn upstream_still_writes_no_named_destinations() {
        let pdf = annotated(1, LinkAnnotation::goto_named(area(), "there"));
        let doc = PdfDocument::from_bytes(pdf).expect("parses");
        let catalog = doc.catalog().expect("has a catalog");
        let catalog = catalog.as_dict().expect("is a dictionary");

        assert!(!catalog.contains_key("Names") && !catalog.contains_key("Dests"));
    }

    #[test]
    fn upstream_still_drops_the_destination_of_a_link_past_the_last_page() {
        let pdf = annotated(1, LinkAnnotation::goto_page(area(), 1));

        assert!(contains(&pdf, b"/Link"));
        assert!(!contains(&pdf, b"/Dest") && !contains(&pdf, b"/A "));
    }

    #[test]
    fn upstream_still_writes_a_non_ascii_uri_as_utf16() {
        let pdf = annotated(1, LinkAnnotation::uri(area(), "https://example.com/ж"));

        assert!(contains(&pdf, b"/URI <FEFF"));
    }

    #[test]
    fn upstream_still_points_every_watermark_at_the_first_page() {
        let mut builder = DocumentBuilder::new();
        builder.page(PageSize::Letter).done();
        builder
            .page(PageSize::Letter)
            .add_annotation(WatermarkAnnotation::new("DRAFT").with_rect(area()))
            .done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");
        let entry = |dict: &Object, key: &str| dict.as_dict().and_then(|d| d.get(key)).cloned();
        let page_ref = |index: usize| {
            let root = doc.catalog().expect("has a catalog");
            let pages = doc
                .resolve_object(&entry(&root, "Pages").expect("/Pages"))
                .expect("resolves");
            let kids = doc
                .resolve_object(&entry(&pages, "Kids").expect("/Kids"))
                .expect("resolves");
            kids.as_array().expect("an array")[index].clone()
        };
        let page = doc.resolve_object(&page_ref(1)).expect("resolves");
        let annots = doc
            .resolve_object(&entry(&page, "Annots").expect("/Annots"))
            .expect("resolves");
        let mark = doc
            .resolve_object(&annots.as_array().expect("an array")[0])
            .expect("resolves");

        assert_eq!(entry(&mark, "P"), Some(page_ref(0)));
    }

    fn acroform_fields(pdf: Vec<u8>) -> Vec<HashMap<String, Object>> {
        let doc = PdfDocument::from_bytes(pdf).expect("parses");
        let entry = |dict: &Object, key: &str| {
            let value = dict
                .as_dict()
                .and_then(|d| d.get(key))
                .expect("has the key");
            doc.resolve_object(value).expect("resolves")
        };
        let form = entry(&doc.catalog().expect("has a catalog"), "AcroForm");
        let fields = entry(&form, "Fields");

        fields
            .as_array()
            .expect("an array")
            .iter()
            .map(|field| {
                let field = doc.resolve_object(field).expect("resolves");
                field.as_dict().expect("a dictionary").clone()
            })
            .collect()
    }

    fn text_field_pdf() -> Vec<u8> {
        let mut builder = DocumentBuilder::new();
        builder
            .page(PageSize::Letter)
            .text_field("name", 72.0, 700.0, 100.0, 12.0, None)
            .done();
        builder.build().expect("builds")
    }

    // The builder and `Form` refuse field text these bytes would misread.
    #[test]
    fn upstream_still_writes_a_one_byte_text_string_byte_for_byte() {
        let bytes = |text: &str| match Object::text_string(text) {
            Object::String(bytes) => bytes,
            other => panic!("not a string: {other:?}"),
        };

        assert_eq!(bytes("a\u{A0}b"), [0x61, 0xA0, 0x62]);
        assert!(bytes("þÿa").starts_with(&[0xFE, 0xFF, 0x61]));
    }

    #[test]
    fn upstream_still_writes_radio_kids_without_a_parent() {
        let mut builder = DocumentBuilder::new();
        let buttons = vec![
            ("card".into(), 72.0, 700.0, 12.0, 12.0),
            ("cash".into(), 100.0, 700.0, 12.0, 12.0),
        ];
        builder
            .page(PageSize::Letter)
            .radio_group("pay", buttons, Some("cash".into()))
            .done();
        let fields = acroform_fields(builder.build().expect("builds"));

        assert!(fields.iter().any(|field| field.contains_key("AS")));
        assert!(fields
            .iter()
            .all(|field| !field.contains_key("Parent") && !field.contains_key("Kids")));
    }

    #[test]
    fn upstream_still_drops_the_widget_entries_of_an_added_field() {
        let mut editor =
            DocumentEditor::from_bytes(annotated(1, LinkAnnotation::uri(area(), "a:b")))
                .expect("parses");
        editor
            .add_form_field(0, TextFieldWidget::new("name", area()).with_tooltip("tip"))
            .expect("adds");
        let fields = acroform_fields(editor.save_to_bytes().expect("saves"));

        assert!(fields[0].contains_key("FT"));
        assert!(!fields[0].contains_key("F") && !fields[0].contains_key("TU"));
    }

    #[test]
    fn upstream_still_ignores_field_property_setters_on_save() {
        let mut editor = DocumentEditor::from_bytes(text_field_pdf()).expect("parses");
        editor.set_form_field_max_length("name", 4).expect("sets");
        editor.set_form_field_alignment("name", 1).expect("sets");
        editor.set_form_field_flags("name", 4096).expect("sets");
        let fields = acroform_fields(editor.save_to_bytes().expect("saves"));

        assert!(fields[0].contains_key("FT"));
        assert!(["MaxLen", "Q", "Ff"]
            .iter()
            .all(|key| !fields[0].contains_key(*key)));
    }

    #[test]
    fn upstream_still_writes_watermark_text_as_raw_bytes() {
        let pdf = annotated(1, WatermarkAnnotation::new("é").with_rect(area()));

        assert!(contains(&pdf, "(é) Tj".as_bytes()));
    }

    #[test]
    fn a_link_rect_reaches_every_point_once_upstream_adds_it() {
        let mut short = 0;
        for step in 0..2000 {
            let near = 1.0 + f64::from(step) * 0.0731;
            for gap in [0.1, 9.31, 92.917, 100.3, 412.06] {
                let (from, to) = (near as f32, (near + gap) as f32);
                short += usize::from(from + (to - from) < to);
                assert!(from + super::span(from, to) >= to, "{from} to {to}");
            }
        }
        assert!(short > 0, "the grid never needs rounding up");

        let rect = super::enclosing(&[72.3, 200.1, 164.917, 200.1, 164.917, 211.2, 72.3, 211.2]);
        assert_eq!((rect.x, rect.y), (72.3, 200.1));
        assert!(rect.x + rect.width >= 164.917 && rect.y + rect.height >= 211.2);
    }

    #[test]
    fn a_watermark_box_reaches_no_farther_than_the_bound_watermark_3_checks() {
        let faces = [
            "Helvetica",
            "Helvetica-Bold",
            "Times-Roman",
            "Times-Bold",
            "Courier",
            "Courier-Bold",
        ];
        for name in faces {
            let face = crate::base14::face(name).expect("base-14");
            // A text of spaces alone is refused.
            for c in (0x21u8..=0x7E).map(char::from) {
                for text in [c.to_string(), c.to_string().repeat(7), format!(" {c}  ")] {
                    for rotation in [0.0, 30.0, 45.0, 90.0, 135.0, 200.0, -45.0] {
                        let [x, y, w, h] =
                            super::watermark_rect(face, &text, 1.0, rotation, (0.0, 0.0));
                        let reach = (text.len() as f64 + 2.0) * 2.0;
                        assert!(
                            [x, y, x + w, y + h].iter().all(|v| v.abs() <= reach),
                            "{name} {text:?} at {rotation}°"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn a_watermark_box_holds_its_turned_ink_centered_on_the_point() {
        let face = crate::base14::face("Helvetica-Bold").expect("base-14");
        for (text, size, rotation) in [
            ("CONFIDENTIAL", 72.0, 45.0),
            ("DRAFT", 120.0, -30.0),
            ("i", 72.0, 90.0),
            ("WWWWWWWWWW", 20.0, 200.0),
        ] {
            let [x, y, w, h] = super::watermark_rect(face, text, size, rotation, (300.0, 400.0));
            let origin = (
                ((w - text.len() as f64 * size / 2.0) / 2.0),
                ((h - size) / 2.0),
            );
            assert!(origin.0 >= 0.0 && origin.1 >= 0.0, "{text}: a clamp acts");

            let mut pen = 0.0;
            let mut ink = [
                f64::INFINITY,
                f64::INFINITY,
                f64::NEG_INFINITY,
                f64::NEG_INFINITY,
            ];
            for c in text.chars() {
                let [l, b, r, t] = face.bounds(c).expect("draws");
                ink = [
                    ink[0].min(pen + l),
                    ink[1].min(b),
                    ink[2].max(pen + r),
                    ink[3].max(t),
                ];
                pen += f64::from(face.width(c).expect("has a width"));
            }
            let [l, b, r, t] = ink.map(|value| value * size / 1000.0);
            let corners =
                [(l, b), (r, b), (r, t), (l, t)].map(|(cx, cy)| (origin.0 + cx, origin.1 + cy));
            let (sin, cos) = f64::to_radians(rotation).sin_cos();
            let turned: Vec<(f64, f64)> = corners
                .iter()
                .map(|&(px, py)| {
                    let (dx, dy) = (px - w / 2.0, py - h / 2.0);
                    (w / 2.0 + cos * dx - sin * dy, h / 2.0 + sin * dx + cos * dy)
                })
                .collect();
            let min_x = turned.iter().map(|p| p.0).fold(f64::INFINITY, f64::min);
            let max_x = turned.iter().map(|p| p.0).fold(f64::NEG_INFINITY, f64::max);
            let min_y = turned.iter().map(|p| p.1).fold(f64::INFINITY, f64::min);
            let max_y = turned.iter().map(|p| p.1).fold(f64::NEG_INFINITY, f64::max);

            assert!(
                min_x >= -1e-9 && max_x <= w + 1e-9,
                "{text}: ink leaves the box"
            );
            assert!(
                min_y >= -1e-9 && max_y <= h + 1e-9,
                "{text}: ink leaves the box"
            );
            assert!(
                (x + (min_x + max_x) / 2.0 - 300.0).abs() < 1e-9,
                "{text}: off center"
            );
            assert!(
                (y + (min_y + max_y) / 2.0 - 400.0).abs() < 1e-9,
                "{text}: off center"
            );
        }
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
