use std::{collections::HashSet, path::PathBuf, sync::Mutex};

use image::{codecs::jpeg::JpegEncoder, ExtendedColorType, ImageEncoder};
use pdf_oxide::{
    document::PageInfo,
    geometry::Rect,
    rendering::{
        flatten_to_images, render_page, render_page_fit, render_page_region, render_separation,
        render_separations, ImageFormat, RenderOptions, RenderedImage, SeparationPlate,
    },
    PdfDocument,
};
use rustler::{Binary, Env, NifMap, NifResult, NifTuple, NifUnitEnum, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    document::ensure_page_in_range,
    error::{tagged_err, to_nif_err},
    geometry::{rect_from_nif, RectNif},
    DocumentResource,
};

// Allocation failure aborts the node and cannot be caught by `contain_panic`;
// cap the raster before upstream allocates it.
const MAX_RENDER_PIXELS: u64 = if usize::BITS >= 64 {
    256_000_000
} else {
    // Allow for simultaneous raster copies within the smaller 32-bit address space.
    64_000_000
};

// Raw RGBA is premultiplied, tightly packed and starts at the top-left.
#[derive(NifUnitEnum, Debug, Clone, Copy)]
pub enum RenderFormatNif {
    Png,
    Jpeg,
    Rgba8,
}

impl From<RenderFormatNif> for ImageFormat {
    fn from(format: RenderFormatNif) -> Self {
        match format {
            RenderFormatNif::Png => ImageFormat::Png,
            RenderFormatNif::Jpeg => ImageFormat::Jpeg,
            RenderFormatNif::Rgba8 => ImageFormat::RawRgba8,
        }
    }
}

// Alpha is always 1.0; Elixir uses `nil` for no background.
#[derive(NifTuple, Debug)]
pub struct BackgroundNif {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
}

#[derive(NifTuple, Debug)]
pub struct FitNif {
    width: u32,
    height: u32,
}

#[derive(NifMap, Debug)]
pub struct RenderOptionsNif {
    dpi: u32,
    format: RenderFormatNif,
    background: Option<BackgroundNif>,
    render_annotations: bool,
    jpeg_quality: u8,
    exclude_layers: Vec<String>,
    fit: Option<FitNif>,
    region: Option<RectNif>,
}

#[derive(NifMap, Debug)]
pub struct DpiOptionsNif {
    dpi: u32,
}

#[derive(NifMap)]
#[rustler(encode)]
pub struct RenderedPageNif<'a> {
    data: Binary<'a>,
    width: u32,
    height: u32,
    format: RenderFormatNif,
}

#[derive(NifMap)]
#[rustler(encode)]
pub struct SeparationPlateNif<'a> {
    ink_name: String,
    data: Binary<'a>,
    width: u32,
    height: u32,
}

// Which of upstream's two dimension formulas applies: a DPI render `ceil`s,
// while the float scale `render_page_fit` installs rounds and clamps to 1.
#[derive(Debug, Clone, Copy)]
enum Scale {
    Dpi(f32),
    Fit(f32),
}

impl RenderOptionsNif {
    // Upstream cannot combine fit scaling with a DPI-based region crop.
    fn validate(&self) -> NifResult<()> {
        if self.fit.is_some() && self.region.is_some() {
            return Err(tagged_err(
                atoms::unsupported(),
                ":fit and :region cannot be combined",
            ));
        }
        // `render_page_region` re-decodes its own full-page output with
        // `image::load_from_memory` before cropping, which raw pixels are not.
        if self.region.is_some() && matches!(self.format, RenderFormatNif::Rgba8) {
            return Err(tagged_err(
                atoms::unsupported(),
                ":region cannot be combined with the :rgba8 format",
            ));
        }

        Ok(())
    }

    fn to_upstream(&self) -> RenderOptions {
        // The private `scale_override` field requires construction through the default.
        let mut options = RenderOptions::with_dpi(self.dpi);
        options.format = self.format.into();
        options.background = self.background.as_ref().map(|bg| [bg.r, bg.g, bg.b, bg.a]);
        options.render_annotations = self.render_annotations;
        options.jpeg_quality = self.jpeg_quality;
        options.excluded_layers = self.exclude_layers.iter().cloned().collect::<HashSet<_>>();

        options
    }
}

