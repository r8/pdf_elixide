use pdf_oxide::geometry::Rect;
use rustler::NifStruct;

#[derive(NifStruct, Debug, Clone, Copy, PartialEq)]
#[module = "PdfElixide.Geometry.Rect"]
pub struct RectNif {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

// Use the constructor so hand-written rectangles normalize before reaching
// geometry helpers that assume non-negative dimensions.
pub fn rect_from_nif(rect: RectNif) -> Rect {
    Rect::new(rect.x, rect.y, rect.width, rect.height)
}

// `enif_make_double` raises `badarg` on a non-finite value. `finite64` bounds
// at the `f32` maximum too, so the one value the Rect doc promises is exact.
pub fn finite(v: f32) -> f32 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(-f32::MAX, f32::MAX)
    }
}

pub fn finite64(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(-f64::from(f32::MAX), f64::from(f32::MAX))
    }
}

pub fn rect_to_nif(rect: Rect) -> RectNif {
    RectNif {
        x: finite(rect.x),
        y: finite(rect.y),
        width: finite(rect.width),
        height: finite(rect.height),
    }
}

// Builds a `RectNif` from two opposite corners — an annotation's `/Rect`
// `[x1, y1, x2, y2]` or a page's `/MediaBox` — normalizing so the corners may
// be given in any order.
pub fn rect_from_corners(x1: f64, y1: f64, x2: f64, y2: f64) -> RectNif {
    // Bound the corners before subtracting: `inf - (-inf)` is NaN.
    let [x1, y1, x2, y2] = [x1, y1, x2, y2].map(finite64);
    RectNif {
        x: finite(x1.min(x2) as f32),
        y: finite(y1.min(y2) as f32),
        width: finite((x2 - x1).abs() as f32),
        height: finite((y2 - y1).abs() as f32),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finite_maps_only_the_values_a_double_term_cannot_hold() {
        for (input, expected) in [
            (f32::INFINITY, f32::MAX),
            (f32::NEG_INFINITY, -f32::MAX),
            (f32::NAN, 0.0),
        ] {
            assert_eq!(finite(input), expected, "{input}");
        }
        for value in [0.0, -1.5, 3.4e38, f32::MAX, -f32::MAX, f32::MIN_POSITIVE] {
            assert_eq!(finite(value), value, "{value}");
        }
        let bound = f64::from(f32::MAX);
        for (input, expected) in [
            (f64::INFINITY, bound),
            (f64::NEG_INFINITY, -bound),
            (f64::NAN, 0.0),
            (1e300, bound),
            (-1e300, -bound),
        ] {
            assert_eq!(finite64(input), expected, "{input}");
        }
        for value in [-2.5, bound, -bound, 3.4e38] {
            assert_eq!(finite64(value), value, "{value}");
        }
    }

    #[test]
    fn corners_without_bounds_still_yield_a_finite_rect() {
        assert_eq!(
            rect_from_corners(f64::NEG_INFINITY, 0.0, f64::INFINITY, 1.0),
            RectNif {
                x: -f32::MAX,
                y: 0.0,
                width: f32::MAX,
                height: 1.0
            }
        );
        assert_eq!(
            rect_from_corners(f64::NAN, f64::NAN, 1.0, 1.0),
            RectNif {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0
            }
        );
    }
}
