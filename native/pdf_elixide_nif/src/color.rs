use pdf_oxide::layout::Color;
use rustler::NifStruct;

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color"]
pub struct ColorNif {
    r: f32,
    g: f32,
    b: f32,
}

pub fn color_to_nif(color: Color) -> ColorNif {
    ColorNif {
        r: color.r,
        g: color.g,
        b: color.b,
    }
}