// Upstream's own arithmetic from `render_page_with_options`, multiplied in
// `f32` as it is there so the two cannot round apart, and widened to `u64` only
// afterwards so the product cannot wrap before it is compared against the cap.
fn render_dimensions(page_w: f32, page_h: f32, scale: Scale) -> (u64, u64) {
    match scale {
        Scale::Dpi(factor) => (
            (page_w * factor).ceil().max(0.0) as u64,
            (page_h * factor).ceil().max(0.0) as u64,
        ),
        Scale::Fit(factor) => (
            ((page_w * factor).round().max(0.0) as u64).max(1),
            ((page_h * factor).round().max(0.0) as u64).max(1),
        ),
    }
}

fn fit_scale(page_w: f32, page_h: f32, fit: &FitNif) -> f32 {
    (fit.width as f32 / page_w.max(1.0)).min(fit.height as f32 / page_h.max(1.0))
}

// Count spot lanes as full pixmaps to conservatively budget their allocation.
fn within_budget(width: u64, height: u64, buffers: u64) -> bool {
    width.saturating_mul(height).saturating_mul(buffers) <= MAX_RENDER_PIXELS
}

// Use the renderer's page reader, including its Letter fallback, so dimensions agree.
fn page_info(doc: &PdfDocument, page_index: usize) -> NifResult<PageInfo> {
    doc.get_page_info(page_index).map_err(to_nif_err)
}

fn page_extent(info: &PageInfo) -> (f32, f32) {
    match info.rotation.rem_euclid(360) {
        90 | 270 => (info.media_box.height, info.media_box.width),
        _ => (info.media_box.width, info.media_box.height),
    }
}

const PROCESS_INKS: [&str; 4] = ["Cyan", "Magenta", "Yellow", "Black"];

// Count all process and distinct spot inks, including unpainted ones.
// This factor also supplies the buffer count in the error message.
fn plate_count(spots: &[String]) -> u64 {
    PROCESS_INKS.len() as u64 + spot_count(spots)
}

// The transparency gate is private, so budget sidecars for every CMYK-profiled
// page. Ignore ink-walk errors as the renderer does; this can over-count buffers.
fn sidecar_buffers(doc: &PdfDocument, page_index: usize) -> u64 {
    if doc.output_intent_cmyk_profile().is_none() {
        return 0;
    }

    let spots = doc.get_page_inks_deep(page_index).unwrap_or_default();

    1 + spot_count(&spots)
}

fn spot_count(inks: &[String]) -> u64 {
    inks.iter()
        .filter(|ink| !PROCESS_INKS.contains(&ink.as_str()))
        .count() as u64
}

fn ensure_render_budget(
    page_w: f32,
    page_h: f32,
    scale: Scale,
    buffers: u64,
    advice: &str,
) -> NifResult<()> {
    let (width, height) = render_dimensions(page_w, page_h, scale);
    if within_budget(width, height, buffers) {
        return Ok(());
    }

    let scope = if buffers == 1 {
        String::new()
    } else {
        format!(" on each of {buffers} full-page buffers")
    };

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "rendering this page would need {width}x{height} pixels{scope}, over \
             the {MAX_RENDER_PIXELS} pixel limit; {advice}"
        ),
    ))
}

// Map raw page coordinates into upstream's crop frame, accounting for rotation
// and the MediaBox origin. Read `upstream_h` with `get_page_media_box` so its
// inversion cancels even when the page readers disagree.
// Clip first: upstream clamps the origin without shrinking the crop extent.
// `None` denotes an empty intersection.
fn upstream_crop_rect(
    info: &PageInfo,
    upstream_h: f32,
    rect: Rect,
) -> Option<(f32, f32, f32, f32)> {
    let media = info.media_box;
    let dx0 = (rect.x - media.x).max(0.0);
    let dy0 = (rect.y - media.y).max(0.0);
    let dx1 = (rect.x - media.x + rect.width).min(media.width);
    let dy1 = (rect.y - media.y + rect.height).min(media.height);

    let (width, height) = (dx1 - dx0, dy1 - dy0);
    if width <= 0.0 || height <= 0.0 {
        return None;
    }

    let (ix, iy, iw, ih) = match info.rotation.rem_euclid(360) {
        90 => (dy0, dx0, height, width),
        180 => (media.width - dx1, dy0, width, height),
        270 => (media.height - dy1, media.width - dx1, height, width),
        _ => (dx0, media.height - dy1, width, height),
    };

    Some((ix, upstream_h - ih - iy, iw, ih))
}

