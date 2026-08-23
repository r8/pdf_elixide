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

// A font's character encoding, encoded to Elixir as a flat tagged term:
// `{:standard, "WinAnsiEncoding"}` for a named base encoding, or the bare atom
// `:custom` / `:identity`.
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

// ISO 32000-1 §9.6.4 defines a subset prefix as exactly six uppercase ASCII
// letters and `+`; a `+` in any other shape remains part of the reported name.
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

// Converts a `FontInfo` (and its per-page resource name) into its NIF
// representation: eager metadata plus a resource handle to the font itself, so
// the embedded font-program bytes are pulled lazily (on `font_data`) rather
// than copied at extraction time.
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

// Font discovery is intentionally tolerant: an unreadable page, resources
// dictionary or font contributes no result rather than failing the call.
pub fn extract_page_fonts(doc: &PdfDocument, page_index: usize) -> Vec<FontNif> {
    page_font_set(doc, page_index)
        .into_iter()
        .map(|(resource_name, font)| font_to_nif(resource_name, font, page_index))
        .collect()
}

// Keep BEAM-independent discovery separate from ResourceArc construction.
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

// Resolves a page's Resources dictionary via the public `get_page` /
// `load_object` path (so it works without the upstream `rendering` feature),
// falling back to an empty dictionary on any failure.
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

#[rustler::nif(schedule = "DirtyCpu")]
fn font_data<'a>(env: Env<'a>, resource: ResourceArc<FontResource>) -> NifResult<Term<'a>> {
    resource.font.with_read(|font| {
        Ok(match font.embedded_font_data.as_deref() {
            Some(bytes) => binary_term(env, bytes, "font")?,
            None => rustler::types::atom::nil().encode(env),
        })
    })
}

// Releases this handle's reference to the font now, rather than waiting for the
// BEAM to garbage-collect it. Idempotent. The embedded font program is freed
// once no other extracted handle still references the same font. Takes the
// handle's lock exclusively, so it waits for an in-flight read on the same
// handle to return — see [`Closable::close`](crate::resource::Closable::close).
#[rustler::nif(schedule = "DirtyCpu")]
fn font_close(resource: ResourceArc<FontResource>) -> rustler::Atom {
    resource.font.close();

    atoms::ok()
}

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

    fn assert_split(base_font: &str, expected: (bool, &str)) {
        let (subset, name) = split_subset_prefix(base_font);

        assert_eq!((subset, name.as_str()), expected, "{base_font}");
    }

    #[test]
    fn strips_a_six_uppercase_letter_subset_prefix() {
        assert_split("ABCDEF+Arial", (true, "Arial"));
        assert_split("XEAACC+Ryumin-Light", (true, "Ryumin-Light"));
    }

    #[test]
    fn keeps_a_name_whose_plus_is_not_a_subset_prefix() {
        assert_split("ABCDE+Arial", (false, "ABCDE+Arial"));
        assert_split("ABCDEFG+Arial", (false, "ABCDEFG+Arial"));
        assert_split("abcdef+Arial", (false, "abcdef+Arial"));
        assert_split("ABC123+Arial", (false, "ABC123+Arial"));
        assert_split("Helvetica+Bold", (false, "Helvetica+Bold"));
        assert_split("Helvetica", (false, "Helvetica"));
    }

    #[test]
    fn splits_only_at_the_first_plus() {
        assert_split("ABCDEF+", (true, ""));
        assert_split("ABCDEF+AB+C", (true, "AB+C"));
        assert_split("+Arial", (false, "+Arial"));
    }

    #[test]
    fn rejects_a_multi_byte_prefix_whatever_its_byte_length() {
        // Six bytes, three characters.
        assert_split("ÉÉÉ+Arial", (false, "ÉÉÉ+Arial"));
        // Seven bytes, six characters.
        assert_split("ABCDEÉ+Arial", (false, "ABCDEÉ+Arial"));
    }

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
