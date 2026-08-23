// Use the bounded field-tree walk: upstream's enumerator aborts on cyclic `/Kids`.

use std::collections::HashMap;

use cms::{content_info::ContentInfo, signed_data::SignedData};
use der::{oid::ObjectIdentifier, Decode, Encode, SliceReader};
use pdf_oxide::{
    object::Object,
    signatures::{
        classify_pades_level, extract_signer_certificate_der, read_dss, verify_signer,
        verify_signer_detached, ByteRangeCalculator, DocumentSecurityStore, HashAlgorithm,
        PadesLevel, SignatureInfo, SignatureSubFilter, SignatureVerifier, SignerVerify, Timestamp,
        VriEntry,
    },
    PdfDocument,
};
use rustler::{Atom, Binary, Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};

use crate::{
    atoms,
    binary::{binary_term, owned_binary},
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
    field_name: Option<String>,
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

fn signature_to_nif<'a>(
    env: Env<'a>,
    info: SignatureInfo,
    field_name: Option<String>,
) -> NifResult<SignatureNif<'a>> {
    let contents = info
        .contents
        .as_deref()
        .map(|bytes| binary_term(env, bytes, "signature contents"))
        .transpose()?;

    Ok(SignatureNif {
        field_name,
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

// One struct per direction is avoidable here: `NifMap` derives both `Encoder`
// and `Decoder`, and a `Binary` satisfies each, so `dss/1` encodes through the
// same shape `pades_level/2` decodes back.
#[derive(NifMap)]
pub struct VriNif<'a> {
    signature_digest: String,
    certificates: Vec<Binary<'a>>,
    crls: Vec<Binary<'a>>,
    ocsp_responses: Vec<Binary<'a>>,
    timestamp: Option<String>,
}

#[derive(NifMap)]
pub struct DssNif<'a> {
    certificates: Vec<Binary<'a>>,
    crls: Vec<Binary<'a>>,
    ocsp_responses: Vec<Binary<'a>>,
    vri: Vec<VriNif<'a>>,
}

fn der_binaries<'a>(env: Env<'a>, blobs: &[Vec<u8>]) -> NifResult<Vec<Binary<'a>>> {
    blobs
        .iter()
        .map(|blob| Ok(owned_binary(blob, "security store entry")?.release(env)))
        .collect()
}

fn vri_to_nif<'a>(env: Env<'a>, entry: VriEntry) -> NifResult<VriNif<'a>> {
    Ok(VriNif {
        signature_digest: entry.signature_digest,
        certificates: der_binaries(env, &entry.certificates)?,
        crls: der_binaries(env, &entry.crls)?,
        ocsp_responses: der_binaries(env, &entry.ocsp_responses)?,
        timestamp: entry.timestamp,
    })
}

fn dss_to_nif<'a>(env: Env<'a>, store: DocumentSecurityStore) -> NifResult<DssNif<'a>> {
    Ok(DssNif {
        certificates: der_binaries(env, &store.certificates)?,
        crls: der_binaries(env, &store.crls)?,
        ocsp_responses: der_binaries(env, &store.ocsp_responses)?,
        vri: store
            .vri
            .into_iter()
            .map(|entry| vri_to_nif(env, entry))
            .collect::<NifResult<_>>()?,
    })
}

// `DocumentSecurityStore` and `VriEntry` are `#[non_exhaustive]`, so a literal
// is unavailable and an upstream field added later keeps compiling as its
// default.
#[allow(clippy::field_reassign_with_default)]
fn dss_from_nif(dss: DssNif) -> DocumentSecurityStore {
    let mut store = DocumentSecurityStore::default();
    store.certificates = dss.certificates.iter().map(|b| b.to_vec()).collect();
    store.crls = dss.crls.iter().map(|b| b.to_vec()).collect();
    store.ocsp_responses = dss.ocsp_responses.iter().map(|b| b.to_vec()).collect();
    store.vri = dss
        .vri
        .into_iter()
        .map(|entry| {
            let mut out = VriEntry::default();
            out.signature_digest = entry.signature_digest;
            out.certificates = entry.certificates.iter().map(|b| b.to_vec()).collect();
            out.crls = entry.crls.iter().map(|b| b.to_vec()).collect();
            out.ocsp_responses = entry.ocsp_responses.iter().map(|b| b.to_vec()).collect();
            out.timestamp = entry.timestamp;
            out
        })
        .collect();

    store
}

