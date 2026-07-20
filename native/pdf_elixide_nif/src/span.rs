use pdf_oxide::layout::TextSpan;
use rustler::NifMap;

use crate::{
    color::{color_to_nif, ColorNif},
    geometry::{rect_to_nif, RectNif},
};

#[derive(NifMap, Debug)]
pub struct SpanNif {
    text: String,
    page: usize,
    bbox: RectNif,
    font_size: f32,
    font: String,
    font_weight: u16,
    bold: bool,
    italic: bool,
    monospace: bool,
    color: ColorNif,
    rotation: f32,
    char_spacing: f32,
    word_spacing: f32,
    horizontal_scaling: f32,
    text_rise: f32,
    heading_level: Option<u8>,
    mcid: Option<u32>,
}

pub fn span_to_nif(span: TextSpan, page: usize) -> SpanNif {
    SpanNif {
        text: span.text,
        page,
        bbox: rect_to_nif(span.bbox),
        font_size: span.font_size,
        font: span.font_name,
        font_weight: span.font_weight as u16,
        bold: span.font_weight.is_bold(),
        italic: span.is_italic,
        monospace: span.is_monospace,
        color: color_to_nif(span.color),
        rotation: span.rotation_degrees,
        char_spacing: span.char_spacing,
        word_spacing: span.word_spacing,
        horizontal_scaling: span.horizontal_scaling,
        text_rise: span.text_rise,
        heading_level: span.heading_level,
        mcid: span.mcid,
    }
}
