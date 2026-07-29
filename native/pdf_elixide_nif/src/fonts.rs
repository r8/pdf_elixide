use std::{collections::HashMap, sync::Arc};

use pdf_oxide::{
    extractors::TextExtractor,
    fonts::{Encoding, FontInfo},
    object::Object,
    PdfDocument,
};
use rustler::{Encoder, Env, NifMap, NifResult, ResourceArc, Term};

use crate::{atoms, binary::binary_term, resource::Closable, FontResource};

#[derive(NifMap)]
#[rustler(encode)]
pub struct FontNif {
    page: usize,
    resource_name: String,
    base_font: String,
    subtype: String,
    encoding: EncodingNif,
    embedded: bool,
    subset: bool,
    weight: Option<i32>,
    bold: bool,
    italic: bool,
    resource: ResourceArc<FontResource>,
}

/// A font's character encoding, encoded to Elixir as a flat tagged term:
/// `{:standard, "WinAnsiEncoding"}` for a named base encoding, or the bare atom
/// `:custom` / `:identity`.
pub enum EncodingNif {
    Standard(String),
    Custom,
    Identity,
}

impl Encoder for EncodingNif {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            EncodingNif::Standard(name) => (atoms::standard(), name.as_str()).encode(env),
            EncodingNif::Custom => atoms::custom().encode(env),
            EncodingNif::Identity => atoms::identity().encode(env),
        }
    }
}

impl From<&Encoding> for EncodingNif {
    fn from(encoding: &Encoding) -> Self {
        match encoding {
            Encoding::Standard(name) => EncodingNif::Standard(name.clone()),
            Encoding::Custom(_) => EncodingNif::Custom,
            Encoding::Identity => EncodingNif::Identity,
        }
    }
}

/// Splits a `/BaseFont` name into "is this a subset?" and the name with any
/// subset prefix removed.
///
/// A subset prefix is *exactly* six uppercase ASCII letters followed by `+`
/// (ISO 32000-1 §9.6.4), e.g. `ABCDEF+Arial`. Anything else — a shorter or
/// longer run, a lowercase or digit-bearing one, or a `+` that is simply part
/// of the name — is left alone, so `Helvetica+Bold` keeps both halves.
///
/// **This is a choice, and upstream makes it three different ways**, which is
/// why the rule is written out here rather than borrowed:
///
/// - `predefined_cidfont::is_predefined` (`src/fonts/predefined_cidfont.rs`)
///   requires the same exact shape, for the same stated reason — not
///   truncating Asian-tooling names that legitimately contain `+`. That is the
///   one this follows.
/// - `FontDict::classify_std14` (`src/fonts/font_dict.rs`) strips at the first
///   `+` unless the suffix is empty, with no shape check.
/// - `PdfDocument::page_font_face_lookups` (`src/document.rs`) strips at the
///   first `+` unconditionally.
///
/// The middle one is why `FontNif`'s `base_font` and its `bold` / `weight` can
/// disagree about which name they describe: those come from `FontInfo::is_bold`
/// and friends, computed under `classify_std14`'s looser rule. `Helvetica+Bold`
/// is reported with its name intact and classified as the standard-14 `Bold`.
/// Deliberate — the strict rule is the right one for a *reported* name — but
/// don't "fix" one side without the other.
fn split_subset_prefix(base_font: &str) -> (bool, String) {
    match base_font.split_once('+') {
        Some((prefix, rest))
            if prefix.len() == 6 && prefix.chars().all(|c| c.is_ascii_uppercase()) =>
        {
            (true, rest.to_string())
        }
        _ => (false, base_font.to_string()),
    }
}

/// Converts a `FontInfo` (and its per-page resource name) into its NIF
/// representation: eager metadata plus a resource handle to the font itself, so
/// the embedded font-program bytes are pulled lazily (on `font_data`) rather
/// than copied at extraction time.
pub fn font_to_nif(resource_name: String, font: Arc<FontInfo>, page: usize) -> FontNif {
    let (subset, base_font) = split_subset_prefix(&font.base_font);

    FontNif {
        page,
        resource_name,
        base_font,
        subtype: font.subtype.clone(),
        encoding: (&font.encoding).into(),
        embedded: font.embedded_font_data.is_some(),
        subset,
        weight: font.font_weight,
        bold: font.is_bold(),
        italic: font.is_italic(),
        resource: ResourceArc::new(FontResource {
            font: Closable::new("Font", font),
        }),
    }
}