fn region_off_page(info: &PageInfo, region: &RectNif) -> rustler::Error {
    let media = info.media_box;

    tagged_err(
        atoms::out_of_range(),
        format!(
            "the region {}x{} at ({}, {}) has no area on a page of {}x{} at ({}, {})",
            region.width,
            region.height,
            region.x,
            region.y,
            media.width,
            media.height,
            media.x,
            media.y
        ),
    )
}

// Upstream's JPEG encoder never reads `RenderOptions::jpeg_quality`, so a
// `:jpeg` render is asked for losslessly and encoded here. Raw for a whole page
// and PNG for a crop, because `render_page_region` cannot read raw pixels.
fn lossless_format(region: bool) -> ImageFormat {
    if region {
        ImageFormat::Png
    } else {
        ImageFormat::RawRgba8
    }
}

fn encode_jpeg(image: &RenderedImage, quality: u8) -> Result<Vec<u8>, String> {
    let rgb = match image.format {
        ImageFormat::RawRgba8 => straight_rgb(&image.data, image.width, image.height)?,
        _ => image::load_from_memory(&image.data)
            .map_err(|e| format!("failed to decode the rendered page: {e}"))?
            .to_rgb8()
            .into_raw(),
    };

    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality)
        .write_image(&rgb, image.width, image.height, ExtendedColorType::Rgb8)
        .map_err(|e| format!("failed to encode JPEG: {e}"))?;

    Ok(out)
}

// Upstream's own conversion out of `encode_jpeg`: tiny-skia's buffer is
// premultiplied, and a fully transparent pixel becomes black rather than
// dividing by zero.
fn straight_rgb(data: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let pixels = width as usize * height as usize;
    if data.len() < pixels * 4 {
        return Err(format!(
            "the raw render is {} bytes, short of the {} a {width}x{height} raster needs",
            data.len(),
            pixels * 4
        ));
    }

    let mut rgb = Vec::with_capacity(pixels * 3);
    for px in data.as_chunks::<4>().0.iter().take(pixels) {
        let alpha = f32::from(px[3]) / 255.0;
        if alpha > 0.0 {
            rgb.push((f32::from(px[0]) / alpha).min(255.0) as u8);
            rgb.push((f32::from(px[1]) / alpha).min(255.0) as u8);
            rgb.push((f32::from(px[2]) / alpha).min(255.0) as u8);
        } else {
            rgb.extend_from_slice(&[0, 0, 0]);
        }
    }

    Ok(rgb)
}

fn rendered_page_to_nif<'a>(
    env: Env<'a>,
    image: RenderedImage,
    format: RenderFormatNif,
) -> NifResult<RenderedPageNif<'a>> {
    Ok(RenderedPageNif {
        data: owned_binary(&image.data, "render")?.release(env),
        width: image.width,
        height: image.height,
        format,
    })
}

