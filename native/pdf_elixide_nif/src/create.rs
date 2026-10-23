use std::{
    collections::HashMap,
    hash::{DefaultHasher, Hash, Hasher},
    io::Cursor,
};

use image::{
    codecs::{jpeg::JpegDecoder, png::PngDecoder},
    ImageDecoder, Limits,
};
use pdf_oxide::{
    api::{Pdf, PdfBuilder, PdfConfig},
    editor::DocumentEditor,
    extractors::{self, PdfImage},
    fonts::encoding::unicode_to_winansi,
    writer::{ColorSpace, ImageData, ImageFormat, PageSize},
};
use rustler::{Binary, NifMap, NifResult, NifUnitEnum, NifUntaggedEnum};

use crate::{
    atoms,
    editor::{opened, OpenedEditor},
    error::{tagged_err, to_nif_err},
    warnings,
};

#[derive(NifUnitEnum, Debug, Clone, Copy)]
pub enum PaperNif {
    Letter,
    A4,
    Legal,
    A3,
}

#[derive(NifUntaggedEnum, Debug)]
pub enum PageSizeNif {
    Paper(PaperNif),
    Custom((f32, f32)),
}

impl From<PageSizeNif> for PageSize {
    fn from(size: PageSizeNif) -> Self {
        match size {
            PageSizeNif::Paper(PaperNif::Letter) => PageSize::Letter,
            PageSizeNif::Paper(PaperNif::A4) => PageSize::A4,
            PageSizeNif::Paper(PaperNif::Legal) => PageSize::Legal,
            PageSizeNif::Paper(PaperNif::A3) => PageSize::A3,
            PageSizeNif::Custom((width, height)) => PageSize::Custom(width, height),
        }
    }
}

#[derive(NifMap, Debug)]
pub struct MarkupCreateOptionsNif {
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
    page_size: PageSizeNif,
    margin_top: f32,
    margin_bottom: f32,
    margin_left: f32,
    font_size: f32,
    line_height: f32,
}

#[derive(NifMap, Debug)]
pub struct PlainTextCreateOptionsNif {
    title: Option<String>,
    author: Option<String>,
    page_size: PageSizeNif,
    margin_top: f32,
    margin_bottom: f32,
    margin_left: f32,
    line_height: f32,
}

#[derive(NifMap, Debug)]
pub struct ImageCreateOptionsNif {
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
    page_size: PageSizeNif,
    margin_top: f32,
    margin_bottom: f32,
    margin_left: f32,
    margin_right: f32,
}

fn described(
    mut builder: PdfBuilder,
    title: Option<String>,
    author: Option<String>,
    subject: Option<String>,
) -> PdfBuilder {
    if let Some(title) = title {
        builder = builder.title(title);
    }
    if let Some(author) = author {
        builder = builder.author(author);
    }
    if let Some(subject) = subject {
        builder = builder.subject(subject);
    }

    builder
}

fn layout(
    page_size: PageSizeNif,
    margin_top: f32,
    margin_bottom: f32,
    margin_left: f32,
    line_height: f32,
) -> PdfBuilder {
    // No text layout reads the right margin; pass the default so `margins` can set
    // the ones that are read.
    let margin_right = PdfConfig::default().margin_right;
    PdfBuilder::new()
        .page_size(page_size.into())
        .margins(margin_left, margin_right, margin_top, margin_bottom)
        .line_height(line_height)
}

impl MarkupCreateOptionsNif {
    fn builder(self) -> PdfBuilder {
        let builder = layout(
            self.page_size,
            self.margin_top,
            self.margin_bottom,
            self.margin_left,
            self.line_height,
        )
        .font_size(self.font_size);

        described(builder, self.title, self.author, self.subject)
    }
}

impl PlainTextCreateOptionsNif {
    fn builder(self) -> PdfBuilder {
        let builder = layout(
            self.page_size,
            self.margin_top,
            self.margin_bottom,
            self.margin_left,
            self.line_height,
        )
        // Plain text spaces its lines by the font size but always draws 12-point
        // glyphs; setting 12 keeps the spacing the Elixir fit check assumes.
        .font_size(12.0);

        described(builder, self.title, self.author, None)
    }
}