/// Extracts every font referenced by a single page's Resources, with rich
/// metadata.
///
/// Infallible by construction, mirroring `PdfDocument::page_font_face_lookups`
/// (`pdf_oxide/src/document.rs:22679`) — not just its Resources-resolving
/// preamble but its whole per-page body, including the
/// `if self.load_fonts_public(..).is_ok()` at `:22710`. There are four points
/// where a page contributes no fonts instead of an error: an unresolvable page
/// (`get_page`), a page object that is not a dictionary (`as_dict`), a dangling
/// `/Resources` reference (`load_object`) — all three in `page_resources` — and
/// a font that fails to load, below.
///
/// So an empty `Vec` means either "references no fonts" or "could not be read",
/// and unlike the predicates in `document.rs` that distinction is *not* restored
/// by a strict variant: this one matches an upstream loop's policy, which the
/// binding follows rather than second-guesses. `Document.fonts/1,2` say so, and
/// `upstream_drift_test.exs` pins it.
pub fn extract_page_fonts(doc: &PdfDocument, page_index: usize) -> Vec<FontNif> {
    page_font_set(doc, page_index)
        .into_iter()
        .map(|(resource_name, font)| font_to_nif(resource_name, font, page_index))
        .collect()
}

/// The whole of [`extract_page_fonts`] except the `FontNif` conversion: one
/// page's `(resource name, font)` pairs, sorted, or an empty `Vec` at any of the
/// four give-up points described above.
///
/// Split out because [`font_to_nif`] mints a `ResourceArc`, which needs a live
/// BEAM — so the transcription of upstream's loop would otherwise be unreachable
/// from `cargo test`. `page_fonts_still_match_upstream_lookups` is what that
/// buys.
fn page_font_set(doc: &PdfDocument, page_index: usize) -> Vec<(String, Arc<FontInfo>)> {
    let resources = page_resources(doc, page_index);

    let mut extractor = TextExtractor::new();
    if doc.load_fonts_public(&resources, &mut extractor).is_err() {
        return Vec::new();
    }

    // `get_font_set` iterates a `HashMap`, whose order Rust randomizes per
    // process. Sort by resource name (unique within a page) so extraction is
    // deterministic across calls.
    let mut fonts = extractor.get_font_set();
    fonts.sort_by(|(a, _), (b, _)| a.cmp(b));
    fonts
}

/// Resolves a page's Resources dictionary via the public `get_page` /
/// `load_object` path (so it works without the upstream `rendering` feature),
/// falling back to an empty dictionary on any failure.
fn page_resources(doc: &PdfDocument, page_index: usize) -> Object {
    let empty = || Object::Dictionary(HashMap::new());

    let Ok(page) = doc.get_page(page_index) else {
        return empty();
    };
    let Some(dict) = page.as_dict() else {
        return empty();
    };
    let resources = dict.get("Resources").cloned().unwrap_or_else(empty);

    match resources.as_reference() {
        Some(reference) => doc.load_object(reference).unwrap_or_else(|_| empty()),
        None => resources,
    }
}

/// Returns the font's raw embedded font-program bytes (the TrueType / OpenType
/// file) as an Erlang binary, or the atom `nil` when the font has no embedded
/// program (e.g. the standard 14).
#[rustler::nif(schedule = "DirtyCpu")]
fn font_data<'a>(env: Env<'a>, resource: ResourceArc<FontResource>) -> NifResult<Term<'a>> {
    resource.font.with_read(|font| {
        Ok(match font.embedded_font_data.as_deref() {
            Some(bytes) => binary_term(env, bytes, "font")?,
            None => rustler::types::atom::nil().encode(env),
        })
    })
}

/// Releases this handle's reference to the font now, rather than waiting for the
/// BEAM to garbage-collect it. Idempotent. The embedded font program is freed
/// once no other extracted handle still references the same font. Takes the
/// handle's lock exclusively, so it waits for an in-flight read on the same
/// handle to return — see [`Closable::close`](crate::resource::Closable::close).
#[rustler::nif(schedule = "DirtyCpu")]
fn font_close(resource: ResourceArc<FontResource>) -> rustler::Atom {
    resource.font.close();

    atoms::ok()
}

