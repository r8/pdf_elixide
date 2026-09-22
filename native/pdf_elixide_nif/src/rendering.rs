use std::{collections::HashSet, path::PathBuf, sync::Mutex};

use image::{codecs::jpeg::JpegEncoder, ExtendedColorType, ImageEncoder};
use pdf_oxide::{
    document::PageInfo,
    geometry::Rect,
    rendering::{
        flatten_to_images, render_page, render_page_fit, render_page_region, render_separation,
        render_separations, ImageFormat, RenderOptions, RenderedImage, SeparationPlate,
        DEFAULT_MAX_OUTPUT_PIXELS,
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
    max_output_pixels: Option<u64>,
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

impl Scale {
    fn factor(self) -> f32 {
        match self {
            Scale::Dpi(factor) | Scale::Fit(factor) => factor,
        }
    }
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
        // Resolve the cap here so default renders cannot be silently downscaled upstream.
        options.max_output_pixels = self.max_output_pixels.unwrap_or(MAX_RENDER_PIXELS);

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

// Mirror the distinct f64 arithmetic upstream uses to decide whether to reduce.
fn upstream_want(page_w: f32, page_h: f32, scale: f32) -> (u64, u64) {
    (
        (f64::from(page_w) * f64::from(scale)).ceil().max(0.0) as u64,
        (f64::from(page_h) * f64::from(scale)).ceil().max(0.0) as u64,
    )
}

// Do not substitute `render_dimensions`: its allocation rounding can be smaller.
fn would_be_reduced(page_w: f32, page_h: f32, scale: f32, cap: u64) -> bool {
    let (width, height) = upstream_want(page_w, page_h, scale);

    width.saturating_mul(height) > cap.max(1)
}

fn fit_scale(page_w: f32, page_h: f32, fit: &FitNif) -> f32 {
    (fit.width as f32 / page_w.max(1.0)).min(fit.height as f32 / page_h.max(1.0))
}

// Count spot lanes as full pixmaps to conservatively budget their allocation.
fn within_budget(pixels: u64, buffers: u64) -> bool {
    pixels.saturating_mul(buffers) <= MAX_RENDER_PIXELS
}

// Only an explicit caller cap may make the allocation guard accept a smaller raster.
fn budgeted_pixels(width: u64, height: u64, cap: Option<u64>) -> u64 {
    let pixels = width.saturating_mul(height);

    match cap {
        Some(cap) => pixels.min(cap.max(1)),
        None => pixels,
    }
}

// Use the renderer's page reader, including its Letter fallback, so dimensions agree.
fn page_info(doc: &PdfDocument, page_index: usize) -> NifResult<PageInfo> {
    doc.get_page_info(page_index).map_err(to_nif_err)
}

// Mirror upstream's private `page_render_box` over the same `PageInfo` it renders.
fn render_box(info: &PageInfo) -> Rect {
    let media = info.media_box;
    let Some(crop) = info.crop_box else {
        return media;
    };

    let x0 = crop.x.max(media.x);
    let y0 = crop.y.max(media.y);
    let x1 = (crop.x + crop.width).min(media.x + media.width);
    let y1 = (crop.y + crop.height).min(media.y + media.height);

    // A crop box describing nothing to show must not blank the page.
    if x1 <= x0 || y1 <= y0 {
        return media;
    }

    Rect::from_points(x0, y0, x1, y1)
}

fn rotated_extent(box_: Rect, rotation: i32) -> (f32, f32) {
    match rotation.rem_euclid(360) {
        90 | 270 => (box_.height, box_.width),
        _ => (box_.width, box_.height),
    }
}

// What the pixmap covers, and so what every budget measures.
fn render_extent(info: &PageInfo) -> (f32, f32) {
    rotated_extent(render_box(info), info.rotation)
}

// Fit scaling uses the medium even though the resulting pixmap uses the render box.
fn media_extent(info: &PageInfo) -> (f32, f32) {
    rotated_extent(info.media_box, info.rotation)
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
    cap: Option<u64>,
    advice: &str,
) -> NifResult<()> {
    let (width, height) = render_dimensions(page_w, page_h, scale);

    // On the default path, guard both allocation and upstream's larger threshold rounding.
    let (width, height) = match cap {
        Some(_) => (width, height),
        None => {
            let want = upstream_want(page_w, page_h, scale.factor());
            if want.0.saturating_mul(want.1) > width.saturating_mul(height) {
                want
            } else {
                (width, height)
            }
        }
    };

    let budget = budgeted_pixels(width, height, cap);
    if within_budget(budget, buffers) {
        return Ok(());
    }

    let scope = if buffers == 1 {
        String::new()
    } else {
        format!(" on each of {buffers} full-page buffers")
    };

    Err(tagged_err(
        atoms::unsupported(),
        match cap {
            // The caller's own budget is what the limit rejects, and lowering
            // `:dpi` only helps once the page falls under it. Naming the page
            // here would report a raster this call would never allocate.
            Some(cap) if budget < width.saturating_mul(height) => format!(
                "the :max_output_pixels budget of {cap} pixels{scope} is over the \
                 {MAX_RENDER_PIXELS} pixel limit; lower :max_output_pixels"
            ),
            _ => format!(
                "rendering this page would need {width}x{height} pixels{scope}, over \
                 the {MAX_RENDER_PIXELS} pixel limit; {advice}"
            ),
        },
    ))
}

// DPI-only upstream calls fix their own cap; refuse before they can scale inconsistently.
fn ensure_upstream_budget(page_w: f32, page_h: f32, dpi: u32, advice: &str) -> NifResult<()> {
    // Upstream's threshold arithmetic, not the pixmap's: this predicts its branch.
    let scale = dpi as f32 / 72.0;
    if !would_be_reduced(page_w, page_h, scale, DEFAULT_MAX_OUTPUT_PIXELS) {
        return Ok(());
    }

    let (width, height) = upstream_want(page_w, page_h, scale);

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "rendering this page would need {width}x{height} pixels, over the \
             {DEFAULT_MAX_OUTPUT_PIXELS} pixel limit this call cannot raise; {advice}"
        ),
    ))
}