impl ImageCreateOptionsNif {
    fn builder(self) -> PdfBuilder {
        let builder = PdfBuilder::new().page_size(self.page_size.into()).margins(
            self.margin_left,
            self.margin_right,
            self.margin_top,
            self.margin_bottom,
        );

        described(builder, self.title, self.author, self.subject)
    }
}

// Refuse characters the unembedded plain-text font would silently replace.
fn first_unrenderable(content: &str) -> Option<char> {
    content
        .chars()
        .find(|&c| unicode_to_winansi(u32::from(c)).is_none())
}

// Invisible spaces make blank lines participate in page breaking; trailing
// blanks stay dropped so they do not add a page.
fn blank_lines_drawn(content: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let end = lines
        .iter()
        .rposition(|line| !line.is_empty())
        .map_or(0, |i| i + 1);

    lines[..end]
        .iter()
        .map(|line| if line.is_empty() { " " } else { line })
        .collect::<Vec<_>>()
        .join("\n")
}

// There is no `Closable` until the editor exists, so `warnings::drained`
// contains a panic in the layout or the parse of its output.
fn create(build: impl FnOnce() -> NifResult<Pdf>) -> NifResult<OpenedEditor> {
    create_from_bytes(|| build().map(Pdf::into_bytes))
}

pub(crate) fn create_from_bytes(
    build: impl FnOnce() -> NifResult<Vec<u8>>,
) -> NifResult<OpenedEditor> {
    let editor = warnings::drained(|| {
        let bytes = build()?;

        DocumentEditor::from_bytes(bytes).map_err(to_nif_err)
    })?;

    opened(editor)
}

// Dirty because laying out a whole document and parsing the result is
// CPU-bound; the only lock taken is the new handle's, which nothing else holds.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_markdown(content: &str, options: MarkupCreateOptionsNif) -> NifResult<OpenedEditor> {
    create(|| options.builder().from_markdown(content).map_err(to_nif_err))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_html(content: &str, options: MarkupCreateOptionsNif) -> NifResult<OpenedEditor> {
    create(|| options.builder().from_html(content).map_err(to_nif_err))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_plain_text(
    content: &str,
    options: PlainTextCreateOptionsNif,
) -> NifResult<OpenedEditor> {
    if let Some(c) = first_unrenderable(content) {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "plain text cannot contain {c:?} (U+{:04X}): only Windows-1252 characters \
                 can be rendered; from_markdown/2 embeds a font covering Greek and Cyrillic",
                u32::from(c)
            ),
        ));
    }

    create(|| {
        options
            .builder()
            .from_text(&blank_lines_drawn(content))
            .map_err(to_nif_err)
    })
}

// Decoding holds several copies of an image's pixels, and an allocation failure
// aborts the node; these caps keep the peak near the one a render may reach.
const MAX_IMAGE_PIXELS: u64 = if usize::BITS >= 64 {
    128_000_000
} else {
    32_000_000
};

// Reads the header only, under the limits `from_png` decodes with.
fn png_header(bytes: &[u8]) -> Option<(u32, u32, u64)> {
    PngDecoder::with_limits(Cursor::new(bytes), Limits::default())
        .ok()
        .map(|decoder| {
            let (width, height) = decoder.dimensions();
            (width, height, decoder.total_bytes())
        })
}

fn ensure_pixel_budget(what: &str, width: u32, height: u32) -> NifResult<()> {
    if u64::from(width) * u64::from(height) > MAX_IMAGE_PIXELS {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "{what} is {width} × {height} pixels, over the {MAX_IMAGE_PIXELS} \
                 pixel limit; scale it down"
            ),
        ));
    }

    Ok(())
}

// The decode reserves its whole buffer against this limit before reading a
// pixel, so this keeps a 16-bit color PNG under the pixel cap `:unsupported`.
fn ensure_png_buffer(what: &str, width: u32, height: u32, total_bytes: u64) -> NifResult<()> {
    let max_alloc = Limits::default().max_alloc.unwrap_or(u64::MAX);

    if total_bytes > max_alloc {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "{what} is {width} × {height} pixels, {total_bytes} bytes decoded, \
                 over the {max_alloc} byte limit; scale it down"
            ),
        ));
    }

    Ok(())
}