/// Returns whether the font handle has been released with `font_close`.
#[rustler::nif(schedule = "DirtyCpu")]
fn font_closed(resource: ResourceArc<FontResource>) -> bool {
    resource.font.is_closed()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    /// Asserts both halves of the decision at once, so a failure shows what the
    /// rule made of the whole name rather than whichever assertion fired first.
    fn assert_split(base_font: &str, expected: (bool, &str)) {
        let (subset, name) = split_subset_prefix(base_font);

        assert_eq!((subset, name.as_str()), expected, "{base_font}");
    }

    /// The happy path, and the only shape `fonts.pdf` exercises.
    #[test]
    fn strips_a_six_uppercase_letter_subset_prefix() {
        assert_split("ABCDEF+Arial", (true, "Arial"));
        assert_split("XEAACC+Ryumin-Light", (true, "Ryumin-Light"));
    }

    /// Every near-miss of the six-uppercase-letter shape, none of which any
    /// fixture produces — and each of which a looser rule would silently
    /// mis-report, since the wrong answer is a plausible font name rather than
    /// an error.
    ///
    /// `Helvetica+Bold` is the one that matters most. `FontDict::classify_std14`
    /// (`pdf_oxide/src/fonts/font_dict.rs`) *would* strip it, which is why
    /// [`split_subset_prefix`]'s doc comment warns that `base_font` and the
    /// `bold` / `weight` fields beside it are computed under different rules.
    #[test]
    fn keeps_a_name_whose_plus_is_not_a_subset_prefix() {
        // Wrong length: five and seven letters.
        assert_split("ABCDE+Arial", (false, "ABCDE+Arial"));
        assert_split("ABCDEFG+Arial", (false, "ABCDEFG+Arial"));
        // Right length, wrong character class.
        assert_split("abcdef+Arial", (false, "abcdef+Arial"));
        assert_split("ABC123+Arial", (false, "ABC123+Arial"));
        // A `+` that is simply part of the name.
        assert_split("Helvetica+Bold", (false, "Helvetica+Bold"));
        // No `+` at all — the other case `fonts.pdf` covers.
        assert_split("Helvetica", (false, "Helvetica"));
    }

    /// Two boundary shapes worth fixing in place rather than discovering later:
    /// a bare prefix is a subset of the empty name (not "not a subset"), and
    /// `split_once` takes the *first* `+`, so a second one stays in the name.
    #[test]
    fn splits_only_at_the_first_plus() {
        assert_split("ABCDEF+", (true, ""));
        assert_split("ABCDEF+AB+C", (true, "AB+C"));
        assert_split("+Arial", (false, "+Arial"));
    }

    /// The length test is `prefix.len()`, which counts **bytes**, so on its own
    /// it would accept a three-character prefix of six-byte characters. What
    /// saves it is that the two guards compose: `is_ascii_uppercase` is false
    /// for every non-ASCII scalar, so a multi-byte prefix is rejected whichever
    /// side of six bytes it lands on. Pinned because dropping either guard
    /// yields a wrong answer, not a panic.
    #[test]
    fn rejects_a_multi_byte_prefix_whatever_its_byte_length() {
        // Six bytes, three characters.
        assert_split("ÉÉÉ+Arial", (false, "ÉÉÉ+Arial"));
        // Seven bytes, six characters.
        assert_split("ABCDEÉ+Arial", (false, "ABCDEÉ+Arial"));
    }

    /// Upstream canary. [`page_font_set`] and [`page_resources`] transcribe
    /// `PdfDocument::page_font_face_lookups` (`pdf_oxide/src/document.rs`) —
    /// not only its Resources-resolving preamble but its whole per-page body,
    /// including the `if self.load_fonts_public(..).is_ok()` that makes an
    /// unloadable font contribute nothing instead of failing. `Document.fonts/1,2`
    /// rest their "infallible by construction" contract on that, and **nothing
    /// in the binding calls the upstream original**, so only this can tell you
    /// when the two stop agreeing.
    ///
    /// Compares *resource-name key sets*, not values, and deliberately:
    /// upstream's canonical name strips at the first `+` unconditionally where
    /// [`split_subset_prefix`] demands the six-uppercase shape. Which fonts a
    /// page yields is the shared claim; what they are called is not.
    ///
    /// `broken_page.pdf` is the load-bearing half — its page 2 resolves through
    /// neither the page tree nor the scanning fallback, so it is the fixture
    /// where both sides must agree on *nothing* rather than on something.
    #[test]
    fn page_fonts_still_match_upstream_lookups() {
        for name in ["fonts.pdf", "sample.pdf", "broken_page.pdf"] {
            let doc = PdfDocument::open(fixture(name)).expect("fixture opens");
            let upstream = doc.page_font_face_lookups().expect("upstream lookups");

            for (page_index, expected) in upstream.iter().enumerate() {
                let ours: Vec<String> = page_font_set(&doc, page_index)
                    .into_iter()
                    .map(|(resource_name, _)| resource_name)
                    .collect();
                let mut theirs: Vec<String> = expected.keys().cloned().collect();
                theirs.sort();

                // `page_font_set` already sorts by resource name, which is the
                // determinism `Document.fonts/2` promises; only upstream's
                // `HashMap` needs ordering here.
                assert_eq!(ours, theirs, "{name} page {page_index}");
            }
        }

        // Precondition: at least one fixture page really does carry fonts, so
        // the comparison above cannot pass by both sides being empty everywhere.
        let fonts_doc = PdfDocument::open(fixture("fonts.pdf")).expect("fixture opens");
        assert!(!page_font_set(&fonts_doc, 0).is_empty());
    }
}
