use std::{collections::HashMap, sync::Arc};

use pdf_oxide::{
    extractors::TextExtractor,
    fonts::{Encoding, FontInfo},
    object::Object,
    PdfDocument,
};
use rustler::{Encoder, Env, NifMap, OwnedBinary, ResourceArc, Term};

use crate::{atoms, FontResource};

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

/// Converts a `FontInfo` (and its per-page resource name) into its NIF
/// representation: eager metadata plus a resource handle to the font itself, so
/// the embedded font-program bytes are pulled lazily (on `font_data`) rather
/// than copied at extraction time.
pub fn font_to_nif(resource_name: String, font: Arc<FontInfo>, page: usize) -> FontNif {
    // A subset prefix is exactly six uppercase ASCII letters followed by `+`
    // (e.g. `ABCDEF+Arial`). Strip it for the reported name and record that the
    // font is subsetted.
    let (subset, base_font) = match font.base_font.split_once('+') {
        Some((prefix, rest))
            if prefix.len() == 6 && prefix.chars().all(|c| c.is_ascii_uppercase()) =>
        {
            (true, rest.to_string())
        }
        _ => (false, font.base_font.clone()),
    };

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
        resource: ResourceArc::new(FontResource { font }),
    }
}

/// Extracts every font referenced by a single page's Resources, with rich
/// metadata. Mirrors `PdfDocument::page_font_face_lookups`' tolerant preamble:
/// a page whose Resources can't be loaded simply yields no fonts (an empty
/// `Vec`) rather than erroring.
pub fn extract_page_fonts(doc: &PdfDocument, page_index: usize) -> Vec<FontNif> {
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
        .into_iter()
        .map(|(resource_name, font)| font_to_nif(resource_name, font, page_index))
        .collect()
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
fn font_data(env: Env<'_>, resource: ResourceArc<FontResource>) -> Term<'_> {
    match resource.font.embedded_font_data.as_deref() {
        Some(bytes) => {
            let mut bin = OwnedBinary::new(bytes.len()).expect("failed to allocate font binary");
            bin.as_mut_slice().copy_from_slice(bytes);
            bin.release(env).encode(env)
        }
        None => rustler::types::atom::nil().encode(env),
    }
}