// The writer labels every JPEG 8-bit, and a header parse stops at the first
// scan, so the whole image is decoded here the way extraction will decode it.
fn ensure_jpeg_readable(what: &str, image: &ImageData) -> NifResult<()> {
    let unreadable = |e: &dyn std::fmt::Display| tagged_err(atoms::other(), format!("{what}: {e}"));

    ensure_pixel_budget(what, image.width, image.height)?;
    JpegDecoder::new(Cursor::new(&image.data)).map_err(|e| unreadable(&e))?;

    let color_space = match image.color_space {
        ColorSpace::DeviceGray => extractors::ColorSpace::DeviceGray,
        ColorSpace::DeviceRGB => extractors::ColorSpace::DeviceRGB,
        ColorSpace::DeviceCMYK => extractors::ColorSpace::DeviceCMYK,
    };
    PdfImage::new(
        image.width,
        image.height,
        color_space,
        8,
        extractors::ImageData::Jpeg(image.data.clone()),
    )
    .to_dynamic_image()
    .map(drop)
    .map_err(|e| unreadable(&e))
}

// Dispatching on the signature here, rather than through `from_bytes`, keeps an
// unrecognized format apart from a damaged image: the two share an error type
// the crate does not export.
pub(crate) fn decoded(what: &str, bytes: &[u8]) -> NifResult<ImageData> {
    let image = if bytes.starts_with(&[0xFF, 0xD8]) {
        ImageData::from_jpeg(bytes.to_vec())
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        if let Some((width, height, total_bytes)) = png_header(bytes) {
            ensure_pixel_budget(what, width, height)?;
            ensure_png_buffer(what, width, height, total_bytes)?;
        }
        ImageData::from_png(bytes)
    } else {
        return Err(tagged_err(
            atoms::unsupported(),
            format!("{what} is neither JPEG nor PNG"),
        ));
    }
    .map_err(|e| tagged_err(atoms::other(), format!("{what}: {e}")))?;

    // A zero dimension makes the page layout divide by zero.
    if image.width == 0 || image.height == 0 {
        return Err(tagged_err(
            atoms::other(),
            format!(
                "{what}: has no area ({} × {} pixels)",
                image.width, image.height
            ),
        ));
    }

    if image.format == ImageFormat::Jpeg {
        ensure_jpeg_readable(what, &image)?;
    }

    Ok(image)
}

// The writer merges images whose compressed samples are equal, whatever their
// size, color space or mask, so each different image sharing an earlier one's
// samples is numbered in no-op deflate blocks.
pub(crate) fn keep_apart<'a>(images: impl IntoIterator<Item = &'a mut ImageData>) {
    let mut numbers: HashMap<(Fingerprint, Shape), usize> = HashMap::new();
    let mut next: HashMap<Fingerprint, usize> = HashMap::new();
    let mut taken: HashMap<Fingerprint, (Fingerprint, Shape)> = HashMap::new();

    for image in images {
        if image.format != ImageFormat::Png || image.data.len() < 2 {
            continue;
        }
        let samples = fingerprint(&image.data);
        let owner = (samples, Shape::of(image));

        let number = if let Some(&number) = numbers.get(&owner) {
            number
        } else {
            loop {
                let counter = next.entry(samples).or_insert(0);
                let number = *counter;
                *counter += 1;
                let key = match number {
                    0 => samples,
                    _ => fingerprint(&numbered(&image.data, number)),
                };
                if taken.get(&key).is_none_or(|holder| *holder == owner) {
                    taken.insert(key, owner);
                    numbers.insert(owner, number);
                    break number;
                }
            }
        };
        if number > 0 {
            image.data = numbered(&image.data, number);
        }
    }
}

type Fingerprint = (u64, usize);