fn plate_to_nif<'a>(env: Env<'a>, plate: SeparationPlate) -> NifResult<SeparationPlateNif<'a>> {
    Ok(SeparationPlateNif {
        ink_name: plate.ink_name,
        data: owned_binary(&plate.data, "separation")?.release(env),
        width: plate.width,
        height: plate.height,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_render_page<'a>(
    env: Env<'a>,
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: RenderOptionsNif,
) -> NifResult<RenderedPageNif<'a>> {
    options.validate()?;

    resource.doc.with_read(|doc| {
        // Check explicitly: upstream classifies a bad index as `InvalidPdf`.
        ensure_page_in_range(doc, page_index)?;

        let info = page_info(doc, page_index)?;
        let (page_w, page_h) = page_extent(&info);
        let buffers = 1 + sidecar_buffers(doc, page_index);
        let mut upstream = options.to_upstream();
        let jpeg = matches!(options.format, RenderFormatNif::Jpeg);
        if jpeg {
            upstream.format = lossless_format(options.region.is_some());
        }

        let image = match (&options.fit, &options.region) {
            (Some(fit), _) => {
                let scale = fit_scale(page_w, page_h, fit);
                ensure_render_budget(
                    page_w,
                    page_h,
                    Scale::Fit(scale),
                    buffers,
                    "use a smaller :fit box",
                )?;
                render_page_fit(doc, page_index, fit.width, fit.height, &upstream)
            }
            (None, Some(region)) => {
                // The crop is a post-process on a full-page raster, so the whole
                // page has to fit in the budget even when the region is small.
                ensure_render_budget(
                    page_w,
                    page_h,
                    Scale::Dpi(options.dpi as f32 / 72.0),
                    buffers,
                    "lower :dpi or use :fit",
                )?;
                // Use the same box reader as upstream's crop to preserve its coordinates and errors.
                let (_, lly, _, ury) = doc.get_page_media_box(page_index).map_err(to_nif_err)?;
                let rect = upstream_crop_rect(&info, ury - lly, rect_from_nif(*region))
                    .ok_or_else(|| region_off_page(&info, region))?;
                render_page_region(doc, page_index, rect, &upstream)
            }
            (None, None) => {
                ensure_render_budget(
                    page_w,
                    page_h,
                    Scale::Dpi(options.dpi as f32 / 72.0),
                    buffers,
                    "lower :dpi or use :fit",
                )?;
                render_page(doc, page_index, &upstream)
            }
        }
        .map_err(to_nif_err)?;

        let image = if jpeg {
            let data = encode_jpeg(&image, options.jpeg_quality)
                .map_err(|message| tagged_err(atoms::other(), message))?;

            RenderedImage {
                data,
                format: ImageFormat::Jpeg,
                ..image
            }
        } else {
            image
        };

        rendered_page_to_nif(env, image, options.format)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_render_separations<'a>(
    env: Env<'a>,
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    options: DpiOptionsNif,
) -> NifResult<Vec<SeparationPlateNif<'a>>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let (page_w, page_h) = page_extent(&page_info(doc, page_index)?);
        // The error propagates because `collect_page_inks` propagates it: a page
        // whose ink walk fails produces no plates upstream either.
        let spots = doc.get_page_inks_deep(page_index).map_err(to_nif_err)?;
        let plates = plate_count(&spots);
        ensure_render_budget(
            page_w,
            page_h,
            Scale::Dpi(options.dpi as f32 / 72.0),
            plates,
            "lower :dpi",
        )?;

        render_separations(doc, page_index, options.dpi)
            .map_err(to_nif_err)?
            .into_iter()
            .map(|plate| plate_to_nif(env, plate))
            .collect()
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_render_separation<'a>(
    env: Env<'a>,
    resource: ResourceArc<DocumentResource>,
    page_index: usize,
    ink: String,
    options: DpiOptionsNif,
) -> NifResult<SeparationPlateNif<'a>> {
    resource.doc.with_read(|doc| {
        ensure_page_in_range(doc, page_index)?;

        let (page_w, page_h) = page_extent(&page_info(doc, page_index)?);
        // The whole ink set, not the one plate asked for: upstream's composite
        // path allocates the entire sidecar either way. The walk's error is
        // swallowed because upstream still yields a plate when it fails.
        let spots = doc.get_page_inks_deep(page_index).unwrap_or_default();
        let plates = plate_count(&spots);
        ensure_render_budget(
            page_w,
            page_h,
            Scale::Dpi(options.dpi as f32 / 72.0),
            plates,
            "lower :dpi",
        )?;

        let plate = render_separation(doc, page_index, &ink, options.dpi).map_err(to_nif_err)?;

        plate_to_nif(env, plate)
    })
}

// Upstream shares a process-wide temp directory. Serialize direct NIF callers
// too, taking this mutex before the handle lock. Elixir queues ordinary callers
// in the BEAM to avoid occupying dirty scheduler threads.
static RASTERIZE: Mutex<()> = Mutex::new(());

// Upstream only removes this staging directory on success.
fn flatten_temp_dir() -> PathBuf {
    std::env::temp_dir().join(format!("pdf_oxide_flatten_{}", std::process::id()))
}

