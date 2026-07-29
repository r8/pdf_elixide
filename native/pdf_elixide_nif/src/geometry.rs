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

/// Decodes a caller-supplied `%PdfElixide.Geometry.Rect{}` — an extracted
/// `bbox` handed straight back as a `:region` option, in the common case.
///
/// Built through `Rect::new` rather than as a struct literal so a hand-written
/// rect with reversed corners normalizes the way it does for every other
/// `pdf_oxide` caller. `Rect`'s fields are public and the geometry helpers
/// assume non-negative dimensions, so a negative width would otherwise reach
/// `intersects` unnormalized and silently match nothing.
pub fn rect_from_nif(rect: RectNif) -> Rect {
    Rect::new(rect.x, rect.y, rect.width, rect.height)
}

pub fn rect_to_nif(rect: Rect) -> RectNif {
    RectNif {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    }
}

/// Builds a `RectNif` from two opposite corners — an annotation's `/Rect`
/// `[x1, y1, x2, y2]` or a page's `/MediaBox` — normalizing so the corners may
/// be given in any order.
pub fn rect_from_corners(x1: f64, y1: f64, x2: f64, y2: f64) -> RectNif {
    RectNif {
        x: x1.min(x2) as f32,
        y: y1.min(y2) as f32,
        width: (x2 - x1).abs() as f32,
        height: (y2 - y1).abs() as f32,
    }
}
