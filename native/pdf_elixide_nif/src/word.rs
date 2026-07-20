use pdf_oxide::layout::Word;
use rustler::NifMap;

use crate::geometry::{rect_to_nif, RectNif};

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
