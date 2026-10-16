use unicode_segmentation::UnicodeSegmentation;

use crate::base14::Base14;

// A fit test on accumulated f64 positions must not lose a line that fits
// exactly, so a box may cross the bottom margin by this much.
const FIT_TOLERANCE: f64 = 1.0e-6;

// Limit coordinate rounding so distinct lines and runs cannot merge on emission.
const PRECISION_STEPS: f64 = 131_072.0;

pub enum Face {
    Base14(&'static Base14),
}

pub struct Fonts {
    faces: Vec<Face>,
}

impl Fonts {
    pub fn new(faces: Vec<Face>) -> Self {
        Self { faces }
    }

    pub fn name(&self, face: usize) -> &str {
        match self.faces[face] {
            Face::Base14(base14) => base14.name,
        }
    }

    // Widths and metrics are in thousandths of an em. A character no face can
    // draw is refused before layout, so it never reaches here.
    fn char_units(&self, face: usize, c: char) -> f64 {
        match self.faces[face] {
            Face::Base14(base14) => f64::from(base14.width(c).unwrap_or(0)),
        }
    }

    fn width(&self, face: usize, text: &str, size: f64) -> f64 {
        text.chars().map(|c| self.char_units(face, c)).sum::<f64>() * size / 1000.0
    }

    fn ascent_descent(&self, face: usize) -> (f64, f64) {
        match self.faces[face] {
            Face::Base14(base14) => (base14.ascent, base14.descent),
        }
    }
}

pub struct Margins {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
}

pub struct Run {
    pub text: String,
    pub face: usize,
}

pub enum Op {
    Page {
        width: f64,
        height: f64,
    },
    Paragraph {
        runs: Vec<Run>,
        face: usize,
        size: f64,
    },
}

pub struct Placed {
    pub x: f64,
    pub baseline: f64,
    pub width: f64,
    pub text: String,
    pub face: usize,
    pub size: f64,
}

pub struct PagePlan {
    pub width: f64,
    pub height: f64,
    pub placed: Vec<Placed>,
}

pub enum Refused {
    LineTooTall {
        op: usize,
        page: usize,
        line: f64,
        room: f64,
    },
    NoWidth {
        op: usize,
        page: usize,
    },
    ClusterTooWide {
        op: usize,
        page: usize,
        cluster: String,
        width: f64,
        room: f64,
    },
    Imprecise {
        op: usize,
        page: usize,
        size: f64,
    },
}

pub fn lay_out(
    fonts: &Fonts,
    margins: &Margins,
    line_height: f64,
    first_page: (f64, f64),
    ops: &[Op],
) -> Result<Vec<PagePlan>, Refused> {
    let mut layout = Layout {
        fonts,
        margins,
        line_height,
        first_page,
        pages: Vec::new(),
        cursor: 0.0,
        fresh: true,
        pending_space: 0.0,
    };

    for (index, op) in ops.iter().enumerate() {
        match op {
            Op::Page { width, height } => layout.new_page(*width, *height),
            Op::Paragraph { runs, face, size } => layout.paragraph(index, runs, *face, *size)?,
        }
    }

    layout.ensure_page();
    Ok(layout.pages)
}

struct Layout<'a> {
    fonts: &'a Fonts,
    margins: &'a Margins,
    line_height: f64,
    first_page: (f64, f64),
    pages: Vec<PagePlan>,
    // Top of the next line box.
    cursor: f64,
    // No line has been placed on the current page yet.
    fresh: bool,
    // Space owed after the previous block, dropped if a page break comes first.
    pending_space: f64,
}

