use pdf_oxide::{
    elements::{ContentElement, FontSpec, TextContent, TextStyle},
    geometry::Rect,
    writer::{DocumentBuilder, PageSize},
};
use rustler::{NifMap, NifResult, NifTaggedEnum};

use crate::{
    atoms,
    base14::{self, Base14},
    create::create_from_bytes,
    editor::OpenedEditor,
    error::{tagged_err, to_nif_err},
    flow::{self, Face, Fonts, Margins, Op, PagePlan, Refused, Run},
};

#[derive(NifMap)]
pub struct BuildNif {
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
    ops: Vec<OpNif>,
}

#[derive(NifTaggedEnum)]
pub enum OpNif {
    Page((f64, f64)),
    Paragraph(ParagraphNif),
}

#[derive(NifMap)]
pub struct ParagraphNif {
    text: String,
    font_size: f64,
}

const HELVETICA: usize = 0;

fn ops(ops: Vec<OpNif>) -> Vec<Op> {
    ops.into_iter()
        .map(|op| match op {
            OpNif::Page((width, height)) => Op::Page { width, height },
            OpNif::Paragraph(paragraph) => Op::Paragraph {
                runs: vec![Run {
                    text: paragraph.text,
                    face: HELVETICA,
                }],
                face: HELVETICA,
                size: paragraph.font_size,
            },
        })
        .collect()
}

// The base-14 writer replaces a character outside Windows-1252 with `?`.
// Whitespace is laid out as spaces, so only the other characters are drawn.
fn first_unrenderable(ops: &[Op], font: &Base14) -> Option<(usize, char)> {
    ops.iter().enumerate().find_map(|(index, op)| match op {
        Op::Paragraph { runs, .. } => runs
            .iter()
            .flat_map(|run| run.text.chars())
            .find(|&c| !c.is_whitespace() && font.width(c).is_none())
            .map(|c| (index, c)),
        Op::Page { .. } => None,
    })
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
    };

    tagged_err(atoms::unsupported(), message)
}

fn emit(meta: Meta, fonts: &Fonts, plan: Vec<PagePlan>) -> pdf_oxide::Result<Vec<u8>> {
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

    for page in plan {
        let mut builder = doc.page(PageSize::Custom(page.width as f32, page.height as f32));
        for placed in page.placed {
            let text = TextContent::new(
                placed.text,
                Rect::new(
                    placed.x as f32,
                    placed.baseline as f32,
                    placed.width as f32,
                    placed.size as f32,
                ),
                FontSpec {
                    name: fonts.name(placed.face).to_string(),
                    size: placed.size as f32,
                },
                TextStyle::default(),
            );
            builder = builder.element(ContentElement::Text(text));
        }
        builder.done();
    }

    doc.build()
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
fn editor_from_builder(build: BuildNif) -> NifResult<OpenedEditor> {
    let ops = ops(build.ops);
    let helvetica = base14::face("Helvetica").expect("Helvetica is a base-14 face");

    if let Some((op, c)) = first_unrenderable(&ops, helvetica) {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "op {op}: Helvetica cannot draw {c:?} (U+{:04X}); only Windows-1252 \
                 characters can be set in a built-in font",
                u32::from(c)
            ),
        ));
    }

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

    create_from_bytes(move || {
        let fonts = Fonts::new(vec![Face::Base14(helvetica)]);
        let plan =
            flow::lay_out(&fonts, &margins, line_height, page_size, &ops).map_err(refused)?;

        emit(meta, &fonts, plan).map_err(to_nif_err)
    })
}
