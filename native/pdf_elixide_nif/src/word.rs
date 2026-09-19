use pdf_oxide::layout::Word;
use rustler::NifMap;

use crate::geometry::{finite, rect_to_nif, RectNif};

#[derive(NifMap, Debug)]
pub struct WordNif {
    text: String,
    page: usize,
    bbox: RectNif,
    font_size: f32,
    font: String,
    bold: bool,
    italic: bool,
    rotation: f32,
}

pub fn word_to_nif(word: Word, page: usize) -> WordNif {
    WordNif {
        text: word.text,
        page,
        bbox: rect_to_nif(word.bbox),
        font_size: finite(word.avg_font_size),
        font: word.dominant_font,
        bold: word.is_bold,
        italic: word.is_italic,
        rotation: finite(word.rotation_degrees),
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::geometry::Rect;

    use super::*;

    #[test]
    fn every_word_float_crosses_finite() {
        let word = Word {
            chars: vec![],
            bbox: Rect {
                x: f32::INFINITY,
                y: f32::NEG_INFINITY,
                width: f32::NAN,
                height: f32::INFINITY,
            },
            text: String::new(),
            avg_font_size: f32::INFINITY,
            dominant_font: String::new(),
            is_bold: false,
            is_italic: false,
            mcid: None,
            sequence: 0,
            rotation_degrees: f32::NEG_INFINITY,
        };

        let nif = word_to_nif(word, 0);

        assert_eq!(
            nif.bbox,
            RectNif {
                x: f32::MAX,
                y: -f32::MAX,
                width: 0.0,
                height: f32::MAX,
            }
        );
        assert_eq!(nif.font_size, f32::MAX);
        assert_eq!(nif.rotation, -f32::MAX);
    }
}
