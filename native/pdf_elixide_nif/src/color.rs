use pdf_oxide::layout::Color;
use rustler::{NifStruct, NifUntaggedEnum};

use crate::geometry::{finite, finite64};

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.RGB"]
pub struct RgbNif {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.CMYK"]
pub struct CmykNif {
    c: f64,
    m: f64,
    y: f64,
    k: f64,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.Gray"]
pub struct GrayNif {
    gray: f64,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.Unknown"]
pub struct UnknownNif {
    components: Vec<f64>,
}

// An annotation color (`/C` or `/IC`). Untagged so each variant encodes as the
// bare struct — Elixir sees `%PdfElixide.Color.RGB{}` and friends directly,
// with no wrapping tuple.
#[derive(NifUntaggedEnum, Debug)]
pub enum AnnotationColorNif {
    Gray(GrayNif),
    Rgb(RgbNif),
    Cmyk(CmykNif),
    Unknown(UnknownNif),
}

pub fn color_to_nif(color: Color) -> RgbNif {
    RgbNif {
        r: finite(color.r),
        g: finite(color.g),
        b: finite(color.b),
    }
}

// Decodes a raw `/C` or `/IC` component array by its length. The colorspace is
// inferred from the component count — the array itself carries no colorspace —
// so anything but 1, 3, or 4 components is kept as `Unknown` rather than
// guessed at.
pub fn annotation_color_to_nif(components: Option<Vec<f64>>) -> Option<AnnotationColorNif> {
    components.map(|c| match c.len() {
        1 => AnnotationColorNif::Gray(GrayNif {
            gray: finite64(c[0]),
        }),
        3 => AnnotationColorNif::Rgb(RgbNif {
            r: finite(c[0] as f32),
            g: finite(c[1] as f32),
            b: finite(c[2] as f32),
        }),
        4 => AnnotationColorNif::Cmyk(CmykNif {
            c: finite64(c[0]),
            m: finite64(c[1]),
            y: finite64(c[2]),
            k: finite64(c[3]),
        }),
        _ => AnnotationColorNif::Unknown(UnknownNif {
            components: c.into_iter().map(finite64).collect(),
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_color_components_cross_finite() {
        let rgb = color_to_nif(Color {
            r: f32::INFINITY,
            g: f32::NEG_INFINITY,
            b: f32::NAN,
        });
        assert_eq!((rgb.r, rgb.g, rgb.b), (f32::MAX, -f32::MAX, 0.0));
    }

    #[test]
    fn annotation_color_components_cross_finite_at_every_length() {
        let bound = f64::from(f32::MAX);
        match annotation_color_to_nif(Some(vec![f64::INFINITY])) {
            Some(AnnotationColorNif::Gray(GrayNif { gray })) => assert_eq!(gray, bound),
            other => panic!("{other:?}"),
        }
        match annotation_color_to_nif(Some(vec![f64::INFINITY, f64::NEG_INFINITY, f64::NAN])) {
            Some(AnnotationColorNif::Rgb(RgbNif { r, g, b })) => {
                assert_eq!((r, g, b), (f32::MAX, -f32::MAX, 0.0))
            }
            other => panic!("{other:?}"),
        }
        match annotation_color_to_nif(Some(vec![
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NAN,
            1e300,
        ])) {
            Some(AnnotationColorNif::Cmyk(CmykNif { c, m, y, k })) => {
                assert_eq!((c, m, y, k), (bound, -bound, 0.0, bound))
            }
            other => panic!("{other:?}"),
        }
        match annotation_color_to_nif(Some(vec![
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NAN,
            0.5,
            1e300,
        ])) {
            Some(AnnotationColorNif::Unknown(UnknownNif { components })) => {
                assert_eq!(components, vec![bound, -bound, 0.0, 0.5, bound])
            }
            other => panic!("{other:?}"),
        }
    }
}