fn fingerprint(bytes: &[u8]) -> Fingerprint {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    (hasher.finish(), bytes.len())
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct Shape {
    width: u32,
    height: u32,
    color_space: u8,
    bits_per_component: u8,
    mask: Option<Fingerprint>,
}

impl Shape {
    fn of(image: &ImageData) -> Self {
        Shape {
            width: image.width,
            height: image.height,
            color_space: match image.color_space {
                ColorSpace::DeviceGray => 0,
                ColorSpace::DeviceRGB => 1,
                ColorSpace::DeviceCMYK => 2,
            },
            bits_per_component: image.bits_per_component,
            mask: image.soft_mask.as_deref().map(fingerprint),
        }
    }
}

// A 1 is an empty fixed-Huffman block then an empty stored block, a 0 the
// stored block alone; both end on a byte boundary and open with different
// bytes, so each number gives different bytes.
fn numbered(data: &[u8], number: usize) -> Vec<u8> {
    const ONE: [u8; 6] = [0x02, 0x00, 0x00, 0x00, 0xFF, 0xFF];
    const ZERO: [u8; 5] = [0x00, 0x00, 0x00, 0xFF, 0xFF];

    let digits = usize::BITS - number.leading_zeros();
    let mut out = Vec::with_capacity(data.len() + 6 * digits as usize);
    out.extend_from_slice(&data[..2]);
    for digit in (0..digits).rev() {
        if number >> digit & 1 == 1 {
            out.extend_from_slice(&ONE);
        } else {
            out.extend_from_slice(&ZERO);
        }
    }
    out.extend_from_slice(&data[2..]);
    out
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_images(
    images: Vec<Binary>,
    options: ImageCreateOptionsNif,
) -> NifResult<OpenedEditor> {
    create(|| {
        let mut images = images
            .iter()
            .enumerate()
            .map(|(index, bytes)| decoded(&format!("image {index}"), bytes.as_slice()))
            .collect::<NifResult<Vec<_>>>()?;
        keep_apart(&mut images);

        options
            .builder()
            .from_image_data_multiple(images)
            .map_err(to_nif_err)
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{error::Result, fonts::bundled::DEJAVU_SANS, PdfDocument};

    use super::*;
    use crate::metadata::read_metadata;

    fn reopened(pdf: Result<Pdf>) -> PdfDocument {
        PdfDocument::from_bytes(pdf.expect("layout succeeds").into_bytes()).expect("output parses")
    }

    fn solid_png<P: image::PixelWithColorType<Subpixel = u8>>(
        width: u32,
        height: u32,
        pixel: P,
    ) -> ImageData
    where
        [u8]: image::EncodableLayout,
    {
        let mut png = std::io::Cursor::new(Vec::new());
        image::ImageBuffer::from_pixel(width, height, pixel)
            .write_to(&mut png, image::ImageFormat::Png)
            .expect("png encodes");
        ImageData::from_png(png.get_ref()).expect("png decodes")
    }

    fn count(pdf: &[u8], needle: &[u8]) -> usize {
        pdf.windows(needle.len())
            .filter(|window| *window == needle)
            .count()
    }

    #[test]
    fn upstream_still_dedups_images_by_their_samples_alone() {
        let opaque = solid_png(8, 8, image::Rgb([128, 128, 128]));
        let transparent = solid_png(8, 8, image::Rgba([128, 128, 128, 128]));
        let pdf = PdfBuilder::new()
            .from_image_data_multiple(vec![opaque, transparent])
            .expect("layout succeeds")
            .into_bytes();

        assert_eq!(count(&pdf, b"/Subtype /Image"), 1);
        assert_eq!(count(&pdf, b"/SMask"), 0);
    }

    #[test]
    fn keep_apart_separates_only_different_images_with_equal_samples() {
        let opaque = solid_png(8, 8, image::Rgb([128, 128, 128]));
        let transparent = solid_png(8, 8, image::Rgba([128, 128, 128, 128]));
        let wide_gray = solid_png(24, 8, image::Luma([128]));
        let mut images = vec![
            opaque.clone(),
            transparent.clone(),
            opaque.clone(),
            wide_gray,
            transparent,
        ];
        assert!(images.iter().all(|image| image.data == opaque.data));

        keep_apart(&mut images);

        assert_eq!(images[0].data, opaque.data);
        assert_eq!(images[2].data, opaque.data);
        assert_ne!(images[1].data, opaque.data);
        assert_ne!(images[3].data, opaque.data);
        assert_ne!(images[3].data, images[1].data);
        assert_eq!(images[4].data, images[1].data);
        assert_eq!(images[3].data[..2], opaque.data[..2]);
    }

    #[test]
    fn keep_apart_numbers_variants_in_binary() {
        let base = solid_png(8, 8, image::Rgb([128, 128, 128]));
        let mut images: Vec<ImageData> = (1..=1024)
            .map(|width| ImageData {
                width,
                ..base.clone()
            })
            .collect();

        keep_apart(&mut images);

        let distinct: std::collections::HashSet<&[u8]> =
            images.iter().map(|image| image.data.as_slice()).collect();
        let longest = images.iter().map(|image| image.data.len()).max();
        assert_eq!(distinct.len(), 1024);
        assert_eq!(longest, Some(base.data.len() + 10 * 6));
    }

    #[test]
    fn upstream_still_ignores_keywords() {
        let doc = reopened(PdfBuilder::new().keywords("kw").from_markdown("Hello"));

        assert_eq!(read_metadata(&doc).keywords, None);
    }

    #[test]
    fn upstream_still_ignores_keywords_on_images() {
        let mut png = std::io::Cursor::new(Vec::new());
        image::GrayImage::new(1, 1)
            .write_to(&mut png, image::ImageFormat::Png)
            .expect("png encodes");
        let image = ImageData::from_png(png.get_ref()).expect("png decodes");
        let doc = reopened(
            PdfBuilder::new()
                .keywords("kw")
                .from_image_data_multiple(vec![image]),
        );

        assert_eq!(read_metadata(&doc).keywords, None);
    }

    #[test]
    fn upstream_still_writes_cmyk_jpeg_without_decode() {
        // Just enough of a JPEG for its frame header to read as four components.
        let mut jpeg = vec![
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x14, 0x08, 0x00, 0x01, 0x00, 0x01, 0x04,
        ];
        jpeg.resize(32, 0);
        let image = ImageData::from_jpeg(jpeg).expect("header parses");
        let pdf = PdfBuilder::new()
            .from_image_data_multiple(vec![image])
            .expect("layout succeeds")
            .into_bytes();
        let has = |needle: &[u8]| pdf.windows(needle.len()).any(|w| w == needle);

        assert!(has(b"/DeviceCMYK"));
        assert!(!has(b"/Decode ") && !has(b"/Decode["));
    }

    #[test]
    fn upstream_still_ignores_the_right_margin() {
        let chars = |right| {
            let doc = reopened(
                PdfBuilder::new()
                    .margins(72.0, right, 72.0, 72.0)
                    .from_markdown(&"word ".repeat(60)),
            );

            doc.extract_chars(0)
                .expect("chars extract")
                .iter()
                .map(|c| (c.bbox.x, c.bbox.y))
                .collect::<Vec<_>>()
        };

        assert_eq!(chars(0.0), chars(500.0));
    }

    #[test]
    fn upstream_still_ignores_font_size_on_plain_text() {
        let doc = reopened(PdfBuilder::new().font_size(30.0).from_text("Hello"));
        let chars = doc.extract_chars(0).expect("chars extract");

        assert!(chars.iter().all(|c| c.font_size == 12.0), "{chars:?}");
    }

    #[test]
    fn upstream_still_drops_subject_on_plain_text() {
        let doc = reopened(PdfBuilder::new().subject("subj").from_text("Hello"));

        assert_eq!(read_metadata(&doc).subject, None);
    }

    #[test]
    fn upstream_still_stacks_plain_text_after_a_page_of_blank_lines() {
        let doc = reopened(PdfBuilder::new().from_text(&format!("a{}b", "\n".repeat(36))));

        assert_eq!(doc.page_count().expect("page count reads"), 1);
    }

    #[test]
    fn upstream_still_writes_question_marks_for_plain_text_outside_win_ansi() {
        let doc = reopened(PdfBuilder::new().from_text("Привет"));

        assert_eq!(doc.extract_text(0).expect("text extracts").trim(), "??????");
    }

    #[test]
    fn upstream_still_draws_inline_runs_at_one_origin() {
        let fonts = vec![(String::from("Body"), DEJAVU_SANS.to_vec())];
        let doc = reopened(Pdf::from_html_css_with_fonts(
            "<p>Hello <b>world</b></p>",
            "",
            fonts,
        ));
        let chars = doc.extract_chars(0).expect("chars extract");
        let x_of = |ch| chars.iter().find(|c| c.char == ch).map(|c| c.bbox.x);

        assert_eq!(
            x_of('H').expect("Hello is drawn"),
            x_of('w').expect("world is drawn")
        );
    }
}