impl Layout<'_> {
    fn ensure_page(&mut self) {
        if self.pages.is_empty() {
            let (width, height) = self.first_page;
            self.new_page(width, height);
        }
    }

    fn page(&self) -> &PagePlan {
        self.pages
            .last()
            .expect("a page exists once ensure_page has run")
    }

    fn new_page(&mut self, width: f64, height: f64) {
        self.pages.push(PagePlan {
            width,
            height,
            placed: Vec::new(),
        });
        self.cursor = height - self.margins.top;
        self.fresh = true;
        self.pending_space = 0.0;
    }

    fn break_page(&mut self) {
        let (width, height) = (self.page().width, self.page().height);
        self.new_page(width, height);
    }

    fn paragraph(
        &mut self,
        op: usize,
        runs: &[Run],
        face: usize,
        size: f64,
    ) -> Result<(), Refused> {
        self.ensure_page();

        let page = self.page();
        let page_index = self.pages.len() - 1;
        // Spelled as the Elixir check spells it, so both refuse the same lines.
        let line = size * self.line_height;
        let room = page.height - self.margins.top - self.margins.bottom;
        if line > room {
            return Err(Refused::LineTooTall {
                op,
                page: page_index,
                line,
                room,
            });
        }

        // Spelled as the Elixir check spells it too.
        if page.width.max(page.height) > size.min(line) * PRECISION_STEPS {
            return Err(Refused::Imprecise {
                op,
                page: page_index,
                size,
            });
        }

        let max_width = page.width - self.margins.left - self.margins.right;
        if max_width <= 0.0 {
            return Err(Refused::NoWidth {
                op,
                page: page_index,
            });
        }

        let (ascent, descent) = self.fonts.ascent_descent(face);
        let half_leading = (line - (ascent - descent) * size / 1000.0) / 2.0;
        let above_baseline = half_leading + ascent * size / 1000.0;

        let lines = wrap(self.fonts, runs, size, max_width).map_err(|(cluster, width)| {
            Refused::ClusterTooWide {
                op,
                page: page_index,
                cluster,
                width,
                room: max_width,
            }
        })?;

        for wrapped in lines {
            self.place_line(line, above_baseline, wrapped, size);
        }

        self.pending_space = 0.5 * size;
        Ok(())
    }

    fn fits(&self, top: f64, line: f64) -> bool {
        top - line >= self.margins.bottom - FIT_TOLERANCE
    }

    fn place_line(&mut self, line: f64, above_baseline: f64, segments: Vec<Segment>, size: f64) {
        if !self.fresh {
            let spaced = self.cursor - self.pending_space;
            self.pending_space = 0.0;
            // A page never breaks before its first line, so a line the refusal
            // above let through always lands somewhere.
            if self.fits(spaced, line) {
                self.cursor = spaced;
            } else {
                self.break_page();
            }
        }

        let baseline = self.cursor - above_baseline;
        let left = self.margins.left;
        let page = self.pages.last_mut().expect("paragraph ensured a page");
        let mut x = left;
        for segment in segments {
            let width = segment.width;
            page.placed.push(Placed {
                x,
                baseline,
                width,
                text: segment.text,
                face: segment.face,
                size,
            });
            x += width;
        }

        self.cursor -= line;
        self.fresh = false;
    }
}

struct Segment {
    text: String,
    face: usize,
    width: f64,
}

enum Token {
    Word(Vec<Run>),
    Space(usize),
    Break,
}

fn tokens(runs: &[Run]) -> Vec<Token> {
    let mut out = Vec::new();
    let mut word: Vec<Run> = Vec::new();

    let flush = |word: &mut Vec<Run>, out: &mut Vec<Token>| {
        if !word.is_empty() {
            out.push(Token::Word(std::mem::take(word)));
        }
    };

    for run in runs {
        for c in run.text.chars() {
            if c == '\n' {
                flush(&mut word, &mut out);
                out.push(Token::Break);
            } else if c.is_whitespace() {
                flush(&mut word, &mut out);
                if !matches!(out.last(), Some(Token::Space(_))) {
                    out.push(Token::Space(run.face));
                }
            } else {
                match word.last_mut() {
                    Some(piece) if piece.face == run.face => piece.text.push(c),
                    _ => word.push(Run {
                        text: c.to_string(),
                        face: run.face,
                    }),
                }
            }
        }
    }
    flush(&mut word, &mut out);

    out
}

