use std::{
    io::Cursor,
    panic::{catch_unwind, AssertUnwindSafe},
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
    error::{panic_err, tagged_err, to_nif_err},
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
    // the three that are read.
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

// There is no `Closable` until the editor exists, so `catch_unwind` contains a
// panic in the layout or the parse of its output.
fn create(build: impl FnOnce() -> NifResult<Pdf>) -> NifResult<OpenedEditor> {
    let editor = warnings::drained(|| {
        catch_unwind(AssertUnwindSafe(|| {
            let bytes = build()?.into_bytes();

            DocumentEditor::from_bytes(bytes).map_err(to_nif_err)
        }))
        .unwrap_or_else(|payload| Err(panic_err(&*payload)))
    })?;

    opened(editor)
}

// Dirty because laying out a whole document and parsing the result is
// CPU-bound; the only lock taken is the new handle's, which nothing else holds.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_markdown(content: &str, options: MarkupCreateOptionsNif) -> NifResult<OpenedEditor> {
    create(|| options.builder().from_markdown(content).map_err(to_nif_err))
}

// Dirty for the same reason as `editor_from_markdown`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_html(content: &str, options: MarkupCreateOptionsNif) -> NifResult<OpenedEditor> {
    create(|| options.builder().from_html(content).map_err(to_nif_err))
}

// Dirty for the same reason as `editor_from_markdown`.
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

fn ensure_pixel_budget(index: usize, width: u32, height: u32) -> NifResult<()> {
    if u64::from(width) * u64::from(height) > MAX_IMAGE_PIXELS {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "image {index} is {width} × {height} pixels, over the {MAX_IMAGE_PIXELS} \
                 pixel limit; scale it down"
            ),
        ));
    }

    Ok(())
}

// The decode reserves its whole buffer against this limit before reading a
// pixel, so this keeps a 16-bit colour PNG under the pixel cap `:unsupported`.
fn ensure_png_buffer(index: usize, width: u32, height: u32, total_bytes: u64) -> NifResult<()> {
    let max_alloc = Limits::default().max_alloc.unwrap_or(u64::MAX);

    if total_bytes > max_alloc {
        return Err(tagged_err(
            atoms::unsupported(),
            format!(
                "image {index} is {width} × {height} pixels, {total_bytes} bytes decoded, \
                 over the {max_alloc} byte limit; scale it down"
            ),
        ));
    }

    Ok(())
}

// The writer labels every JPEG 8-bit, and a header parse stops at the first
// scan, so the whole image is decoded here the way extraction will decode it.
fn ensure_jpeg_readable(index: usize, image: &ImageData) -> NifResult<()> {
    let unreadable =
        |e: &dyn std::fmt::Display| tagged_err(atoms::other(), format!("image {index}: {e}"));

    ensure_pixel_budget(index, image.width, image.height)?;
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
// unrecognised format apart from a damaged image: the two share an error type
// the crate does not export.
fn decoded(index: usize, bytes: &[u8]) -> NifResult<ImageData> {
    let image = if bytes.starts_with(&[0xFF, 0xD8]) {
        ImageData::from_jpeg(bytes.to_vec())
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        if let Some((width, height, total_bytes)) = png_header(bytes) {
            ensure_pixel_budget(index, width, height)?;
            ensure_png_buffer(index, width, height, total_bytes)?;
        }
        ImageData::from_png(bytes)
    } else {
        return Err(tagged_err(
            atoms::unsupported(),
            format!("image {index} is neither JPEG nor PNG"),
        ));
    }
    .map_err(|e| tagged_err(atoms::other(), format!("image {index}: {e}")))?;

    // A zero dimension makes the page layout divide by zero.
    if image.width == 0 || image.height == 0 {
        return Err(tagged_err(
            atoms::other(),
            format!(
                "image {index}: has no area ({} × {} pixels)",
                image.width, image.height
            ),
        ));
    }

    if image.format == ImageFormat::Jpeg {
        ensure_jpeg_readable(index, &image)?;
    }

    Ok(image)
}

// Dirty for the same reason as `editor_from_markdown`, with PNG decoding and
// compression on top.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_images(
    images: Vec<Binary>,
    options: ImageCreateOptionsNif,
) -> NifResult<OpenedEditor> {
    create(|| {
        let images = images
            .iter()
            .enumerate()
            .map(|(index, bytes)| decoded(index, bytes.as_slice()))
            .collect::<NifResult<Vec<_>>>()?;

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
