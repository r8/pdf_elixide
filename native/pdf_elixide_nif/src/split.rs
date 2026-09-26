use std::collections::{HashMap, HashSet};

use pdf_oxide::{
    error::Result,
    filename::{slugify_title_with, DEFAULT_MAX_SLUG_BYTES},
    split_bookmarks::{
        build_segments, collect_split_points, flatten_outline, BookmarkLevel, BookmarkSegment,
        SplitByBookmarksOptions,
    },
    OutlineItem, PdfDocument,
};
use rustler::{NifMap, NifResult};
use unicode_normalization::UnicodeNormalization;

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
    outline::{check_depth, too_deep, TooDeep},
};

#[derive(NifMap, Debug)]
pub struct SplitOptionsNif {
    // `None` is every depth.
    depth: Option<u32>,
    title_prefix: Option<String>,
    ignore_case: bool,
    include_front_matter: bool,
}

impl SplitOptionsNif {
    // Preserve the public depth contract for callers that bypass Elixir validation.
    pub fn validate(&self) -> NifResult<()> {
        if self.depth == Some(0) {
            return Err(tagged_err(
                atoms::other(),
                "Invalid :depth 0: the depth must be a positive integer or :all",
            ));
        }

        Ok(())
    }

    fn to_upstream(&self) -> SplitByBookmarksOptions {
        SplitByBookmarksOptions {
            level: self.depth.map_or(BookmarkLevel::All, BookmarkLevel::UpTo),
            include_front_matter: self.include_front_matter,
            ..SplitByBookmarksOptions::default()
        }
    }

    // The title is trimmed; the caller's prefix remains verbatim.
    fn matches(&self, title: &str) -> bool {
        let Some(prefix) = &self.title_prefix else {
            return true;
        };

        let title = title.trim();
        if self.ignore_case {
            fold(title).starts_with(&fold(prefix))
        } else {
            title.starts_with(prefix.as_str())
        }
    }
}

// `last` is inclusive, so it feeds `check_span` and an Elixir range directly.
#[derive(NifMap, Debug)]
pub struct BookmarkSegmentNif {
    pub title: Option<String>,
    pub first: usize,
    pub last: usize,
    pub file_stem: String,
}

impl From<BookmarkSegment> for BookmarkSegmentNif {
    fn from(segment: BookmarkSegment) -> Self {
        BookmarkSegmentNif {
            title: segment.title,
            first: segment.start_page,
            last: segment.end_page - 1,
            file_stem: segment.file_stem,
        }
    }
}

// Plan in stages so `position` can map source pages before split points are collected.
pub(crate) fn plan(
    doc: &PdfDocument,
    page_count: usize,
    position: impl Fn(usize) -> Option<usize>,
    options: &SplitOptionsNif,
) -> NifResult<Vec<BookmarkSegmentNif>> {
    let Some(outline) = doc.get_outline().map_err(to_nif_err)? else {
        return Ok(Vec::new());
    };
    check_depth(&outline).map_err(|TooDeep| too_deep())?;

    let segments = segments(&outline, page_count, position, options).map_err(to_nif_err)?;

    Ok(segments.into_iter().map(BookmarkSegmentNif::from).collect())
}

// The public contract treats no split points as an empty plan.
fn segments(
    outline: &[OutlineItem],
    page_count: usize,
    position: impl Fn(usize) -> Option<usize>,
    options: &SplitOptionsNif,
) -> Result<Vec<BookmarkSegment>> {
    let upstream = options.to_upstream();
    let flat = flatten_outline(outline, upstream.level)
        .into_iter()
        .filter(|(title, _)| options.matches(title))
        .map(|(title, page)| (title, page.and_then(&position)))
        .collect();
    let points: Vec<(usize, String)> = collect_split_points(flat, &upstream)
        .into_iter()
        .filter(|&(page, _)| page < page_count)
        .collect();

    if points.is_empty() {
        return Ok(Vec::new());
    }

    let mut segments = build_segments(&points, page_count, &upstream)?;
    let titles: Vec<Option<&str>> = segments.iter().map(|s| s.title.as_deref()).collect();
    let stems = file_stems(&titles);
    for (segment, stem) in segments.iter_mut().zip(stems) {
        segment.file_stem = stem;
    }

    Ok(segments)
}

