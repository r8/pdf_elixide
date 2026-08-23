// Use the bounded field-tree walk: upstream's enumerator aborts on cyclic `/Kids`.

use std::collections::HashMap;

use pdf_oxide::{
    object::Object,
    signatures::{
        extract_signer_certificate_der, verify_signer, verify_signer_detached, ByteRangeCalculator,
        SignatureInfo, SignatureSubFilter, SignatureVerifier, SignerVerify,
    },
    PdfDocument,
};
use rustler::{Atom, Binary, Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};

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

// Bound zero-padded `/Contents` by its outer DER length before verification.
// Pass an unreadable header through so the verifier remains the validator.
fn trim_der_padding(contents: &[u8]) -> &[u8] {
    match der_tlv_len(contents) {
        Some(len) => &contents[..len],
        None => contents,
    }
}

fn der_tlv_len(bytes: &[u8]) -> Option<usize> {
    let [_tag, first, rest @ ..] = bytes else {
        return None;
    };

    let (length, header) = if *first < 0x80 {
        (usize::from(*first), 2)
    } else {
        // DER excludes 0x80 and 0xFF; four length bytes also fit 32-bit usize.
        let count = usize::from(first & 0x7F);
        if !(1..=4).contains(&count) || rest.len() < count {
            return None;
        }

        let length = rest[..count]
            .iter()
            .fold(0u64, |acc, &byte| (acc << 8) | u64::from(byte));

        (usize::try_from(length).ok()?, 2 + count)
    };

    let total = header.checked_add(length)?;

    (total <= bytes.len()).then_some(total)
}

fn cms_blob(contents: Option<&[u8]>) -> NifResult<&[u8]> {
    let contents = contents.ok_or_else(|| {
        tagged_err(
            atoms::invalid_pdf(),
            "signature dictionary has no /Contents to verify",
        )
    })?;

    Ok(trim_der_padding(contents))
}

fn signed_bytes(pdf_data: &[u8], byte_range: &[i64]) -> NifResult<Vec<u8>> {
    let Ok(range) = <[i64; 4]>::try_from(byte_range) else {
        return Err(tagged_err(
            atoms::invalid_pdf(),
            format!(
                "signature /ByteRange has {} entries, expected four",
                byte_range.len()
            ),
        ));
    };

    if !byte_range_fits(&range, pdf_data.len()) {
        return Err(tagged_err(
            atoms::invalid_pdf(),
            format!(
                "signature /ByteRange {range:?} does not lie within {} bytes",
                pdf_data.len()
            ),
        ));
    }

    ByteRangeCalculator::extract_signed_bytes(pdf_data, &range).map_err(to_nif_err)
}

// Guard upstream's unchecked i64-to-usize cast: a negative span can wrap past
// its bounds check and panic while indexing the file.
fn byte_range_fits(range: &[i64; 4], size: usize) -> bool {
    let [offset1, length1, offset2, length2] = *range;

    span_fits(offset1, length1, size) && span_fits(offset2, length2, size)
}

fn span_fits(offset: i64, length: i64, size: usize) -> bool {
    let (Ok(offset), Ok(length)) = (usize::try_from(offset), usize::try_from(length)) else {
        return false;
    };

    offset.checked_add(length).is_some_and(|end| end <= size)
}

fn verdict_atom(verify: SignerVerify) -> Atom {
    match verify {
        SignerVerify::Valid => atoms::valid(),
        SignerVerify::Invalid => atoms::invalid(),
        SignerVerify::Unknown => atoms::unknown(),
    }
}

// Dirty for its own work rather than for a lock — it takes no resource at all.
// Parsing the CMS blob and verifying a public-key signature over it, plus
// hashing the covered range here, can outrun a normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_verify_detached(
    contents: Option<Binary>,
    byte_range: Vec<i64>,
    pdf_data: Binary,
) -> NifResult<Atom> {
    let blob = cms_blob(contents.as_deref())?;
    let signed = signed_bytes(&pdf_data, &byte_range)?;

    verify_signer_detached(blob, &signed)
        .map(verdict_atom)
        .map_err(to_nif_err)
}

// Dirty for the same reason as `signature_verify_detached` above.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_verify_signer(contents: Option<Binary>) -> NifResult<Atom> {
    let blob = cms_blob(contents.as_deref())?;

    verify_signer(blob).map(verdict_atom).map_err(to_nif_err)
}