// `DirtyCpu` rather than `DirtyIo` despite the temporary files: the work is a
// full-document render and the writes are incidental to it.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_rasterize(
    resource: ResourceArc<DocumentResource>,
    options: DpiOptionsNif,
) -> NifResult<OwnedBinary> {
    let _serialized = RASTERIZE.lock().unwrap_or_else(|e| e.into_inner());

    let result = resource.doc.with_read(|doc| {
        let count = doc.page_count().map_err(to_nif_err)?;

        // Populate the page cache before measuring: filling it can change inherited
        // boxes and rotations, invalidating earlier allocation estimates.
        for page_index in 0..count {
            page_info(doc, page_index)?;
        }

        for page_index in 0..count {
            let (page_w, page_h) = page_extent(&page_info(doc, page_index)?);
            ensure_render_budget(
                page_w,
                page_h,
                Scale::Dpi(options.dpi as f32 / 72.0),
                1 + sidecar_buffers(doc, page_index),
                "lower :dpi",
            )?;
        }

        let bytes = flatten_to_images(doc, options.dpi).map_err(to_nif_err)?;

        owned_binary(&bytes, "rasterized document")
    });

    // Keep `RASTERIZE` held through cleanup so no other call can use the directory.
    // Panic containment also brings failed renders here.
    let _ = std::fs::remove_dir_all(flatten_temp_dir());

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/../../test/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))
    }

    #[test]
    fn dpi_dimensions_round_up_and_fit_dimensions_round() {
        assert_eq!(
            render_dimensions(612.0, 792.0, Scale::Dpi(150.0 / 72.0)),
            (1275, 1650)
        );
        assert_eq!(render_dimensions(100.4, 100.4, Scale::Dpi(1.0)), (101, 101));
        assert_eq!(render_dimensions(100.4, 100.4, Scale::Fit(1.0)), (100, 100));
        assert_eq!(render_dimensions(612.0, 792.0, Scale::Fit(0.0001)), (1, 1));
    }

    #[test]
    fn fit_scale_preserves_aspect_and_never_divides_by_zero() {
        let fit = FitNif {
            width: 300,
            height: 300,
        };
        assert!((fit_scale(612.0, 792.0, &fit) - 300.0 / 792.0).abs() < f32::EPSILON);
        assert!(fit_scale(0.0, 0.0, &fit).is_finite());
    }

    #[test]
    fn the_budget_rejects_what_would_abort_the_node() {
        let (w, h) = render_dimensions(612.0, 792.0, Scale::Dpi(600.0 / 72.0));
        assert!(within_budget(w, h, 1));
        let (w, h) = render_dimensions(612.0, 792.0, Scale::Dpi(10_000.0 / 72.0));
        assert!(!within_budget(w, h, 1));
        assert!(!within_budget(u64::MAX, u64::MAX, 1));
        assert!(!within_budget(u64::MAX, u64::MAX, u64::MAX));
    }

    #[test]
    fn the_budget_counts_every_full_page_buffer() {
        let (w, h) = render_dimensions(612.0, 792.0, Scale::Dpi(600.0 / 72.0));
        assert!(within_budget(w, h, 1));
        assert!(!within_budget(w, h, 20));
        assert!(!within_budget(w, h, 1 + 1 + 8));

        // Use a fraction of the cap so this assertion holds on both pointer widths.
        let quarter = MAX_RENDER_PIXELS / 4;
        assert!(within_budget(quarter, 1, 4));
        assert!(!within_budget(quarter, 1, 5));
    }

    #[test]
    fn only_non_process_inks_count_as_spot_lanes() {
        let inks = |names: &[&str]| names.iter().map(|n| n.to_string()).collect::<Vec<_>>();

        assert_eq!(
            spot_count(&inks(&["Cyan", "Magenta", "Yellow", "Black"])),
            0
        );
        assert_eq!(spot_count(&inks(&["Black", "PANTONE 185 C", "Varnish"])), 2);
    }

    #[test]
    fn a_crop_rect_is_mapped_into_the_space_upstream_reads() {
        let letter = info(0.0, 0.0, 612.0, 792.0, 0);
        let whole = Rect::new(0.0, 0.0, 612.0, 792.0);

        assert_eq!(
            upstream_crop_rect(&letter, 792.0, Rect::new(10.0, 20.0, 100.0, 80.0)),
            Some((10.0, 20.0, 100.0, 80.0))
        );

        assert_eq!(
            upstream_crop_rect(&info(0.0, 0.0, 612.0, 792.0, 90), 792.0, whole),
            Some((0.0, 180.0, 792.0, 612.0))
        );
        assert_eq!(
            upstream_crop_rect(&info(0.0, 0.0, 612.0, 792.0, 180), 792.0, whole),
            Some((0.0, 0.0, 612.0, 792.0))
        );
        assert_eq!(
            upstream_crop_rect(&info(0.0, 0.0, 612.0, 792.0, 270), 792.0, whole),
            Some((0.0, 180.0, 792.0, 612.0))
        );

        assert_eq!(
            upstream_crop_rect(
                &info(10.0, 20.0, 612.0, 792.0, 0),
                792.0,
                Rect::new(10.0, 20.0, 612.0, 792.0)
            ),
            Some((0.0, 0.0, 612.0, 792.0))
        );

        assert_eq!(
            upstream_crop_rect(&info(0.0, 0.0, 612.0, 792.0, 45), 792.0, whole),
            upstream_crop_rect(&letter, 792.0, whole)
        );

        // An asymmetric rect distinguishes all four rotations.
        let inner = Rect::new(20.0, 10.0, 50.0, 30.0);
        let turned =
            |rotation| upstream_crop_rect(&info(0.0, 0.0, 200.0, 200.0, rotation), 200.0, inner);

        assert_eq!(turned(0), Some((20.0, 10.0, 50.0, 30.0)));
        assert_eq!(turned(90), Some((10.0, 130.0, 30.0, 50.0)));
        assert_eq!(turned(180), Some((130.0, 160.0, 50.0, 30.0)));
        assert_eq!(turned(270), Some((160.0, 20.0, 30.0, 50.0)));
    }

    #[test]
    fn a_crop_rect_is_clipped_to_the_page() {
        let square = info(0.0, 0.0, 200.0, 200.0, 0);
        let over_the_left = Rect::new(-50.0, 0.0, 100.0, 80.0);

        assert_eq!(
            upstream_crop_rect(&square, 200.0, over_the_left),
            Some((0.0, 0.0, 50.0, 80.0))
        );

        assert_eq!(
            upstream_crop_rect(&info(0.0, 0.0, 200.0, 200.0, 90), 200.0, over_the_left),
            Some((0.0, 150.0, 80.0, 50.0))
        );

        assert_eq!(
            upstream_crop_rect(
                &info(10.0, 20.0, 612.0, 792.0, 0),
                792.0,
                Rect::new(0.0, 0.0, 112.0, 120.0)
            ),
            Some((0.0, 0.0, 102.0, 100.0))
        );

        assert_eq!(
            upstream_crop_rect(&square, 200.0, Rect::new(250.0, 0.0, 100.0, 80.0)),
            None
        );
        assert_eq!(
            upstream_crop_rect(&square, 200.0, Rect::new(0.0, 200.0, 100.0, 80.0)),
            None
        );
        assert_eq!(
            upstream_crop_rect(&square, 200.0, Rect::new(10.0, 10.0, 0.0, 80.0)),
            None
        );
    }

    fn info(x: f32, y: f32, width: f32, height: f32, rotation: i32) -> PageInfo {
        PageInfo {
            media_box: Rect::new(x, y, width, height),
            crop_box: None,
            rotation,
        }
    }

    // Justifies refusing `:region` with `:rgba8`.
    #[test]
    fn upstream_still_cannot_crop_a_raw_render() {
        let doc = PdfDocument::open(fixture("sample.pdf")).expect("open");
        let options = RenderOptions::with_dpi(72).as_raw();

        assert!(
            render_page_region(&doc, 0, (10.0, 10.0, 50.0, 50.0), &options).is_err(),
            "upstream now crops a raw render"
        );
        assert!(
            render_page_region(
                &doc,
                0,
                (10.0, 10.0, 50.0, 50.0),
                &RenderOptions::with_dpi(72)
            )
            .is_ok(),
            "the PNG control crop failed, so the raw assertion proves nothing"
        );
    }

    #[test]
    fn upstream_still_defaults_a_missing_media_box_to_letter() {
        let doc = PdfDocument::open(fixture("media_box.pdf")).expect("open");
        let boxless = doc.page_count().expect("count") - 1;

        assert!(
            doc.get_page_media_box(boxless).is_err(),
            "the fixture's last page gained a /MediaBox; this test needs one without"
        );

        let info = doc.get_page_info(boxless).expect("page info");
        assert_eq!(
            (info.media_box.width, info.media_box.height),
            (612.0, 792.0),
            "upstream stopped substituting Letter for an unreadable /MediaBox"
        );
    }

    // Justifies `upstream_crop_rect`.
    #[test]
    fn upstream_still_crops_in_unrotated_page_space() {
        let doc = PdfDocument::open(fixture("rotation.pdf")).expect("open");
        let options = RenderOptions::with_dpi(72);

        let turned = render_page_region(&doc, 0, (0.0, 0.0, 612.0, 792.0), &options).expect("crop");
        assert_eq!(
            (turned.width, turned.height),
            (612, 612),
            "upstream now crops in the raster's frame"
        );

        let upright =
            render_page_region(&doc, 3, (0.0, 0.0, 612.0, 792.0), &options).expect("crop");
        assert_eq!(
            (upright.width, upright.height),
            (612, 792),
            "the unrotated control crop failed, so the assertion above proves nothing"
        );
    }

    // Dimensions cannot detect mirroring; the fixture fills x=0..100 on a
    // 200 x 100 pt page rotated by 270 degrees.
    #[test]
    fn a_mapped_crop_lands_on_the_content_it_names() {
        let doc = PdfDocument::open(fixture("rotated_separation.pdf")).expect("open");
        let info = doc.get_page_info(0).expect("page info");
        let (_, lly, _, ury) = doc.get_page_media_box(0).expect("media box");
        let options = RenderOptions::with_dpi(72);

        let crop = |rect: Rect| {
            let mapped = upstream_crop_rect(&info, ury - lly, rect).expect("on the page");
            let image = render_page_region(&doc, 0, mapped, &options).expect("crop");
            image::load_from_memory(&image.data)
                .expect("decode")
                .to_luma8()
        };

        let inked = crop(Rect::new(0.0, 0.0, 100.0, 100.0));
        let paper = crop(Rect::new(100.0, 0.0, 100.0, 100.0));
        assert_eq!((inked.width(), inked.height()), (100, 100));
        assert!(
            inked.pixels().all(|p| p.0[0] < 128),
            "the crop of the inked half is not all ink"
        );
        assert!(
            paper.pixels().all(|p| p.0[0] == 255),
            "the crop of the empty half is not all paper"
        );
    }

    // The rotated strip must mark the left edge and leave the right edge clear.
    #[test]
    fn a_mapped_crop_of_a_quarter_turned_page_is_the_raster_edge_it_names() {
        let doc = PdfDocument::open(fixture("rotation.pdf")).expect("open");
        let info = doc.get_page_info(0).expect("page info");
        assert_eq!(
            info.rotation.rem_euclid(360),
            90,
            "page 0 stopped being a 90-degree page"
        );
        let (_, lly, _, ury) = doc.get_page_media_box(0).expect("media box");
        let options = RenderOptions::with_dpi(72);

        let full = render_page(&doc, 0, &options.clone().as_raw()).expect("render");
        let strip = Rect::new(0.0, 0.0, info.media_box.width, 100.0);
        let mapped = upstream_crop_rect(&info, ury - lly, strip).expect("on the page");
        let crop = render_page_region(&doc, 0, mapped, &options).expect("crop");
        let crop = image::load_from_memory(&crop.data)
            .expect("decode")
            .to_rgba8();
        assert_eq!((crop.width(), crop.height()), (100, full.height));

        let raster = |col: u32, row: u32| {
            let at = ((row * full.width + col) * 4) as usize;
            &full.data[at..at + 4]
        };
        let mut differs_from_right = false;
        for (col, row, px) in crop.enumerate_pixels() {
            assert_eq!(
                px.0,
                raster(col, row),
                "pixel ({col}, {row}) differs from the raster's left edge"
            );
            differs_from_right |= px.0 != raster(full.width - 100 + col, row);
        }
        assert!(
            differs_from_right,
            "the raster's two edges match, so the assertion above proves nothing"
        );
    }

    // Justifies the cleanup in `document_rasterize`. The reversed-corner page
    // fails after page 0 has been written.
    #[test]
    fn upstream_still_leaves_its_page_images_behind_on_failure() {
        let doc = PdfDocument::open(fixture("media_box.pdf")).expect("open");
        let _ = std::fs::remove_dir_all(flatten_temp_dir());

        assert!(
            flatten_to_images(&doc, 18).is_err(),
            "the fixture stopped failing part-way, so nothing here is proven"
        );
        let left_behind = flatten_temp_dir().exists();
        let _ = std::fs::remove_dir_all(flatten_temp_dir());

        assert!(
            left_behind,
            "upstream now removes its temp directory on the error path"
        );
    }

    // Justifies budgeting `document_rasterize` per page rather than per document.
    #[test]
    fn upstream_still_holds_assembled_pages_compressed() {
        let doc = PdfDocument::open(fixture("sample.pdf")).expect("open");
        let page = render_page(&doc, 0, &RenderOptions::with_dpi(72)).expect("render");
        let raw = page.width as usize * page.height as usize * 3;

        let loaded = pdf_oxide::writer::ImageData::from_png(&page.data).expect("load");
        assert_eq!((loaded.width, loaded.height), (page.width, page.height));
        // The threshold distinguishes compressed output from raw pixels.
        assert!(
            loaded.data.len() * 4 < raw,
            "upstream now holds an assembled page at {} bytes against {raw} raw",
            loaded.data.len()
        );
    }

    // Justifies `encode_jpeg`, `straight_rgb` and `lossless_format`.
    #[test]
    fn upstream_still_ignores_jpeg_quality() {
        let doc = PdfDocument::open(fixture("sample.pdf")).expect("open");
        let render = |quality: u8| {
            render_page(&doc, 0, &RenderOptions::with_dpi(72).as_jpeg(quality))
                .expect("render")
                .data
        };

        assert_eq!(render(1), render(100), "upstream now honours jpeg_quality");
        let raw = render_page(&doc, 0, &RenderOptions::with_dpi(72).as_raw()).expect("render");
        assert_ne!(
            encode_jpeg(&raw, 1).expect("encode"),
            encode_jpeg(&raw, 100).expect("encode"),
            "the local encoder stopped responding to quality"
        );
    }

    #[test]
    fn a_premultiplied_raster_comes_back_as_straight_rgb() {
        let premultiplied = [255, 0, 0, 255, 128, 0, 0, 128, 0, 0, 0, 0];

        // Upstream's f32 un-premultiply truncates this component to 254.
        assert_eq!(
            straight_rgb(&premultiplied, 3, 1),
            Ok(vec![255, 0, 0, 254, 0, 0, 0, 0, 0])
        );
        assert!(straight_rgb(&premultiplied, 4, 1).is_err());
    }

    #[test]
    fn the_spot_ink_fixture_declares_what_the_budget_counts() {
        let doc = PdfDocument::open(fixture("spot_inks_and_intent.pdf")).expect("open");

        assert!(
            doc.output_intent_cmyk_profile().is_some(),
            "the synthetic /DestOutputProfile no longer parses as a CMYK profile"
        );
        assert_eq!(sidecar_buffers(&doc, 0), 9, "page 0 lost its spot inks");
        assert_eq!(
            sidecar_buffers(&doc, 1),
            1,
            "page 1 gained an ink, so it is no longer the control"
        );
    }

    // Guards no local code; the defect is recorded rather than worked around.
    #[test]
    fn upstream_still_mirrors_a_270_degree_separation() {
        let doc = PdfDocument::open(fixture("rotated_separation.pdf")).expect("open");

        let rendered = render_page(&doc, 0, &RenderOptions::with_dpi(72).as_raw()).expect("render");
        let plate = render_separation(&doc, 0, "Black", 72).expect("plate");
        assert_eq!(
            (plate.width, plate.height),
            (rendered.width, rendered.height),
            "the plate and the render disagree about the raster size"
        );

        // The fixture marks the bottom half after rotation; column 0 distinguishes
        // the two halves.
        let inked = |row: u32| plate.data[(row * plate.width) as usize] > 0;
        let painted = |row: u32| rendered.data[(row * rendered.width * 4) as usize] < 128;

        let (top, bottom) = (1, plate.height - 2);
        assert!(
            painted(top) != painted(bottom),
            "the fixture stopped painting exactly one half of the render"
        );
        assert!(
            inked(top) != inked(bottom),
            "the fixture stopped painting exactly one half of the plate"
        );
        assert!(
            inked(top) != painted(top),
            "upstream stopped mirroring a 270-degree separation"
        );
    }
}
