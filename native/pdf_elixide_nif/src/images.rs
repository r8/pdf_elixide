use std::{borrow::Cow, io::Cursor};

use pdf_oxide::{
    extractors::{
        ccitt_bilevel::{bilevel_to_grayscale, decompress_ccitt_reporting},
        ColorSpace, ImageData, PdfImage, PixelFormat,
    },
    Error as PdfError,
};
use rustler::{
    Binary, Encoder, Env, NifMap, NifResult, NifTuple, NifUnitEnum, OwnedBinary, ResourceArc, Term,
};

use crate::{
    atoms,
    binary::{binary_term, owned_binary},
    error::{tagged_err, to_nif_err},
    fs_path::path_arg,
    geometry::{finite, rect_to_nif, RectNif},
    resource::Closable,
    ImageResource,
};

#[derive(NifMap)]
#[rustler(encode)]
pub struct ImageNif {
    page: usize,
    bbox: Option<RectNif>,
    width: u32,
    height: u32,
    format: SourceFormatNif,
    resource: ResourceArc<ImageResource>,
    color_space: ColorSpaceNif,
    bits_per_component: u8,
    rotation_degrees: i32,
    matrix: MatrixNif,
}

// The transformation in effect where the image was painted, `[a b c d e f]` —
// every `cm` in scope composed, not one operator's operands. Named fields rather
// than a bare six-tuple so the operand order is documented where the type is
// declared; it still encodes as a six-tuple.
#[derive(NifTuple, Debug)]
pub struct MatrixNif {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    e: f32,
    f: f32,
}

// How the image was stored in the PDF: a compressed JPEG blob (`:jpeg`, so
// re-encoding to JPEG is lossless pass-through) or decoded pixels (`:raw`).
#[derive(NifUnitEnum, Debug)]
pub enum SourceFormatNif {
    Jpeg,
    Raw,
}

// The requested output encoding for `image_to_binary` / `image_save`.
#[derive(NifUnitEnum, Debug)]
pub enum OutputFormatNif {
    Png,
    Jpeg,
}

// The layout of raw (uncompressed) pixel data.
#[derive(NifUnitEnum, Debug)]
pub enum PixelFormatNif {
    Rgb,
    Grayscale,
    Cmyk,
}

impl From<PixelFormat> for PixelFormatNif {
    fn from(format: PixelFormat) -> Self {
        match format {
            PixelFormat::RGB => PixelFormatNif::Rgb,
            PixelFormat::Grayscale => PixelFormatNif::Grayscale,
            PixelFormat::CMYK => PixelFormatNif::Cmyk,
        }
    }
}

// The image's color space, resolved to a plain atom. `ICCBased(_)` flattens to
// `:icc_based` (the component count is dropped).
#[derive(NifUnitEnum, Debug)]
pub enum ColorSpaceNif {
    DeviceRgb,
    DeviceGray,
    DeviceCmyk,
    Indexed,
    CalGray,
    CalRgb,
    Lab,
    IccBased,
    Separation,
    DeviceN,
    Pattern,
}

impl From<&ImageData> for SourceFormatNif {
    fn from(data: &ImageData) -> Self {
        match data {
            ImageData::Jpeg(_) => SourceFormatNif::Jpeg,
            ImageData::Raw { .. } => SourceFormatNif::Raw,
        }
    }
}

impl From<ColorSpace> for ColorSpaceNif {
    fn from(cs: ColorSpace) -> Self {
        match cs {
            ColorSpace::DeviceRGB => ColorSpaceNif::DeviceRgb,
            ColorSpace::DeviceGray => ColorSpaceNif::DeviceGray,
            ColorSpace::DeviceCMYK => ColorSpaceNif::DeviceCmyk,
            ColorSpace::Indexed => ColorSpaceNif::Indexed,
            ColorSpace::CalGray => ColorSpaceNif::CalGray,
            ColorSpace::CalRGB => ColorSpaceNif::CalRgb,
            ColorSpace::Lab => ColorSpaceNif::Lab,
            ColorSpace::ICCBased(_) => ColorSpaceNif::IccBased,
            ColorSpace::Separation => ColorSpaceNif::Separation,
            ColorSpace::DeviceN => ColorSpaceNif::DeviceN,
            ColorSpace::Pattern => ColorSpaceNif::Pattern,
        }
    }
}

