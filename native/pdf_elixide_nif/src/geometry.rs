use pdf_oxide::geometry::Rect;
use rustler::NifStruct;

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Geometry.Rect"]
pub struct RectNif {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
}

pub fn rect_to_nif(rect: Rect) -> RectNif {
    RectNif {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    }
}