fn dss_of<'a>(env: Env<'a>, doc: &PdfDocument) -> NifResult<Option<DssNif<'a>>> {
    read_dss(doc)
        .map_err(to_nif_err)?
        .map(|store| dss_to_nif(env, store))
        .transpose()
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

// Keep listing and counting on the same per-value classification rule.
fn signature_dict(doc: &PdfDocument, value: &Object) -> NifResult<Option<Object>> {
    let sig_dict = resolve(doc, value)?;

    if sig_dict.as_dict().is_none() {
        // Match the unresolved value: upstream also resolves a dangling
        // reference to null, but only a literal null means "cleared".
        if matches!(value, Object::Null) {
            return Ok(None);
        }

        return Err(tagged_err(
            atoms::invalid_pdf(),
            "signature field /V is not a signature dictionary",
        ));
    }

    Ok(Some(sig_dict))
}

fn signature_infos(doc: &PdfDocument) -> NifResult<Vec<(SignatureInfo, Option<String>)>> {
    let verifier = SignatureVerifier::new();
    let signatures = form_tree::signatures(doc)?;
    let mut out = Vec::new();

    for (value, field_name) in signatures.values {
        let Some(sig_dict) = signature_dict(doc, &value)? else {
            continue;
        };

        let mut info = verifier
            .extract_signature_info(&sig_dict)
            .map_err(to_nif_err)?;

        // Avoid panicking in the NIF even though `signature_dict` checked this.
        if let Some(dict) = sig_dict.as_dict() {
            redecode_text(dict, &mut info);
        }

        out.push((info, field_name));
    }

    Ok(out)
}

fn signatures_of<'a>(env: Env<'a>, doc: &PdfDocument) -> NifResult<Vec<SignatureNif<'a>>> {
    signature_infos(doc)?
        .into_iter()
        .map(|(info, field_name)| signature_to_nif(env, info, field_name))
        .collect()
}

