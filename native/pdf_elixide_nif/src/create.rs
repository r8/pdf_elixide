use std::panic::{catch_unwind, AssertUnwindSafe};

use pdf_oxide::{
    api::{Pdf, PdfBuilder, PdfConfig},
    editor::DocumentEditor,
    error::Result,
    fonts::encoding::unicode_to_winansi,
    writer::PageSize,
};
use rustler::{NifMap, NifResult, NifUnitEnum, NifUntaggedEnum};

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

fn layout(
    title: Option<String>,
    author: Option<String>,
    page_size: PageSizeNif,
    margin_top: f32,
    margin_bottom: f32,
    margin_left: f32,
    line_height: f32,
) -> PdfBuilder {
    // No layout reads the right margin; pass the default so `margins` can set
    // the three that are read.
    let margin_right = PdfConfig::default().margin_right;
    let mut builder = PdfBuilder::new()
        .page_size(page_size.into())
        .margins(margin_left, margin_right, margin_top, margin_bottom)
        .line_height(line_height);

    if let Some(title) = title {
        builder = builder.title(title);
    }
    if let Some(author) = author {
        builder = builder.author(author);
    }

    builder
}

impl MarkupCreateOptionsNif {
    fn builder(self) -> PdfBuilder {
        let builder = layout(
            self.title,
            self.author,
            self.page_size,
            self.margin_top,
            self.margin_bottom,
            self.margin_left,
            self.line_height,
        )
        .font_size(self.font_size);

        match self.subject {
            Some(subject) => builder.subject(subject),
            None => builder,
        }
    }
}

impl PlainTextCreateOptionsNif {
    fn builder(self) -> PdfBuilder {
        layout(
            self.title,
            self.author,
            self.page_size,
            self.margin_top,
            self.margin_bottom,
            self.margin_left,
            self.line_height,
        )
        // Plain text spaces its lines by the font size but always draws 12-point
        // glyphs; setting 12 keeps the spacing the Elixir fit check assumes.
        .font_size(12.0)
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
fn create(build: impl FnOnce() -> Result<Pdf>) -> NifResult<OpenedEditor> {
    let editor = warnings::drained(|| {
        catch_unwind(AssertUnwindSafe(|| {
            let bytes = build().map_err(to_nif_err)?.into_bytes();

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
    create(|| options.builder().from_markdown(content))
}

// Dirty for the same reason as `editor_from_markdown`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_from_html(content: &str, options: MarkupCreateOptionsNif) -> NifResult<OpenedEditor> {
    create(|| options.builder().from_html(content))
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

    create(|| options.builder().from_text(&blank_lines_drawn(content)))
}

#[cfg(test)]
mod tests {
    use pdf_oxide::PdfDocument;

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
}