// Windows reserves these whatever their case and whatever extension follows.
const RESERVED_NAMES: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "COM0", "COM1", "COM2", "COM3", "COM4",
    "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³", "LPT0", "LPT1", "LPT2", "LPT3",
    "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
];

// Reserve the widest suffix once so deduplication stays linear and within budget.
fn file_stems(titles: &[Option<&str>]) -> Vec<String> {
    let digits = titles.len().to_string().len();
    let group_budget = DEFAULT_MAX_SLUG_BYTES - " ()".len() - digits;
    let mut taken = HashSet::new();
    let mut next: HashMap<String, usize> = HashMap::new();

    titles
        .iter()
        .map(|&title| {
            let base = file_stem_base(title);
            if taken.insert(collision_key(&base)) {
                return base;
            }

            let group = fit(&base, group_budget);
            let n = next.entry(collision_key(&group)).or_insert(2);
            let stem = format!("{group} ({n})");
            *n += 1;

            stem
        })
        .collect()
}

// Case-insensitive and canonically equivalent names are one file on the common
// desktop file systems, so they must be one key.
fn collision_key(stem: &str) -> String {
    fold(&stem.nfd().collect::<String>()).nfd().collect()
}

// A context-free fold merges sigma and multi-character case forms.
fn fold(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .flat_map(char::to_uppercase)
        .flat_map(char::to_lowercase)
        .collect()
}

fn file_stem_base(title: Option<&str>) -> String {
    let Some(title) = title else {
        return String::from("front-matter");
    };

    let slug = slugify_title_with(title, DEFAULT_MAX_SLUG_BYTES);
    if is_reserved(&slug) {
        fit(&format!("_{slug}"), DEFAULT_MAX_SLUG_BYTES)
    } else {
        slug
    }
}

fn is_reserved(stem: &str) -> bool {
    let device = stem.split('.').next().unwrap_or(stem);

    RESERVED_NAMES
        .iter()
        .any(|name| name.eq_ignore_ascii_case(device))
}

