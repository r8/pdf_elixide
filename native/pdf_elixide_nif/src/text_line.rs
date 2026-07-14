use pdf_oxide::layout::TextLine;
use rustler::NifMap;

use crate::word::{rect_to_nif, word_to_nif, RectNif, WordNif};

#[derive(NifMap, Debug)]
pub struct TextLineNif {
    text: String,
    page: usize,
    bbox: RectNif,
    words: Vec<WordNif>,
}

pub fn text_line_to_nif(line: TextLine, page: usize) -> TextLineNif {
    TextLineNif {
        text: line.text,
        page,
        bbox: rect_to_nif(line.bbox),
        words: line
            .words
            .into_iter()
            .map(|word| word_to_nif(word, page))
            .collect(),
    }
}