// Region coordinates stay at the requested DPI, so refuse a cap that changes the scale.
fn ensure_crop_is_not_reduced(
    page_w: f32,
    page_h: f32,
    options: &RenderOptionsNif,
) -> NifResult<()> {
    let Some(cap) = options.max_output_pixels else {
        return Ok(());
    };

    let scale = options.dpi as f32 / 72.0;
    if !would_be_reduced(page_w, page_h, scale, cap) {
        return Ok(());
    }

    let (width, height) = upstream_want(page_w, page_h, scale);

    Err(tagged_err(
        atoms::unsupported(),
        format!(
            "cropping with :region needs the whole page, {width}x{height} pixels, \
             within :max_output_pixels ({cap}); the crop would be taken from a \
             reduced raster at the requested :dpi. Lower :dpi or raise \
             :max_output_pixels"
        ),
    ))
}

// Map raw page coordinates into the render-box frame. `upstream_h` must remain
// the media height because `render_page_region` subtracts that same value.
// Clip first: upstream clamps the origin without shrinking the crop extent.
// `None` denotes an empty intersection.
fn upstream_crop_rect(
    info: &PageInfo,
    upstream_h: f32,
    rect: Rect,
) -> Option<(f32, f32, f32, f32)> {
    let media = render_box(info);
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
    let media = render_box(info);

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
        let (page_w, page_h) = render_extent(&info);
        let buffers = 1 + sidecar_buffers(doc, page_index);
        let mut upstream = options.to_upstream();
        let jpeg = matches!(options.format, RenderFormatNif::Jpeg);
        if jpeg {
            upstream.format = lossless_format(options.region.is_some());
        }

        let image = match (&options.fit, &options.region) {
            (Some(fit), _) => {
                // Scale the medium, but budget the render-box raster.
                let (fit_w, fit_h) = media_extent(&info);
                let scale = fit_scale(fit_w, fit_h, fit);
                ensure_render_budget(
                    page_w,
                    page_h,
                    Scale::Fit(scale),
                    buffers,
                    options.max_output_pixels,
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
                    options.max_output_pixels,
                    "lower :dpi or use :fit",
                )?;
                ensure_crop_is_not_reduced(page_w, page_h, &options)?;
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
                    options.max_output_pixels,
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

        let (page_w, page_h) = render_extent(&page_info(doc, page_index)?);
        // The error propagates because `collect_page_inks` propagates it: a page
        // whose ink walk fails produces no plates upstream either.
        let spots = doc.get_page_inks_deep(page_index).map_err(to_nif_err)?;
        let plates = plate_count(&spots);
        ensure_render_budget(
            page_w,
            page_h,
            Scale::Dpi(options.dpi as f32 / 72.0),
            plates,
            None,
            "lower :dpi",
        )?;
        // Keep the more specific buffer-count refusal first.
        ensure_upstream_budget(page_w, page_h, options.dpi, "lower :dpi")?;

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

        let (page_w, page_h) = render_extent(&page_info(doc, page_index)?);
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
            None,
            "lower :dpi",
        )?;
        ensure_upstream_budget(page_w, page_h, options.dpi, "lower :dpi")?;

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

        for page_index in 0..count {
            let (page_w, page_h) = render_extent(&page_info(doc, page_index)?);
            ensure_render_budget(
                page_w,
                page_h,
                Scale::Dpi(options.dpi as f32 / 72.0),
                1 + sidecar_buffers(doc, page_index),
                None,
                "lower :dpi",
            )?;
            ensure_upstream_budget(page_w, page_h, options.dpi, "lower :dpi")?;
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
        assert!(within_budget(budgeted_pixels(w, h, None), 1));
        let (w, h) = render_dimensions(612.0, 792.0, Scale::Dpi(10_000.0 / 72.0));
        assert!(!within_budget(budgeted_pixels(w, h, None), 1));
        assert!(!within_budget(budgeted_pixels(u64::MAX, u64::MAX, None), 1));
        assert!(!within_budget(
            budgeted_pixels(u64::MAX, u64::MAX, None),
            u64::MAX
        ));
    }

    #[test]
    fn the_budget_counts_every_full_page_buffer() {
        let (w, h) = render_dimensions(612.0, 792.0, Scale::Dpi(600.0 / 72.0));
        let letter_at_600 = budgeted_pixels(w, h, None);
        assert!(within_budget(letter_at_600, 1));
        assert!(!within_budget(letter_at_600, 20));
        assert!(!within_budget(letter_at_600, 1 + 1 + 8));

        // Use a fraction of the cap so this assertion holds on both pointer widths.
        let quarter = MAX_RENDER_PIXELS / 4;
        assert!(within_budget(quarter, 4));
        assert!(!within_budget(quarter, 5));
    }

    #[test]
    fn a_caller_budget_clamps_the_guard_only_when_it_is_given() {
        assert_eq!(budgeted_pixels(1_000, 1_000, None), 1_000_000);
        assert_eq!(budgeted_pixels(1_000, 1_000, Some(4_000)), 4_000);
        assert_eq!(budgeted_pixels(10, 10, Some(4_000)), 100);
        // Upstream floors its budget at one pixel.
        assert_eq!(budgeted_pixels(1_000, 1_000, Some(0)), 1);
        assert_eq!(budgeted_pixels(u64::MAX, u64::MAX, None), u64::MAX);
    }

    #[test]
    fn the_render_box_is_the_crop_box_reduced_to_the_medium() {
        let media = Rect::new(0.0, 0.0, 200.0, 200.0);
        let with_crop = |crop: Option<Rect>| {
            render_box(&PageInfo {
                media_box: media,
                crop_box: crop,
                rotation: 0,
            })
        };

        assert_eq!(with_crop(None), media);
        assert_eq!(
            with_crop(Some(Rect::new(50.0, 40.0, 100.0, 100.0))),
            Rect::new(50.0, 40.0, 100.0, 100.0)
        );
        assert_eq!(
            with_crop(Some(Rect::new(100.0, 100.0, 500.0, 500.0))),
            Rect::new(100.0, 100.0, 100.0, 100.0)
        );
        assert_eq!(with_crop(Some(Rect::new(300.0, 300.0, 50.0, 50.0))), media);
        assert_eq!(with_crop(Some(Rect::new(10.0, 10.0, 0.0, 50.0))), media);
    }

    // Page 0 of `crop_box_fallbacks.pdf` is the only crop box anywhere that
    // leaves the sheet; the skips are the two shapes the public accessor
    // rejects and `get_page_info` fills from its own defaults.
    #[test]
    fn the_render_box_agrees_with_upstreams_public_visible_box() {
        let skip = [("crop_box.pdf", 5), ("crop_box_fallbacks.pdf", 3)];
        let mut compared = 0;

        for name in ["crop_box.pdf", "crop_box_fallbacks.pdf", "media_box.pdf"] {
            let doc = PdfDocument::open(fixture(name)).expect("open");
            let pages = doc.page_count().expect("page count");

            for page in 0..pages {
                let (Ok(info), Ok(visible)) =
                    (doc.get_page_info(page), doc.get_page_visible_box(page))
                else {
                    continue;
                };
                if skip.contains(&(name, page)) {
                    continue;
                }

                let ours = render_box(&info);
                let corners = (ours.x, ours.y, ours.x + ours.width, ours.y + ours.height);
                assert_eq!(corners, visible, "{name} page {page}");
                compared += 1;
            }
        }

        // Every skip above is silent, so without this the loop could go vacuous.
        assert_eq!(compared, 15);
    }

    #[test]
    fn upstream_still_rasters_the_crop_box() {
        let doc = PdfDocument::open(fixture("crop_box.pdf")).expect("open");
        let render = |page| {
            let image = render_page(&doc, page, &RenderOptions::with_dpi(72)).expect("render");
            (image.width, image.height)
        };

        assert_eq!(
            render(0),
            (200, 300),
            "upstream stopped rastering the crop box"
        );
        // Pages 4 and 7 declare none and `null`: the medium is the fallback.
        assert_eq!(render(4), (612, 792));
        assert_eq!(render(7), (612, 792));
    }

    // When this fails the two readers agree and `render_box` becomes that one call.
    #[test]
    fn upstream_still_rasters_a_crop_box_its_public_accessor_rejects() {
        let doc = PdfDocument::open(fixture("crop_box.pdf")).expect("open");
        let rendered = render_page(&doc, 5, &RenderOptions::with_dpi(72)).expect("render");

        // `/CropBox [0 0 100]` is three elements; `get_page_info` fills the
        // fourth from its own default, so the renderer draws 100 pt wide.
        assert_eq!((rendered.width, rendered.height), (100, 792));
        assert_eq!(
            doc.get_page_visible_box(5).expect("visible box"),
            (0.0, 0.0, 612.0, 792.0)
        );
    }

    #[test]
    fn upstream_still_scales_a_fit_render_by_the_media_box() {
        let doc = PdfDocument::open(fixture("cropped_content.pdf")).expect("open");
        let rendered =
            render_page_fit(&doc, 0, 400, 400, &RenderOptions::with_dpi(72)).expect("fit");

        assert_eq!((rendered.width, rendered.height), (200, 200));
    }

    #[test]
    fn the_reduction_threshold_is_upstreams_own_arithmetic() {
        let scale = 2.0 / 72.0;

        assert_eq!(render_dimensions(612.0, 792.0, Scale::Dpi(scale)), (17, 22));
        assert_eq!(upstream_want(612.0, 792.0, scale), (18, 23));

        assert_eq!(upstream_want(612.0, 792.0, 600.0 / 72.0), (5100, 6600));
    }

    // When this fails, `upstream_want` collapses into `render_dimensions`.
    #[test]
    fn upstream_still_reduces_on_the_f64_threshold() {
        let doc = PdfDocument::open(fixture("sample.pdf")).expect("open");
        let render = |cap| {
            let mut options = RenderOptions::with_dpi(2);
            options.max_output_pixels = cap;
            let image = render_page(&doc, 0, &options).expect("render");
            (image.width, image.height)
        };

        // The pixmap is exactly 17x22 = 374 px, so a 374 px budget fits it.
        assert_eq!(
            render_dimensions(612.0, 792.0, Scale::Dpi(2.0 / 72.0)),
            (17, 22)
        );
        assert_eq!(
            render(374),
            (17, 21),
            "upstream now budgets the pixmap it allocates"
        );

        // A budget at the number it does test leaves the page alone.
        assert_eq!(render(414), (17, 22));
    }

    #[test]
    fn a_raster_that_fills_its_budget_exactly_is_still_reduced() {
        let scale = 2.0 / 72.0;
        assert_eq!(render_dimensions(612.0, 792.0, Scale::Dpi(scale)), (17, 22));

        assert!(would_be_reduced(612.0, 792.0, scale, 17 * 22));
        assert!(would_be_reduced(612.0, 792.0, scale, 18 * 23 - 1));
        assert!(!would_be_reduced(612.0, 792.0, scale, 18 * 23));

        assert!(would_be_reduced(612.0, 792.0, scale, 0));
    }

    #[test]
    fn the_unbudgetable_ceiling_is_the_one_upstream_builds_for_itself() {
        assert_eq!(DEFAULT_MAX_OUTPUT_PIXELS, 16_000_000);
        assert_eq!(
            RenderOptions::default().max_output_pixels,
            DEFAULT_MAX_OUTPUT_PIXELS
        );
    }

    #[test]
    fn upstream_still_crops_a_reduced_raster_at_the_requested_dpi() {
        let doc = PdfDocument::open(fixture("sample.pdf")).expect("open");
        let rect = (0.0, 0.0, 100.0, 100.0);

        let mut reduced = RenderOptions::with_dpi(72);
        reduced.max_output_pixels = 10_000;
        let cropped = render_page_region(&doc, 0, rect, &reduced).expect("crop");
        assert_ne!(
            (cropped.width, cropped.height),
            (100, 100),
            "upstream now crops a reduced raster at the scale it rendered"
        );

        // Keep an unreduced control so an unrelated crop failure cannot satisfy the canary.
        let control =
            render_page_region(&doc, 0, rect, &RenderOptions::with_dpi(72)).expect("crop");
        assert_eq!((control.width, control.height), (100, 100));
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

    #[test]
    fn a_mapped_crop_lands_on_the_content_it_names_on_a_cropped_page() {
        let doc = PdfDocument::open(fixture("cropped_content.pdf")).expect("open");
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

        // The visible area is 50,40 .. 150,140 and its left half is filled.
        let inked = crop(Rect::new(50.0, 40.0, 50.0, 100.0));
        let paper = crop(Rect::new(100.0, 40.0, 50.0, 100.0));
        assert_eq!((inked.width(), inked.height()), (50, 100));
        assert!(
            inked.pixels().all(|p| p.0[0] < 128),
            "the crop of the inked half is not all ink"
        );
        assert!(
            paper.pixels().all(|p| p.0[0] == 255),
            "the crop of the empty half is not all paper"
        );
    }

    #[test]
    fn a_crop_rect_outside_the_visible_area_is_off_the_page() {
        let doc = PdfDocument::open(fixture("cropped_content.pdf")).expect("open");
        let info = doc.get_page_info(0).expect("page info");

        // Inside the medium, outside the crop box: no pixels were rendered for it.
        assert!(upstream_crop_rect(&info, 200.0, Rect::new(0.0, 0.0, 40.0, 30.0)).is_none());
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

    // Justifies the cleanup in `document_rasterize`.
    #[test]
    fn upstream_still_leaves_its_page_images_behind_on_failure() {
        let doc = PdfDocument::open(fixture("degenerate_box.pdf")).expect("open");
        let _ = std::fs::remove_dir_all(flatten_temp_dir());

        assert!(
            flatten_to_images(&doc, 18).is_err(),
            "the fixture stopped failing part-way, so nothing here is proven"
        );
        // `create_dir_all` runs before the page loop, so the directory alone
        // survives a failure that wrote nothing and would prove nothing.
        let page_0_left_behind = flatten_temp_dir().join("page_0.png").exists();
        let page_1_written = flatten_temp_dir().join("page_1.png").exists();
        let _ = std::fs::remove_dir_all(flatten_temp_dir());

        assert!(
            !page_1_written,
            "every page rendered, so the loop no longer stops part-way"
        );
        assert!(
            page_0_left_behind,
            "upstream now removes its page images on the error path"
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
}
