use pdf_oxide::layout::TextSpan;
use rustler::NifMap;

use crate::{
    color::{color_to_nif, RgbNif},
    geometry::{finite, rect_to_nif, RectNif},
};

#[derive(NifMap, Debug)]
pub struct SpanNif {
    text: String,
    page: usize,
    bbox: RectNif,
    page_bbox: RectNif,
    font_size: f32,
    font: String,
    font_weight: u16,
    bold: bool,
    italic: bool,
    monospace: bool,
    color: RgbNif,
    rotation: f32,
    char_spacing: f32,
    word_spacing: f32,
    horizontal_scaling: f32,
    text_rise: f32,
    heading_level: Option<u8>,
    mcid: Option<u32>,
}

// Decodes a span the caller owns, moving its two heap strings out rather than
// copying them.
pub fn span_to_nif(mut span: TextSpan, page: usize) -> SpanNif {
    let text = std::mem::take(&mut span.text);
    let font = std::mem::take(&mut span.font_name);

    span_parts_to_nif(text, font, &span, page)
}

// The table path borrows spans; copy only the two strings, not the per-glyph
// vectors retained by the table resource.
pub fn span_ref_to_nif(span: &TextSpan, page: usize) -> SpanNif {
    span_parts_to_nif(span.text.clone(), span.font_name.clone(), span, page)
}

// The one field literal both spellings above share, so a new `SpanNif` field
// cannot be added to one and forgotten in the other.
fn span_parts_to_nif(text: String, font: String, span: &TextSpan, page: usize) -> SpanNif {
    SpanNif {
        text,
        page,
        bbox: rect_to_nif(span.bbox),
        page_bbox: rect_to_nif(span.page_bbox()),
        font_size: finite(span.font_size),
        font,
        font_weight: span.font_weight as u16,
        bold: span.font_weight.is_bold(),
        italic: span.is_italic,
        monospace: span.is_monospace,
        color: color_to_nif(span.color),
        rotation: finite(span.rotation_degrees),
        char_spacing: finite(span.char_spacing),
        word_spacing: finite(span.word_spacing),
        horizontal_scaling: finite(span.horizontal_scaling),
        text_rise: finite(span.text_rise),
        heading_level: span.heading_level,
        mcid: span.mcid,
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{geometry::Rect, layout::Color};

    use super::*;

    #[test]
    fn every_span_float_crosses_finite() {
        let span = TextSpan {
            bbox: Rect {
                x: f32::INFINITY,
                y: f32::NEG_INFINITY,
                width: f32::NAN,
                height: f32::INFINITY,
            },
            font_size: f32::INFINITY,
            color: Color {
                r: f32::NAN,
                g: f32::INFINITY,
                b: f32::NEG_INFINITY,
            },
            rotation_degrees: f32::NAN,
            char_spacing: f32::INFINITY,
            word_spacing: f32::NEG_INFINITY,
            horizontal_scaling: f32::INFINITY,
            text_rise: f32::NEG_INFINITY,
            ..TextSpan::default()
        };

        let nif = span_to_nif(span, 0);

        assert_eq!(
            nif.bbox,
            RectNif {
                x: f32::MAX,
                y: -f32::MAX,
                width: 0.0,
                height: f32::MAX,
            }
        );
        assert_eq!(
            nif.page_bbox,
            RectNif {
                x: 0.0,
                y: 0.0,
                width: f32::MAX,
                height: f32::MAX,
            }
        );
        assert_eq!(nif.font_size, f32::MAX);
        assert_eq!(
            (nif.color.r, nif.color.g, nif.color.b),
            (0.0, f32::MAX, -f32::MAX)
        );
        assert_eq!(nif.rotation, 0.0);
        assert_eq!(nif.char_spacing, f32::MAX);
        assert_eq!(nif.word_spacing, -f32::MAX);
        assert_eq!(nif.horizontal_scaling, f32::MAX);
        assert_eq!(nif.text_rise, -f32::MAX);
    }
}