fn signature_count(doc: &PdfDocument) -> NifResult<usize> {
    let mut count = 0;

    for value in form_tree::signature_values(doc)? {
        if signature_dict(doc, &value)?.is_some() {
            count += 1;
        }
    }

    Ok(count)
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

#[rustler::nif(schedule = "DirtyCpu")]
fn document_unsigned_signature_fields(
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Vec<String>> {
    resource
        .doc
        .with_read(|doc| Ok(form_tree::signatures(doc)?.unsigned))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_unsigned_signature_fields(
    resource: ResourceArc<EditorResource>,
) -> NifResult<Vec<String>> {
    resource
        .editor
        .with_read(|editor| Ok(form_tree::signatures(editor.source())?.unsigned))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_signature_count(resource: ResourceArc<DocumentResource>) -> NifResult<usize> {
    resource.doc.with_read(signature_count)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_signature_count(resource: ResourceArc<EditorResource>) -> NifResult<usize> {
    resource
        .editor
        .with_read(|editor| signature_count(editor.source()))
}

// Shared, like every signature read above: `read_dss` takes `&PdfDocument` and its walk over
// the catalog is one level deep, with nothing of the `/Kids` recursion that
// `form_tree` exists to bound.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_dss<'a>(
    env: Env<'a>,
    resource: ResourceArc<DocumentResource>,
) -> NifResult<Option<DssNif<'a>>> {
    resource.doc.with_read(|doc| dss_of(env, doc))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_dss<'a>(
    env: Env<'a>,
    resource: ResourceArc<EditorResource>,
) -> NifResult<Option<DssNif<'a>>> {
    resource
        .editor
        .with_read(|editor| dss_of(env, editor.source()))
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

fn contents_of(contents: Option<&[u8]>) -> NifResult<&[u8]> {
    contents.ok_or_else(|| {
        tagged_err(
            atoms::invalid_pdf(),
            "signature dictionary has no /Contents",
        )
    })
}

fn cms_blob(contents: Option<&[u8]>) -> NifResult<&[u8]> {
    Ok(trim_der_padding(contents_of(contents)?))
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

// Dirty for the same reason as the three verify/certificate NIFs above.
//
// The blob goes in untrimmed: the classifier decodes through a reader that
// tolerates the signer's zero padding, and upstream keys a DSS `/VRI` entry on
// the digest of the *padded* bytes, so trimming would break the B-LT lookup.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_pades_level(contents: Option<Binary>, dss: Option<DssNif>) -> NifResult<Atom> {
    // Only `contents` is read, and `Default` keeps an added upstream field from
    // breaking the build.
    let info = SignatureInfo {
        contents: Some(contents_of(contents.as_deref())?.to_vec()),
        ..Default::default()
    };
    let store = dss.map(dss_from_nif);

    match classify_pades_level(&info, store.as_ref()) {
        PadesLevel::BB => Ok(atoms::b_b()),
        PadesLevel::BT => Ok(atoms::b_t()),
        PadesLevel::BLt => Ok(atoms::b_lt()),
        // `PadesLevel` is `#[non_exhaustive]`, and upstream documents that this
        // classifier never returns `BLta`. This arm is what reports either of
        // those changing rather than mapping it to a level the caller was not
        // told about.
        other => Err(tagged_err(
            atoms::unsupported(),
            format!("pdf_oxide reported an unmapped PAdES level: {other:?}"),
        )),
    }
}

// `id-aa-signatureTimeStampToken` — the RFC 3161 token a PAdES B-T signature
// carries as a CMS *unsigned* attribute.
const OID_SIGNATURE_TIME_STAMP: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.16.2.14");

// Carries the reason without building the atom, so `cargo test` can drive the
// walk's failures: an atom without a BEAM aborts the process. `outline.rs`'s
// `TooDeep` is the same move for the same reason.
#[derive(Debug, PartialEq)]
struct MalformedCms(&'static str);

// Transcribed from upstream's `has_bt_timestamp`, which finds this attribute and
// then answers only a `bool`. Untrimmed and decoded without `finish()`, so the
// signer's zero padding is tolerated.
//
// `Ok(None)` means the blob parsed as CMS `SignedData` and carries no such
// attribute — the only point at which "no timestamp" is a finding rather than a
// failure to look, so anything earlier is an error. A `SignedData` with no
// `SignerInfo` stays on that side deliberately; the missing signer is
// `signature_verify_signer`'s to report.
fn signature_timestamp_token(cms: &[u8]) -> Result<Option<Vec<u8>>, MalformedCms> {
    let mut reader =
        SliceReader::new(cms).map_err(|_| MalformedCms("signature /Contents is empty"))?;
    let content = ContentInfo::decode(&mut reader)
        .map_err(|_| MalformedCms("signature /Contents is not a CMS blob"))?;
    let der = content
        .content
        .to_der()
        .map_err(|_| MalformedCms("signature /Contents holds unencodable CMS content"))?;
    let signed = SignedData::from_der(&der)
        .map_err(|_| MalformedCms("signature /Contents is not CMS SignedData"))?;

    let Some(signer) = signed.signer_infos.0.iter().next() else {
        return Ok(None);
    };
    let Some(attributes) = signer.unsigned_attrs.as_ref() else {
        return Ok(None);
    };
    let Some(attribute) = attributes
        .iter()
        .find(|attr| attr.oid == OID_SIGNATURE_TIME_STAMP)
    else {
        return Ok(None);
    };

    let value = attribute.values.iter().next().ok_or(MalformedCms(
        "signature timestamp attribute carries no value",
    ))?;

    value
        .to_der()
        .map(Some)
        .map_err(|_| MalformedCms("signature timestamp attribute holds an unencodable value"))
}

#[derive(NifMap)]
pub struct TimestampNif<'a> {
    token: Binary<'a>,
    time: i64,
    serial: String,
    policy_oid: String,
    tsa_name: Option<String>,
    hash_algorithm: Atom,
    message_imprint: Binary<'a>,
}

fn hash_algorithm_atom(algorithm: HashAlgorithm) -> Atom {
    match algorithm {
        HashAlgorithm::Sha1 => atoms::sha1(),
        HashAlgorithm::Sha256 => atoms::sha256(),
        HashAlgorithm::Sha384 => atoms::sha384(),
        HashAlgorithm::Sha512 => atoms::sha512(),
        HashAlgorithm::Unknown => atoms::unknown(),
    }
}

// The window `DateTime.from_unix/1` accepts. `Timestamp::time` casts an unsigned
// duration to `i64`, so a token outside it is refused here, which is what lets
// `Timestamp.from_nif/1` call `DateTime.from_unix!/1` rather than the fallible one.
const MIN_GEN_TIME: i64 = -62_167_219_200;
const MAX_GEN_TIME: i64 = 253_402_300_799;

fn timestamp_to_nif<'a>(env: Env<'a>, timestamp: &Timestamp) -> NifResult<TimestampNif<'a>> {
    let time = timestamp.time();
    if !(MIN_GEN_TIME..=MAX_GEN_TIME).contains(&time) {
        return Err(tagged_err(
            atoms::invalid_pdf(),
            format!("timestamp generation time {time} is not a representable date"),
        ));
    }

    let tsa_name = timestamp.tsa_name();

    Ok(TimestampNif {
        token: owned_binary(timestamp.token_bytes(), "timestamp token")?.release(env),
        time,
        serial: timestamp.serial(),
        policy_oid: timestamp.policy_oid(),
        // Upstream reports an absent TSA name as an empty string rather than an
        // `Option`, and "the TSA did not name itself" is not a name.
        tsa_name: (!tsa_name.is_empty()).then_some(tsa_name),
        hash_algorithm: hash_algorithm_atom(timestamp.hash_algorithm()),
        message_imprint: owned_binary(timestamp.message_imprint_ref(), "message imprint")?
            .release(env),
    })
}

fn parse_timestamp(token: &[u8]) -> NifResult<Timestamp> {
    Timestamp::from_der(trim_der_padding(token)).map_err(to_nif_err)
}

// Dirty for the same reason as the four verify/certificate/level NIFs above.
// Trimmed, unlike `signature_pades_level`: a `/DocTimeStamp` hands its padded
// `/Contents` straight here, and `der`'s `from_der` reports the tail as
// `TrailingData`.
#[rustler::nif(schedule = "DirtyCpu")]
fn timestamp_parse<'a>(env: Env<'a>, token: Binary) -> NifResult<TimestampNif<'a>> {
    timestamp_to_nif(env, &parse_timestamp(&token)?)
}