// Dirty for the same reason as the two verify NIFs above.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_certificate<'a>(env: Env<'a>, contents: Option<Binary>) -> NifResult<Term<'a>> {
    let blob = cms_blob(contents.as_deref())?;
    let der = extract_signer_certificate_der(blob).map_err(to_nif_err)?;

    binary_term(env, &der, "signer certificate")
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
    fn bounds_a_der_value_by_its_own_length() {
        assert_eq!(der_tlv_len(&[0x30, 0x00]), Some(2));
        assert_eq!(der_tlv_len(&[0x30, 0x03, 1, 2, 3]), Some(5));
        assert_eq!(der_tlv_len(&[0x30, 0x03, 1, 2, 3, 0, 0, 0]), Some(5));

        assert_eq!(
            trim_der_padding(&[0x30, 0x03, 1, 2, 3, 0, 0]),
            &[0x30, 0x03, 1, 2, 3]
        );
    }

    #[test]
    fn reads_every_long_form_length() {
        let tlv = |count: usize, length: usize| {
            let mut bytes = vec![0x30, 0x80 | count as u8];
            bytes.extend_from_slice(&length.to_be_bytes()[8 - count..]);
            bytes.resize(bytes.len() + length, 0xAA);
            bytes
        };

        assert_eq!(der_tlv_len(&tlv(1, 128)), Some(131));
        assert_eq!(der_tlv_len(&tlv(2, 256)), Some(260));
        assert_eq!(der_tlv_len(&tlv(3, 5)), Some(10));
        // Legal to read even though DER wants the minimal encoding.
        assert_eq!(der_tlv_len(&tlv(4, 5)), Some(11));
    }

    #[test]
    fn refuses_a_length_it_cannot_trust() {
        assert_eq!(der_tlv_len(&[]), None);
        assert_eq!(der_tlv_len(&[0x30]), None);
        assert_eq!(der_tlv_len(&[0x30, 0x80, 1, 2, 0, 0]), None);
        assert_eq!(der_tlv_len(&[0x30, 0xFF, 1, 2]), None);
        assert_eq!(der_tlv_len(&[0x30, 0x85, 1, 2, 3, 4, 5]), None);
        assert_eq!(der_tlv_len(&[0x30, 0x82, 0x01]), None);
        assert_eq!(der_tlv_len(&[0x30, 0x0A, 1, 2]), None);
    }

    #[test]
    fn passes_an_unreadable_blob_through_untouched() {
        let blob = [0x30, 0x80, 1, 2];

        assert_eq!(trim_der_padding(&blob), &blob);
    }

    #[test]
    fn accepts_a_byte_range_inside_the_file() {
        assert!(byte_range_fits(&[0, 10, 20, 10], 30));
        assert!(byte_range_fits(&[0, 30, 30, 0], 30));
        assert!(byte_range_fits(&[0, 0, 0, 0], 0));
    }

    #[test]
    fn refuses_a_byte_range_that_wraps_past_the_bounds_check() {
        assert!(!byte_range_fits(&[0, 0, -1, 2], 4096));
        assert!(!byte_range_fits(&[-1, 2, 0, 0], 4096));
        assert!(!byte_range_fits(&[0, i64::MAX, 0, 0], 4096));
        assert!(!byte_range_fits(&[0, 1, 0, 0], 0));
    }

    #[test]
    fn upstream_still_rejects_a_zero_padded_contents() {
        let doc = fixture("form_signature_cms.pdf");
        let infos = signature_infos(&doc).expect("local enumeration");
        let padded = infos[0]
            .contents
            .as_deref()
            .expect("the CMS fixture carries /Contents");

        let trimmed = trim_der_padding(padded);
        assert!(trimmed.len() < padded.len(), "fixture must carry padding");

        assert!(
            verify_signer(padded).is_err(),
            "upstream now reads a padded /Contents; the DER bound is no longer load-bearing"
        );
        assert!(verify_signer(trimmed).is_ok());
    }

    // The certificate path reaches `ContentInfo::from_der` independently of the
    // verify path, so it can stop needing the DER bound on its own.
    #[test]
    fn upstream_still_rejects_a_zero_padded_certificate_blob() {
        let doc = fixture("form_signature_cms.pdf");
        let infos = signature_infos(&doc).expect("local enumeration");
        let padded = infos[0]
            .contents
            .as_deref()
            .expect("the CMS fixture carries /Contents");

        let trimmed = trim_der_padding(padded);
        assert!(trimmed.len() < padded.len(), "fixture must carry padding");

        assert!(
            extract_signer_certificate_der(padded).is_err(),
            "upstream now reads a padded /Contents here; the DER bound is no longer \
             load-bearing on the certificate path"
        );
        assert!(extract_signer_certificate_der(trimmed).is_ok());
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
