use pdf_oxide::layout::Color;
use rustler::{NifStruct, NifUntaggedEnum};

// A DeviceRGB color. The only shape text and path colors can take: `pdf_oxide`
// resolves every colorspace to DeviceRGB during extraction.
#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.RGB"]
pub struct RgbNif {
    r: f32,
    g: f32,
    b: f32,
}

// A DeviceCMYK color, from a four-component annotation color array.
#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.CMYK"]
pub struct CmykNif {
    c: f64,
    m: f64,
    y: f64,
    k: f64,
}

// A DeviceGray color, from a single-component annotation color array.
#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Color.Gray"]
pub struct GrayNif {
    gray: f64,
}

// Components whose colorspace we can't identify, preserved verbatim.
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
        r: color.r,
        g: color.g,
        b: color.b,
    }
}

// Decodes a raw `/C` or `/IC` component array by its length. The colorspace is
// inferred from the component count — the array itself carries no colorspace —
// so anything but 1, 3, or 4 components is kept as `Unknown` rather than
// guessed at.
pub fn annotation_color_to_nif(components: Option<Vec<f64>>) -> Option<AnnotationColorNif> {
    components.map(|c| match c.len() {
        1 => AnnotationColorNif::Gray(GrayNif { gray: c[0] }),
        3 => AnnotationColorNif::Rgb(RgbNif {
            r: c[0] as f32,
            g: c[1] as f32,
            b: c[2] as f32,
        }),
        4 => AnnotationColorNif::Cmyk(CmykNif {
            c: c[0],
            m: c[1],
            y: c[2],
            k: c[3],
        }),
        _ => AnnotationColorNif::Unknown(UnknownNif { components: c }),
    })
}
