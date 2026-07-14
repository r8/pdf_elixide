use pdf_oxide::{geometry::Rect, layout::Word};
use rustler::{NifMap, NifStruct};

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Geometry.Rect"]
pub struct RectNif {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

#[derive(NifMap, Debug)]
pub struct WordNif {
    text: String,
    page: usize,
    bbox: RectNif,
    font_size: f32,
    font: String,
    bold: bool,
    italic: bool,
}

pub fn word_to_nif(word: Word, page: usize) -> WordNif {
    WordNif {
        text: word.text,
        page,
        bbox: rect_to_nif(word.bbox),
        font_size: word.avg_font_size,
        font: word.dominant_font,
        bold: word.is_bold,
        italic: word.is_italic,
    }
}

fn rect_to_nif(rect: Rect) -> RectNif {
    RectNif {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    }
}
