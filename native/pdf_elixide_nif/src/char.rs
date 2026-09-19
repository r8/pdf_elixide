use pdf_oxide::layout::TextChar;
use rustler::NifMap;

use crate::{
    color::{color_to_nif, RgbNif},
    geometry::{finite, rect_to_nif, RectNif},
};

#[derive(NifMap, Debug)]
pub struct CharNif {
    text: String,
    page: usize,
    bbox: RectNif,
    font_size: f32,
    font: String,
    font_weight: u16,
    bold: bool,
    italic: bool,
    monospace: bool,
    color: RgbNif,
    origin: (f32, f32),
    rotation: f32,
    advance_width: f32,
    rendered_advance: f32,
    ascent: f32,
    descent: f32,
    mcid: Option<u32>,
}

pub fn char_to_nif(ch: TextChar, page: usize) -> CharNif {
    CharNif {
        text: ch.char.to_string(),
        page,
        bbox: rect_to_nif(ch.bbox),
        font_size: finite(ch.font_size),
        font: ch.font_name,
        font_weight: ch.font_weight as u16,
        bold: ch.font_weight.is_bold(),
        italic: ch.is_italic,
        monospace: ch.is_monospace,
        color: color_to_nif(ch.color),
        origin: (finite(ch.origin_x), finite(ch.origin_y)),
        rotation: finite(ch.rotation_degrees),
        advance_width: finite(ch.advance_width),
        rendered_advance: finite(ch.rendered_advance),
        ascent: finite(ch.ascent),
        descent: finite(ch.descent),
        mcid: ch.mcid,
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{geometry::Rect, layout::Color};

    use super::*;

    #[test]
    fn every_char_float_crosses_finite() {
        let ch = TextChar {
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
            origin_x: f32::INFINITY,
            origin_y: f32::NEG_INFINITY,
            rotation_degrees: f32::NAN,
            advance_width: f32::INFINITY,
            rendered_advance: f32::NEG_INFINITY,
            ascent: f32::INFINITY,
            descent: f32::NEG_INFINITY,
            ..TextChar::default()
        };

        let nif = char_to_nif(ch, 0);

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
        assert_eq!(
            (nif.color.r, nif.color.g, nif.color.b),
            (0.0, f32::MAX, -f32::MAX)
        );
        assert_eq!(nif.origin, (f32::MAX, -f32::MAX));
        assert_eq!(nif.rotation, 0.0);
        assert_eq!(nif.advance_width, f32::MAX);
        assert_eq!(nif.rendered_advance, -f32::MAX);
        assert_eq!(nif.ascent, f32::MAX);
        assert_eq!(nif.descent, -f32::MAX);
    }
}
