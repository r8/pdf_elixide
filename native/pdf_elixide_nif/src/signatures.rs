// Use the bounded field-tree walk: upstream's enumerator aborts on cyclic `/Kids`.

use std::collections::HashMap;

use pdf_oxide::{
    object::Object,
    signatures::{SignatureInfo, SignatureSubFilter, SignatureVerifier},
    PdfDocument,
};
use rustler::{Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};

use crate::{
    atoms,
    binary::binary_term,
    error::{tagged_err, to_nif_err},
    form_tree,
    metadata::decode_pdf_text_string,
    DocumentResource, EditorResource,
};

#[derive(NifUnitEnum, Debug, PartialEq)]
pub enum SubFilterNif {
    Pkcs7Detached,
    Pkcs7Sha1,
    CadesDetached,
    Rfc3161,
}

#[derive(NifMap, Debug)]
pub struct SignatureNif<'a> {
    signer_name: Option<String>,
    signing_time: Option<String>,
    reason: Option<String>,
    location: Option<String>,
    contact_info: Option<String>,
    sub_filter: Option<SubFilterNif>,
    byte_range: Vec<i64>,
    contents: Option<Term<'a>>,
}

fn sub_filter_to_nif(sub_filter: SignatureSubFilter) -> SubFilterNif {
    match sub_filter {
        SignatureSubFilter::Pkcs7Detached => SubFilterNif::Pkcs7Detached,
        SignatureSubFilter::Pkcs7Sha1 => SubFilterNif::Pkcs7Sha1,
        SignatureSubFilter::CadesDetached => SubFilterNif::CadesDetached,
        SignatureSubFilter::Rfc3161 => SubFilterNif::Rfc3161,
    }
}

fn signature_to_nif<'a>(env: Env<'a>, info: SignatureInfo) -> NifResult<SignatureNif<'a>> {
    let contents = info
        .contents
        .as_deref()
        .map(|bytes| binary_term(env, bytes, "signature contents"))
        .transpose()?;

    Ok(SignatureNif {
        signer_name: info.signer_name,
        signing_time: info.signing_time,
        reason: info.reason,
        location: info.location,
        contact_info: info.contact_info,
        sub_filter: info.sub_filter.map(sub_filter_to_nif),
        byte_range: info.byte_range,
        contents,
    })
}

// Signature reads must not turn an unreadable object into "no signatures".
fn resolve(doc: &PdfDocument, obj: &Object) -> NifResult<Object> {
    match obj.as_reference() {
        Some(obj_ref) => doc.load_object(obj_ref).map_err(to_nif_err),
        None => Ok(obj.clone()),
    }
}

// Upstream decodes these PDF text strings as UTF-8, so re-read them before the
// lossy values escape. `/M` uses the same decoder as metadata dates.
fn redecode_text(dict: &HashMap<String, Object>, info: &mut SignatureInfo) {
    let text = |key: &str| {
        dict.get(key)
            .and_then(Object::as_string)
            .map(decode_pdf_text_string)
    };

    info.signer_name = text("Name");
    info.signing_time = text("M");
    info.reason = text("Reason");
    info.location = text("Location");
    info.contact_info = text("ContactInfo");
}

fn signature_infos(doc: &PdfDocument) -> NifResult<Vec<SignatureInfo>> {
    let verifier = SignatureVerifier::new();
    let mut out = Vec::new();

    for value in form_tree::signature_values(doc)? {
        let sig_dict = resolve(doc, &value)?;

        let Some(dict) = sig_dict.as_dict() else {
            // Match the unresolved value: upstream also resolves a dangling
            // reference to null, but only a literal null means "cleared".
            if matches!(value, Object::Null) {
                continue;
            }

            return Err(tagged_err(
                atoms::invalid_pdf(),
                "signature field /V is not a signature dictionary",
            ));
        };

        let mut info = verifier
            .extract_signature_info(&sig_dict)
            .map_err(to_nif_err)?;
        redecode_text(dict, &mut info);

        out.push(info);
    }

    Ok(out)
}

fn signatures_of<'a>(env: Env<'a>, doc: &PdfDocument) -> NifResult<Vec<SignatureNif<'a>>> {
    signature_infos(doc)?
        .into_iter()
        .map(|info| signature_to_nif(env, info))
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_signatures<'a>(
    env: Env<'a>,
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Vec<SignatureNif<'a>>> {
    resource.doc.with_read(|doc| signatures_of(env, doc))
}

// Shared rather than exclusive: only `source()` is reached, which takes `&self`.
#[rustler::nif(schedule = "DirtyCpu")]
fn editor_signatures<'a>(
    env: Env<'a>,
    resource: ResourceArc<EditorResource>,
) -> NifResult<Vec<SignatureNif<'a>>> {
    resource
        .editor
        .with_read(|editor| signatures_of(env, editor.source()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> PdfDocument {
        let path = format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        );

        PdfDocument::open(path).expect("fixture opens")
    }

    // Never pass the cyclic fixture to upstream's enumerator; it aborts.

    // Compare only values this binding still takes from upstream.
    #[test]
    fn signatures_match_upstream_enumerate() {
        let doc = fixture("form_signature.pdf");
        let mut upstream_doc = fixture("form_signature.pdf");

        let ours = signature_infos(&doc).expect("local enumeration");
        let theirs = pdf_oxide::signatures::enumerate_signatures(&mut upstream_doc)
            .expect("upstream enumeration");

        assert_eq!(ours.len(), theirs.len());
        assert_eq!(
            ours.first().map(|info| &info.byte_range),
            theirs.first().map(|info| &info.byte_range)
        );
        assert_eq!(
            ours.first().and_then(|info| info.contents.as_deref()),
            theirs.first().and_then(|info| info.contents.as_deref())
        );
    }

    #[test]
    fn upstream_still_misses_an_inherited_signature_field() {
        let doc = fixture("form_signature_edge.pdf");
        let mut upstream_doc = fixture("form_signature_edge.pdf");

        let ours = signature_infos(&doc).expect("local enumeration");
        let theirs = pdf_oxide::signatures::enumerate_signatures(&mut upstream_doc)
            .expect("upstream enumeration");

        assert_eq!(ours.len(), 1, "the inherited /Sig leaf is ours to find");
        assert!(
            theirs.is_empty(),
            "upstream now resolves an inherited /FT: {theirs:?}"
        );
    }

    #[test]
    fn upstream_still_decodes_signature_text_leniently() {
        let mut doc = fixture("form_signature_utf16.pdf");

        let theirs =
            pdf_oxide::signatures::enumerate_signatures(&mut doc).expect("upstream enumeration");
        let signer = theirs
            .first()
            .and_then(|info| info.signer_name.as_deref())
            .expect("upstream reports a /Name");

        assert!(
            signer.contains('\u{FFFD}'),
            "upstream now decodes /Name as a text string: {signer:?}"
        );
    }
}