// Encoding is lazy, but the complete decoded image or JPEG blob is resident in
// this resource from extraction onward.
pub fn image_to_nif(image: PdfImage, page: usize) -> ImageNif {
    let [a, b, c, d, e, f] = image.matrix().map(finite);

    ImageNif {
        page,
        bbox: image.bbox().copied().map(rect_to_nif),
        width: image.width(),
        height: image.height(),
        format: image.data().into(),
        color_space: (*image.color_space()).into(),
        bits_per_component: image.bits_per_component(),
        rotation_degrees: image.rotation_degrees(),
        matrix: MatrixNif { a, b, c, d, e, f },
        resource: ResourceArc::new(ImageResource {
            image: Closable::new("Image", image),
        }),
    }
}

// Borrow a pass-through JPEG so it is copied only once, directly into the
// Erlang binary; encoding paths already own their output.
#[rustler::nif(schedule = "DirtyCpu")]
fn image_to_binary(
    resource: ResourceArc<ImageResource>,
    format: OutputFormatNif,
) -> NifResult<OwnedBinary> {
    resource.image.with_read(|image| {
        if let Some(pixels) = ccitt_pixels(image) {
            return owned_binary(&encode_gray(image, pixels?, &format)?, "image");
        }

        let bytes: Cow<[u8]> = match format {
            OutputFormatNif::Png => Cow::Owned(image.to_png_bytes().map_err(to_nif_err)?),
            OutputFormatNif::Jpeg => match image.data() {
                // JPEG-stored, non-CMYK → hand back the original bytes (zero loss),
                // matching `save_as_jpeg`'s pass-through.
                ImageData::Jpeg(jpeg) if image.color_space().components() != 4 => {
                    Cow::Borrowed(jpeg.as_slice())
                }
                // CMYK JPEG or raw pixels → decode + encode.
                _ => Cow::Owned(encode_jpeg(image)?),
            },
        };

        owned_binary(&bytes, "image")
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn image_save(
    resource: ResourceArc<ImageResource>,
    path: Binary,
    format: OutputFormatNif,
) -> NifResult<rustler::Atom> {
    // Decoded before the lock: rejecting a path needs no image.
    let path = path_arg(path)?;

    resource.image.with_read(|image| {
        if let Some(pixels) = ccitt_pixels(image) {
            let bytes = encode_gray(image, pixels?, &format)?;
            std::fs::write(&path, bytes).map_err(|e| to_nif_err(PdfError::Io(e)))?;

            return Ok(atoms::ok());
        }

        match format {
            OutputFormatNif::Png => image.save_as_png(&path).map_err(to_nif_err)?,
            OutputFormatNif::Jpeg => image.save_as_jpeg(&path).map_err(to_nif_err)?,
        }

        Ok(atoms::ok())
    })
}

// Build the tagged tuple here so allocation can fail into the error contract
// and borrowed bytes are copied without an intermediate `Vec`.
#[rustler::nif(schedule = "DirtyCpu")]
fn image_data<'a>(env: Env<'a>, resource: ResourceArc<ImageResource>) -> NifResult<Term<'a>> {
    resource.image.with_read(|image| {
        if let Some(pixels) = ccitt_pixels(image) {
            return Ok((
                atoms::raw(),
                binary_term(env, &pixels?, "image")?,
                PixelFormatNif::Grayscale,
            )
                .encode(env));
        }

        Ok(match image.data() {
            ImageData::Jpeg(bytes) => {
                (atoms::jpeg(), binary_term(env, bytes, "image")?).encode(env)
            }
            ImageData::Raw { pixels, format } => (
                atoms::raw(),
                binary_term(env, pixels, "image")?,
                PixelFormatNif::from(*format),
            )
                .encode(env),
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn image_close(resource: ResourceArc<ImageResource>) -> rustler::Atom {
    resource.image.close();

    atoms::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn image_closed(resource: ResourceArc<ImageResource>) -> bool {
    resource.image.is_closed()
}

fn encode_jpeg(image: &PdfImage) -> NifResult<Vec<u8>> {
    let dynamic = image.to_dynamic_image().map_err(to_nif_err)?;
    let mut buffer = Cursor::new(Vec::new());
    dynamic
        .write_to(&mut buffer, image::ImageFormat::Jpeg)
        .map_err(|e| tagged_err(atoms::other(), format!("failed to encode JPEG: {e}")))?;
    Ok(buffer.into_inner())
}

// Keep this guard aligned with `to_dynamic_image` so no other image takes this path.
fn ccitt_pixels(image: &PdfImage) -> Option<NifResult<Vec<u8>>> {
    let decoded = decode_ccitt(image)?;

    Some(decoded.map_err(|failure| match failure {
        CcittFailure::Upstream(e) => to_nif_err(e),
        CcittFailure::NoRows => tagged_err(
            atoms::invalid_pdf(),
            "CCITT image data could not be decoded",
        ),
    }))
}

enum CcittFailure {
    Upstream(PdfError),
    NoRows,
}

fn decode_ccitt(image: &PdfImage) -> Option<Result<Vec<u8>, CcittFailure>> {
    let ImageData::Raw { pixels, .. } = image.data() else {
        return None;
    };
    let params = image.ccitt_params()?;

    if image.bits_per_component() != 1 || !matches!(image.color_space(), ColorSpace::DeviceGray) {
        return None;
    }

    Some(match decompress_ccitt_reporting(pixels, params) {
        Ok((_, 0)) => Err(CcittFailure::NoRows),
        Ok((bilevel, rows_valid)) => {
            let mut gray = bilevel_to_grayscale(&bilevel, image.width(), image.height());
            // Padding for lost rows is written before the `/BlackIs1`
            // inversion, so it can come out black; repaint it white.
            let read = rows_valid.saturating_mul(image.width() as usize);
            if let Some(lost) = gray.get_mut(read..) {
                lost.fill(u8::MAX);
            }
            Ok(gray)
        }
        Err(e) => Err(CcittFailure::Upstream(e)),
    })
}

fn encode_gray(image: &PdfImage, pixels: Vec<u8>, format: &OutputFormatNif) -> NifResult<Vec<u8>> {
    let gray = image::GrayImage::from_raw(image.width(), image.height(), pixels)
        .ok_or_else(|| tagged_err(atoms::other(), "invalid CCITT image dimensions"))?;
    let encoding = match format {
        OutputFormatNif::Png => image::ImageFormat::Png,
        OutputFormatNif::Jpeg => image::ImageFormat::Jpeg,
    };
    let mut buffer = Cursor::new(Vec::new());
    gray.write_to(&mut buffer, encoding)
        .map_err(|e| tagged_err(atoms::other(), format!("failed to encode image: {e}")))?;

    Ok(buffer.into_inner())
}

#[cfg(test)]
mod tests {
    use pdf_oxide::PdfDocument;

    use super::*;

    fn only_image(name: &str) -> PdfImage {
        let path = format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        );
        let doc = PdfDocument::open(path).expect("fixture opens");

        doc.extract_images(0)
            .expect("images extract")
            .into_iter()
            .next()
            .expect("one image")
    }

    #[test]
    fn ccitt_pixels_match_upstream() {
        let image = only_image("image_ccitt.pdf");
        let Some(Ok(ours)) = decode_ccitt(&image) else {
            panic!("the fixture decodes");
        };

        let theirs = image.to_dynamic_image().expect("upstream decodes");
        assert_eq!(ours, theirs.to_luma8().into_raw());
    }
}