// Dirty for the same reason, and trimmed for the same reason.
//
// Two atoms rather than the three `verdict_atom` builds: upstream's `verify`
// folds `SignerVerify::Unknown` into an error, and so does a token that is not
// CMS-wrapped, both of which reach the caller as `:invalid_pdf`.
#[rustler::nif(schedule = "DirtyCpu")]
fn timestamp_verify(token: Binary) -> NifResult<Atom> {
    let verified = parse_timestamp(&token)?.verify().map_err(to_nif_err)?;

    Ok(if verified {
        atoms::valid()
    } else {
        atoms::invalid()
    })
}

// Dirty for the same reason as the NIFs above. `contents_of` rather than
// `cms_blob`, because the extraction tolerates the padding itself.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_timestamp<'a>(
    env: Env<'a>,
    contents: Option<Binary>,
) -> NifResult<Option<TimestampNif<'a>>> {
    let found = signature_timestamp_token(contents_of(contents.as_deref())?)
        .map_err(|MalformedCms(reason)| tagged_err(atoms::invalid_pdf(), reason))?;

    let Some(token) = found else {
        return Ok(None);
    };

    timestamp_to_nif(env, &parse_timestamp(&token)?).map(Some)
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

    fn infos_of(doc: &PdfDocument) -> NifResult<Vec<SignatureInfo>> {
        signature_infos(doc).map(|out| out.into_iter().map(|(info, _name)| info).collect())
    }

    // Compare only values this binding still takes from upstream.
    #[test]
    fn signatures_match_upstream_enumerate() {
        let doc = fixture("form_signature.pdf");
        let mut upstream_doc = fixture("form_signature.pdf");

        let ours = infos_of(&doc).expect("local enumeration");
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

        let ours = infos_of(&doc).expect("local enumeration");
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
        let infos = infos_of(&doc).expect("local enumeration");
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
        let infos = infos_of(&doc).expect("local enumeration");
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

    #[test]
    fn upstream_still_conflates_an_empty_dss_with_an_absent_one() {
        let present_but_unreadable = fixture("signature_dss_empty.pdf");
        let absent = fixture("sample.pdf");

        assert!(
            read_dss(&present_but_unreadable)
                .expect("read_dss succeeds")
                .is_none(),
            "upstream now distinguishes a /DSS that yielded nothing"
        );
        assert!(read_dss(&absent).expect("read_dss succeeds").is_none());
    }

    #[test]
    fn upstream_still_keys_vri_on_the_padded_contents() {
        let doc = fixture("form_signature_pades_lt.pdf");
        let store = read_dss(&doc).expect("read_dss").expect("/DSS present");

        let contents = infos_of(&doc)
            .expect("signatures read")
            .into_iter()
            .next()
            .and_then(|info| info.contents)
            .expect("a signature with /Contents");

        let key = pdf_oxide::signatures::pades::vri_key(&contents).expect("SHA-1 available");
        assert!(
            store.vri_for(&key).is_some(),
            "no /VRI entry keyed on the padded /Contents"
        );
        assert!(
            pdf_oxide::signatures::pades::vri_key(trim_der_padding(&contents))
                .is_some_and(|trimmed| store.vri_for(&trimmed).is_none()),
            "the trimmed blob now keys the same entry; the untrimmed pass-through \
             is no longer load-bearing"
        );
    }

    // Compare only well-formed CMS; malformed blobs intentionally differ because
    // this parser reports an error where the upstream classifier returns false.
    #[test]
    fn bt_timestamp_matches_upstreams_classification() {
        for (name, expected) in [
            ("form_signature_pades.pdf", PadesLevel::BB),
            ("form_signature_pades_t.pdf", PadesLevel::BT),
        ] {
            let doc = fixture(name);
            let info = infos_of(&doc)
                .expect("local enumeration")
                .pop()
                .expect("one signature");
            let contents = info.contents.clone().expect("contents");

            assert_eq!(
                classify_pades_level(&info, None),
                expected,
                "upstream now classifies {name} differently"
            );
            assert_eq!(
                signature_timestamp_token(&contents)
                    .expect("both fixtures carry well-formed CMS")
                    .is_some(),
                expected == PadesLevel::BT,
                "upstream no longer agrees with the transcribed walk on {name}"
            );
        }
    }

    // Shapes no fixture carries: a `/Contents` of no bytes at all, and a DER
    // header promising more than it holds. Neither may read as carrying no
    // timestamp. The marker blob is Elixir's, reaching the same answer.
    #[test]
    fn refuses_contents_that_are_not_a_cms_blob() {
        for blob in [b"".as_slice(), b"\x30\x82\x01\x00".as_slice()] {
            assert!(signature_timestamp_token(blob).is_err());
        }
    }

    #[test]
    fn upstream_still_rejects_a_zero_padded_timestamp_token() {
        let doc = fixture("signature_doctimestamp.pdf");
        let padded = infos_of(&doc)
            .expect("local enumeration")
            .pop()
            .expect("one signature")
            .contents
            .expect("contents");
        let trimmed = trim_der_padding(&padded);

        assert!(trimmed.len() < padded.len(), "fixture must carry padding");
        assert!(
            Timestamp::from_der(&padded).is_err(),
            "upstream now tolerates a zero-padded timestamp token"
        );
        assert!(
            Timestamp::from_der(trimmed).is_ok(),
            "the trimmed token must still parse"
        );
    }
}