#[derive(Default)]
struct Line {
    pieces: Vec<Run>,
    width: f64,
}

impl Line {
    fn push(&mut self, fonts: &Fonts, piece: Run, size: f64) {
        self.width += fonts.width(piece.face, &piece.text, size);
        match self.pieces.last_mut() {
            Some(last) if last.face == piece.face => last.text.push_str(&piece.text),
            _ => self.pieces.push(piece),
        }
    }

    fn segments(self, fonts: &Fonts, size: f64) -> Vec<Segment> {
        self.pieces
            .into_iter()
            .map(|piece| Segment {
                width: fonts.width(piece.face, &piece.text, size),
                text: piece.text,
                face: piece.face,
            })
            .collect()
    }
}

// Greedy filling: words separated by collapsed whitespace, `\n` a hard break,
// and a word wider than the line split between clusters.
// A cluster wider than the line is the error, with its width.
type TooWide = (String, f64);

fn wrap(
    fonts: &Fonts,
    runs: &[Run],
    size: f64,
    max_width: f64,
) -> Result<Vec<Vec<Segment>>, TooWide> {
    let mut lines = Vec::new();
    let mut line = Line::default();
    let mut space: Option<usize> = None;

    let finish = |line: &mut Line, lines: &mut Vec<Vec<Segment>>| {
        lines.push(std::mem::take(line).segments(fonts, size));
    };

    for token in tokens(runs) {
        match token {
            Token::Break => {
                finish(&mut line, &mut lines);
                space = None;
            }
            Token::Space(face) => {
                if !line.pieces.is_empty() {
                    space = Some(face);
                }
            }
            Token::Word(pieces) => {
                let width: f64 = pieces
                    .iter()
                    .map(|p| fonts.width(p.face, &p.text, size))
                    .sum();
                let space_width = space.map_or(0.0, |face| fonts.width(face, " ", size));

                if !line.pieces.is_empty() && line.width + space_width + width <= max_width {
                    if let Some(face) = space {
                        line.push(
                            fonts,
                            Run {
                                text: " ".into(),
                                face,
                            },
                            size,
                        );
                    }
                    for piece in pieces {
                        line.push(fonts, piece, size);
                    }
                } else {
                    if !line.pieces.is_empty() {
                        finish(&mut line, &mut lines);
                    }
                    if width <= max_width {
                        for piece in pieces {
                            line.push(fonts, piece, size);
                        }
                    } else {
                        for chunk in split_word(fonts, pieces, size, max_width)? {
                            if !line.pieces.is_empty() {
                                finish(&mut line, &mut lines);
                            }
                            for piece in chunk {
                                line.push(fonts, piece, size);
                            }
                        }
                    }
                }
                space = None;
            }
        }
    }

    if !line.pieces.is_empty() {
        finish(&mut line, &mut lines);
    }

    Ok(lines)
}

fn split_word(
    fonts: &Fonts,
    pieces: Vec<Run>,
    size: f64,
    max_width: f64,
) -> Result<Vec<Vec<Run>>, TooWide> {
    let mut chunks: Vec<Vec<Run>> = Vec::new();
    let mut chunk: Vec<Run> = Vec::new();
    let mut width = 0.0;

    for piece in pieces {
        // Extended grapheme clusters, so an accent stays with its letter and an
        // emoji sequence stays whole.
        for cluster in piece.text.graphemes(true) {
            let cluster_width = fonts.width(piece.face, cluster, size);
            if cluster_width > max_width {
                return Err((cluster.to_string(), cluster_width));
            }
            if !chunk.is_empty() && width + cluster_width > max_width {
                chunks.push(std::mem::take(&mut chunk));
                width = 0.0;
            }
            width += cluster_width;
            match chunk.last_mut() {
                Some(last) if last.face == piece.face => last.text.push_str(cluster),
                _ => chunk.push(Run {
                    text: cluster.to_string(),
                    face: piece.face,
                }),
            }
        }
    }
    if !chunk.is_empty() {
        chunks.push(chunk);
    }

    Ok(chunks)
}
