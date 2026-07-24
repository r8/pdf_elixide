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

/// Builds a `RectNif` from two opposite corners (e.g. a PDF `/Rect`
/// `[x1, y1, x2, y2]`), normalizing so the corners may be given in any order.
pub fn rect_from_corners(x1: f64, y1: f64, x2: f64, y2: f64) -> RectNif {
    RectNif {
        x: x1.min(x2) as f32,
        y: y1.min(y2) as f32,
        width: (x2 - x1).abs() as f32,
        height: (y2 - y1).abs() as f32,
    }
}