// Cuts at a char boundary and drops a `-` the cut exposes, as upstream's slug does.
fn fit(stem: &str, budget: usize) -> String {
    let mut end = stem.len().min(budget);
    while !stem.is_char_boundary(end) {
        end -= 1;
    }

    stem[..end].trim_end_matches('-').to_string()
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{
        editor::{DocumentEditor, DocumentInfo, EditableDocument},
        filename::slugify_title,
        split_bookmarks::split_by_bookmarks_to_bytes,
        Destination,
    };

    use super::*;
    use crate::metadata::read_metadata;

    fn item(title: &str, page: usize, children: Vec<OutlineItem>) -> OutlineItem {
        OutlineItem {
            title: title.to_string(),
            dest: Some(Destination::PageIndex(page)),
            children,
        }
    }

    fn outline() -> Vec<OutlineItem> {
        vec![
            item("Chapter 1", 0, vec![item("Section 1.1", 1, vec![])]),
            item("Chapter 2", 2, vec![]),
        ]
    }

    fn ranges(segments: &[BookmarkSegment]) -> Vec<(Option<&str>, usize, usize)> {
        segments
            .iter()
            .map(|s| (s.title.as_deref(), s.start_page, s.end_page))
            .collect()
    }

    fn options(depth: Option<u32>) -> SplitOptionsNif {
        SplitOptionsNif {
            depth,
            title_prefix: None,
            ignore_case: false,
            include_front_matter: true,
        }
    }

    fn with_prefix(prefix: &str, ignore_case: bool) -> SplitOptionsNif {
        SplitOptionsNif {
            title_prefix: Some(prefix.to_string()),
            ignore_case,
            ..options(Some(1))
        }
    }

    fn titles_matching(titles: &[&str], options: &SplitOptionsNif) -> Vec<String> {
        let outline: Vec<OutlineItem> = titles
            .iter()
            .enumerate()
            .map(|(page, title)| item(title, page, vec![]))
            .collect();

        segments(&outline, titles.len(), Some, options)
            .expect("plans")
            .into_iter()
            .filter_map(|segment| segment.title)
            .collect()
    }

    #[test]
    fn ignore_case_folds_letters_whose_case_forms_differ_in_length() {
        let titles = ["Straße 1", "Chapter"];

        assert_eq!(
            titles_matching(&titles, &with_prefix("STRASSE", true)),
            ["Straße 1"]
        );
        assert!(titles_matching(&titles, &with_prefix("STRASSE", false)).is_empty());
    }

    #[test]
    fn the_prefix_rule_trims_the_title_and_not_the_prefix() {
        let titles = ["  Chapter 1", "chapter 2"];

        assert_eq!(
            titles_matching(&titles, &with_prefix("Chapter", false)),
            ["  Chapter 1"]
        );
        assert!(titles_matching(&titles, &with_prefix(" Chapter", false)).is_empty());
    }

    #[test]
    fn fold_merges_every_case_form_full_folding_merges() {
        for (a, b) in [
            ("Σ", "ς"),
            ("σ", "ς"),
            ("ß", "SS"),
            ("ẞ", "ss"),
            ("ﬅ", "ST"),
            ("Ab", "aB"),
        ] {
            assert_eq!(fold(a), fold(b), "{a} and {b}");
        }

        // Full folding keeps a dotted capital I apart from a plain i.
        assert_ne!(fold("İ"), fold("i"));
    }

    #[test]
    fn a_bookmark_on_a_deleted_page_is_skipped() {
        // Source page 0 deleted: sources 1 and 2 now sit at 0 and 1.
        let position = |source: usize| source.checked_sub(1);

        let planned = segments(&outline(), 2, position, &options(Some(1))).expect("plans");

        assert_eq!(ranges(&planned), [(None, 0, 1), (Some("Chapter 2"), 1, 2)]);
    }

    #[test]
    fn moved_pages_are_split_in_output_order() {
        // Source page 2 moved to the front.
        let position = |source: usize| Some([1, 2, 0][source]);

        let planned = segments(&outline(), 3, position, &options(None)).expect("plans");

        assert_eq!(
            ranges(&planned),
            [
                (Some("Chapter 2"), 0, 1),
                (Some("Chapter 1"), 1, 2),
                (Some("Section 1.1"), 2, 3),
            ]
        );
    }

    #[test]
    fn no_split_point_is_an_empty_plan() {
        let planned = segments(&outline(), 3, |_| None, &options(Some(1))).expect("plans");

        assert!(planned.is_empty());
    }

    #[test]
    fn every_depth_is_all_levels() {
        let planned = segments(&outline(), 3, Some, &options(None)).expect("plans");

        assert_eq!(planned.len(), 3);
    }

    #[test]
    fn upstream_still_drops_info_from_a_bookmark_split() {
        let path = format!(
            "{}/../../test/fixtures/outline.pdf",
            env!("CARGO_MANIFEST_DIR")
        );
        let mut editor = DocumentEditor::open(path).expect("fixture opens");
        editor
            .set_info(DocumentInfo {
                title: Some(String::from("Book")),
                ..DocumentInfo::default()
            })
            .expect("sets /Info");
        let source = editor.save_to_bytes().expect("full rewrite");
        let reopened = PdfDocument::from_bytes(source.clone()).expect("source reopens");
        assert_eq!(read_metadata(&reopened).title.as_deref(), Some("Book"));

        let parts = split_by_bookmarks_to_bytes(&source, &SplitByBookmarksOptions::default())
            .expect("splits");

        assert_eq!(parts.len(), 2);
        for (_, bytes) in parts {
            let part = PdfDocument::from_bytes(bytes).expect("part opens");
            assert!(
                read_metadata(&part).title.is_none(),
                "upstream's split now carries /Info"
            );
        }
    }

    fn stems(titles: &[Option<&str>]) -> Vec<String> {
        file_stems(titles)
    }

    fn all_distinct(stems: &[String]) -> bool {
        stems
            .iter()
            .map(|stem| collision_key(stem))
            .collect::<HashSet<_>>()
            .len()
            == stems.len()
    }

    #[test]
    fn a_reserved_device_name_is_prefixed_with_or_without_an_extension() {
        for title in ["CON.txt", "con", "NUL.tar.gz", "COM¹", "LPT0", "CONOUT$"] {
            let [stem] = stems(&[Some(title)]).try_into().expect("one stem");
            assert!(stem.starts_with('_'), "{title} gave {stem}");
        }

        assert_eq!(
            stems(&[Some("CONTRACT"), Some("COM10"), Some("CONSOLE.txt")]),
            ["CONTRACT", "COM10", "CONSOLE.txt"]
        );
    }

    #[test]
    fn a_suffixed_stem_stays_within_the_budget() {
        let long = "x".repeat(DEFAULT_MAX_SLUG_BYTES);
        let titles = vec![Some(long.as_str()); 11];

        let stems = stems(&titles);

        assert!(stems
            .iter()
            .all(|stem| stem.len() <= DEFAULT_MAX_SLUG_BYTES));
        assert!(stems[1].ends_with(" (2)"));
        assert!(stems[10].ends_with(" (11)"));
        assert_eq!(stems.iter().collect::<HashSet<_>>().len(), 11);
    }

    #[test]
    fn a_cut_does_not_split_a_code_point() {
        // 80 bytes, so upstream keeps it whole; the ` (2)` budget of 76 lands
        // inside the two-byte `é` at bytes 75 and 76.
        let title = format!("{}é{}", "x".repeat(75), "y".repeat(3));

        let stems = stems(&[Some(&title), Some(&title)]);

        assert_eq!(stems[0], title);
        assert_eq!(stems[1], format!("{} (2)", "x".repeat(75)));
    }

    #[test]
    fn stems_differing_only_in_case_are_told_apart() {
        assert_eq!(
            stems(&[Some("Intro"), Some("intro"), None, Some("Front Matter")]),
            ["Intro", "intro (2)", "front-matter", "Front-Matter (2)"]
        );
    }

    #[test]
    fn titles_equal_under_case_folding_are_told_apart() {
        assert_eq!(stems(&[Some("Σ"), Some("ς")]), ["Σ", "ς (2)"]);
        assert_eq!(
            stems(&[Some("Straße"), Some("STRASSE")]),
            ["Straße", "STRASSE (2)"]
        );
    }

    #[test]
    fn canonically_equivalent_titles_are_told_apart() {
        let stems = stems(&[Some("Caf\u{e9}"), Some("Cafe\u{301}")]);

        assert_eq!(stems[0], "Caf\u{e9}");
        assert_eq!(stems[1], "Cafe\u{301} (2)");
    }

    #[test]
    fn many_repeated_or_colliding_titles_stay_distinct_and_within_budget() {
        let repeated = vec![Some("Record"); 20_000];

        let prefix = "x".repeat(76);
        let long: Vec<String> = (0..10_000).map(|i| format!("{prefix}{i:04}")).collect();
        let colliding: Vec<Option<&str>> = long
            .iter()
            .chain(long.iter())
            .map(|title| Some(title.as_str()))
            .collect();

        for titles in [repeated, colliding] {
            let stems = stems(&titles);
            assert!(all_distinct(&stems));
            assert!(stems
                .iter()
                .all(|stem| stem.len() <= DEFAULT_MAX_SLUG_BYTES));
        }
    }

    #[test]
    fn upstream_still_lowercases_rather_than_folds_the_title_prefix() {
        let options = SplitByBookmarksOptions {
            title_prefix: Some(String::from("STRASSE")),
            ignore_case: true,
            ..SplitByBookmarksOptions::default()
        };

        let points = collect_split_points(vec![(String::from("Straße"), Some(0))], &options);

        assert!(points.is_empty());
    }

    #[test]
    fn upstream_still_ignores_the_extension_of_a_reserved_name() {
        assert_eq!(slugify_title("CON.txt"), "CON.txt");
    }

    #[test]
    fn upstream_still_suffixes_past_the_slug_budget() {
        let long = "x".repeat(DEFAULT_MAX_SLUG_BYTES);
        let points = [(0, long.clone()), (1, long)];

        let segments =
            build_segments(&points, 2, &SplitByBookmarksOptions::default()).expect("builds");

        assert_eq!(segments[1].file_stem.len(), DEFAULT_MAX_SLUG_BYTES + 4);
    }
}
