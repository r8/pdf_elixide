use pdf_oxide::layout::TextChar;
use rustler::NifMap;

use crate::{
    color::{color_to_nif, RgbNif},
    geometry::{rect_to_nif, RectNif},
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
        font_size: ch.font_size,
        font: ch.font_name,
        font_weight: ch.font_weight as u16,
        bold: ch.font_weight.is_bold(),
        italic: ch.is_italic,
        monospace: ch.is_monospace,
        color: color_to_nif(ch.color),
        origin: (ch.origin_x, ch.origin_y),
        rotation: ch.rotation_degrees,
        advance_width: ch.advance_width,
        rendered_advance: ch.rendered_advance,
        ascent: ch.ascent,
        descent: ch.descent,
        mcid: ch.mcid,
    }
}
