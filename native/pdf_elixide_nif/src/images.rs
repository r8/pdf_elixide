use std::{borrow::Cow, io::Cursor};

use pdf_oxide::extractors::{ColorSpace, ImageData, PdfImage, PixelFormat};
use rustler::{Encoder, Env, NifMap, NifResult, NifUnitEnum, OwnedBinary, ResourceArc, Term};

use crate::{
    atoms,
    binary::{binary_term, owned_binary},
    error::{tagged_err, to_nif_err},
    geometry::{rect_to_nif, RectNif},
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
}

/// How the image was stored in the PDF: a compressed JPEG blob (`:jpeg`, so
/// re-encoding to JPEG is lossless pass-through) or decoded pixels (`:raw`).
#[derive(NifUnitEnum, Debug)]
pub enum SourceFormatNif {
    Jpeg,
    Raw,
}

/// The requested output encoding for `image_to_binary` / `image_save`.
#[derive(NifUnitEnum, Debug)]
pub enum OutputFormatNif {
    Png,
    Jpeg,
}

/// The layout of raw (uncompressed) pixel data.
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

/// The image's color space, resolved to a plain atom. `ICCBased(_)` flattens to
/// `:icc_based` (the component count is dropped).
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

/// Converts an extracted `PdfImage` into its NIF representation: eager metadata
/// plus a resource handle to the image itself, so the pixel data is encoded
/// lazily (on `image_to_binary` / `image_save`) rather than at extraction time.
pub fn image_to_nif(image: PdfImage, page: usize) -> ImageNif {
    ImageNif {
        page,
        bbox: image.bbox().copied().map(rect_to_nif),
        width: image.width(),
        height: image.height(),
        format: image.data().into(),
        color_space: (*image.color_space()).into(),
        bits_per_component: image.bits_per_component(),
        rotation_degrees: image.rotation_degrees(),
        resource: ResourceArc::new(ImageResource {
            image: Closable::new("Image", image),
        }),
    }
}

/// Encodes the image to the requested format and returns the bytes as an Erlang
/// binary. PNG goes through `to_png_bytes`; JPEG passes the original bytes
/// through for non-CMYK JPEG-stored images (zero loss) and otherwise decodes and
/// re-encodes.
///
/// The pass-through branch yields a `Cow::Borrowed` of the blob still held by the
/// resource, so it is copied once — straight into the Erlang binary — rather than
/// being cloned into an intermediate `Vec` first. The encoding branches own their
/// output already, so that single copy is all any path costs.
#[rustler::nif(schedule = "DirtyCpu")]
fn image_to_binary(
    resource: ResourceArc<ImageResource>,
    format: OutputFormatNif,
) -> NifResult<OwnedBinary> {
    resource.image.with_read(|image| {
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

/// Writes the image to `path`, encoded as the requested format.
#[rustler::nif(schedule = "DirtyIo")]
fn image_save(
    resource: ResourceArc<ImageResource>,
    path: String,
    format: OutputFormatNif,
) -> NifResult<rustler::Atom> {
    resource.image.with_read(|image| {
        match format {
            OutputFormatNif::Png => image.save_as_png(path).map_err(to_nif_err)?,
            OutputFormatNif::Jpeg => image.save_as_jpeg(path).map_err(to_nif_err)?,
        }

        Ok(atoms::ok())
    })
}

/// Returns the image's raw stored bytes as a flat tagged tuple:
/// `{:jpeg, <binary>}` (the original DCTDecode blob) or
/// `{:raw, <binary>, pixel_format}` (bare pixels — not a standalone file).
///
/// The tuple is built here rather than through an `Encoder` impl so the
/// allocation can fail into an error term, and so the bytes are copied straight
/// out of the guard's borrow instead of being cloned into an intermediate `Vec`
/// first.
#[rustler::nif(schedule = "DirtyCpu")]
fn image_data<'a>(env: Env<'a>, resource: ResourceArc<ImageResource>) -> NifResult<Term<'a>> {
    resource.image.with_read(|image| {
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

/// Releases the image's pixel data now, rather than waiting for the BEAM to
/// garbage-collect the handle. Idempotent. Takes the handle's lock exclusively,
/// so it waits for an in-flight read on the same handle to return — see
/// [`Closable::close`](crate::resource::Closable::close).
#[rustler::nif(schedule = "DirtyCpu")]
fn image_close(resource: ResourceArc<ImageResource>) -> rustler::Atom {
    resource.image.close();

    atoms::ok()
}

/// Returns whether the image has been released with `image_close`.
#[rustler::nif(schedule = "DirtyCpu")]
fn image_closed(resource: ResourceArc<ImageResource>) -> bool {
    resource.image.is_closed()
}

/// Decodes the image and re-encodes it as JPEG bytes in memory.
fn encode_jpeg(image: &PdfImage) -> NifResult<Vec<u8>> {
    let dynamic = image.to_dynamic_image().map_err(to_nif_err)?;
    let mut buffer = Cursor::new(Vec::new());
    dynamic
        .write_to(&mut buffer, image::ImageFormat::Jpeg)
        .map_err(|e| tagged_err(atoms::other(), format!("failed to encode JPEG: {e}")))?;
    Ok(buffer.into_inner())
}
