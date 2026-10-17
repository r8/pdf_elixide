use std::collections::{HashMap, HashSet};

use pdf_oxide::{
    elements::{ContentElement, FontSpec, TextContent, TextStyle},
    fonts::bundled::{DEJAVU_SANS, DEJAVU_SANS_BOLD},
    geometry::Rect,
    layout::Color,
    writer::{DocumentBuilder, EmbeddedFont, LineStyle, PageSize},
};
use rustler::{Binary, NifMap, NifResult, NifTaggedEnum, NifUnitEnum};

use crate::{
    atoms, base14,
    color::RgbNif,
    create::create_from_bytes,
    editor::OpenedEditor,
    error::{tagged_err, to_nif_err},
    flow::{
        self, embedded_key, Embedded, Face, Fonts, Margins, Marker, Op, PagePlan, Refused, Run,
        Unordered,
    },
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
    fonts: Fonts,
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
        let coverage = coverage(bytes);
        let face = self
            .fonts
            .add(Face::Embedded(Box::new(Embedded { font, coverage })));
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
    EmbeddedFont::from_data(Some(name), bytes.to_vec())
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

fn coverage(bytes: &[u8]) -> HashSet<char> {
    let mut covered = HashSet::new();
    if let Some(cmap) = ttf_parser::Face::parse(bytes, 0)
        .ok()
        .and_then(|face| face.tables().cmap)
    {
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
            OpNif::List(ListNif {
                font: FontNif::Auto,
                items,
                ..
            }) => Some(items.iter().collect()),
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
        .map(|run| {
            // DejaVu Sans has no italic, so `:auto` sets it upright.
            let italic = run.italic && !(from_auto && family == Family::DejaVu);
            Ok(Run {
                face: faces.face(op, family, Style::of(run.bold, italic))?,
                color: run.color.map(|c| [c.r, c.g, c.b]),
                text: run.text,
            })
        })
        .collect()
}

fn ops(ops: Vec<OpNif>, faces: &mut Faces<'_, '_>) -> NifResult<Vec<Op>> {
    let auto = auto_family(&ops);

    ops.into_iter()
        .enumerate()
        .map(|(index, op)| match op {
            OpNif::Page((width, height)) => Ok(Op::Page { width, height }),
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
        })
        .collect()
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
        } => format!(
            "op {op} starting on page {page}: {cluster:?} is {width} points wide, wider than \
             the {room}-point line; reduce the font size or the left and right margins"
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
        Refused::CounterOverflow { op, page } => {
            format!("op {op} on page {page}: the list's numbering overflows; use a smaller :start")
        }
    };

    unsupported(message)
}

const RULE_WIDTH: f32 = 0.5;
const RULE_GRAY: f32 = 0.5;

fn emit(
    meta: Meta,
    fonts: &Fonts,
    sources: &[(usize, &[u8])],
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
        for placed in page.placed {
            let mut style = TextStyle::default();
            if let Some([r, g, b]) = placed.color {
                style.color = Color { r, g, b };
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
            builder = builder.element(ContentElement::Text(text));
        }
        for rule in page.rules {
            let y = rule.y as f32;
            builder = builder.stroke_line(
                rule.from as f32,
                y,
                rule.to as f32,
                y,
                LineStyle::new(RULE_WIDTH, RULE_GRAY, RULE_GRAY, RULE_GRAY),
            );
        }
        builder.done();
    }

    doc.build().map_err(to_nif_err)
}

struct Meta {
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
    creator: Option<String>,
}

// Dirty because laying out a whole document and parsing the result is
// CPU-bound; the only lock taken is the new handle's, which nothing else holds.
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
    let op_nifs = build.ops;

    // Fonts are parsed inside, so a panic in the font parser is contained too.
    create_from_bytes(move || {
        let mut faces = Faces {
            families,
            fonts: Fonts::new(),
            sources: Vec::new(),
            index: HashMap::new(),
        };
        let ops = ops(op_nifs, &mut faces)?;
        let plan =
            flow::lay_out(&faces.fonts, &margins, line_height, page_size, &ops).map_err(refused)?;

        emit(meta, &faces.fonts, &faces.sources, plan)
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{
        fonts::bundled::DEJAVU_SANS,
        writer::{DocumentBuilder, EmbeddedFont, FontManager, PageSize, TextLayout},
        PdfDocument,
    };

    use crate::metadata::read_metadata;

    fn fixture(name: &str) -> Vec<u8> {
        let path = format!("{}/../../test/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
        std::fs::read(path).expect("fixture exists")
    }

    #[test]
    fn upstream_still_ignores_keywords_in_the_document_builder() {
        let mut builder = DocumentBuilder::new().keywords("kw");
        builder.page(PageSize::Letter).text("Hello").done();
        let doc = PdfDocument::from_bytes(builder.build().expect("builds")).expect("parses");

        assert_eq!(read_metadata(&doc).keywords, None);
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
        let font = EmbeddedFont::from_data(None, fixture("font_truetype.ttf")).expect("parses");

        assert!(!super::coverage(&fixture("font_truetype.ttf")).contains(&'•'));
        assert_eq!(font.glyph_id(u32::from('•')), font.glyph_id(u32::from('*')));
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
