// Use the bounded field-tree walk: upstream's enumerator aborts on cyclic `/Kids`.

use std::collections::HashMap;

use cms::{
    cert::{
        x509::{name::Name, time::Time, Certificate},
        CertificateChoices,
    },
    content_info::ContentInfo,
    signed_data::{SignedData, SignerIdentifier},
};
use der::{
    asn1::{BmpString, Ia5StringRef, PrintableStringRef, TeletexStringRef, Utf8StringRef},
    oid::ObjectIdentifier,
    Any, Decode, Encode, SliceReader, Tag, Tagged,
};
use pdf_oxide::{
    object::{Object, ObjectRef},
    signatures::{
        classify_pades_level, parse_pdf_date_to_epoch, read_dss, verify_signer,
        verify_signer_detached, ByteRangeCalculator, DocumentSecurityStore, HashAlgorithm,
        PadesLevel, SignatureInfo, SignatureSubFilter, SignatureVerifier, SignerVerify, Timestamp,
        VriEntry,
    },
    PdfDocument,
};
use rustler::{Atom, Binary, Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha384, Sha512};

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

// Caller-supplied DER accepts zero padding but rejects any other readable tail.
// Pass an unreadable header through so the parser remains the validator.
fn der_value_only(bytes: &[u8]) -> Option<&[u8]> {
    match der_tlv_len(bytes) {
        Some(len) if bytes[len..].iter().all(|&byte| byte == 0) => Some(&bytes[..len]),
        Some(_) => None,
        None => Some(bytes),
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

// `id-data` — the CMS content type an `adbe.pkcs7.sha1` signature encapsulates
// its digest in (ISO 32000-1 §12.8.3.3, "ContentInfo of type Data").
const OID_ID_DATA: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.7.1");

const SHA1_DIGEST_LEN: usize = 20;

// Accept only the id-data OCTET STRING containing a SHA-1-sized digest.
fn encapsulated_sha1_digest(signed: &SignedData) -> Option<&[u8]> {
    if signed.encap_content_info.econtent_type != OID_ID_DATA {
        return None;
    }

    let econtent = signed.encap_content_info.econtent.as_ref()?;

    // `cms` represents eContent as `Any`, so enforce the specified tag here.
    if econtent.tag() != Tag::OctetString {
        return None;
    }

    let digest = econtent.value();

    (digest.len() == SHA1_DIGEST_LEN).then_some(digest)
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
//
// Verify the signer against the encapsulated digest, then compare that digest
// with SHA-1 of the covered PDF bytes. Checking the signer against those bytes
// directly reports a sound signature as an altered document.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_verify_pkcs7_sha1(
    contents: Option<Binary>,
    byte_range: Vec<i64>,
    pdf_data: Binary,
) -> NifResult<Atom> {
    let blob = cms_blob(contents.as_deref())?;
    let covered = signed_bytes(&pdf_data, &byte_range)?;
    let signed = signed_data_of(blob)
        .map_err(|MalformedCms(reason)| tagged_err(atoms::invalid_pdf(), reason))?;

    let Some(digest) = encapsulated_sha1_digest(&signed) else {
        return Ok(atoms::unknown());
    };

    match verify_signer_detached(blob, digest).map_err(to_nif_err)? {
        SignerVerify::Valid if digest_matches(HashAlgorithm::Sha1, &covered, digest) => {
            Ok(atoms::valid())
        }
        SignerVerify::Valid => Ok(atoms::invalid()),
        other => Ok(verdict_atom(other)),
    }
}

// Dirty for the same reason as `signature_verify_detached` above.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_verify_signer(contents: Option<Binary>) -> NifResult<Atom> {
    let blob = cms_blob(contents.as_deref())?;

    verify_signer(blob).map(verdict_atom).map_err(to_nif_err)
}

// Dirty for the same reason as the two verify NIFs above.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_certificate<'a>(
    env: Env<'a>,
    contents: Option<Binary>,
) -> NifResult<CertificateNif<'a>> {
    let blob = cms_blob(contents.as_deref())?;
    let certificate = signer_certificate(blob)
        .map_err(|MalformedCms(reason)| tagged_err(atoms::invalid_pdf(), reason))?;

    certificate_to_nif(env, &certificate)
}

// Takes no resource and no lock, and is dirty because decoding a certificate
// and rendering two distinguished names out of it is CPU-bound.
#[rustler::nif(schedule = "DirtyCpu")]
fn certificate_parse<'a>(env: Env<'a>, der: Binary) -> NifResult<CertificateNif<'a>> {
    let unpadded = || {
        tagged_err(
            atoms::invalid_pdf(),
            "not a DER-encoded X.509 certificate".to_string(),
        )
    };
    let certificate = der_value_only(&der)
        .ok_or_else(unpadded)
        .and_then(|der| Certificate::from_der(der).map_err(|_| unpadded()))?;

    certificate_to_nif(env, &certificate)
}

// A short, lock-free parse does not warrant dirty scheduling. Invalid and
// unrepresentable dates follow upstream's unparseable `None` result.
#[rustler::nif]
fn signature_signing_time(signing_time: Option<String>) -> Option<i64> {
    signing_time
        .as_deref()
        .filter(|date| well_formed_pdf_date(date))
        .and_then(parse_pdf_date_to_epoch)
        .filter(|secs| representable_epoch(*secs))
}

// Reject values upstream would normalize into a different date while preserving
// its accepted PDF date spellings.
fn well_formed_pdf_date(date: &str) -> bool {
    let bytes = date.strip_prefix("D:").unwrap_or(date).as_bytes();

    // Every field after the year is optional (ISO 32000-1 §7.9.4).
    let field = |start: usize, absent: u32| match bytes.len() {
        len if len <= start => Some(absent),
        len if len < start + 2 => None,
        _ => two_digits(&bytes[start..start + 2]),
    };

    let (Some(year), Some(month), Some(day)) = (
        bytes.get(..4).and_then(four_digits),
        field(4, 1),
        field(6, 1),
    ) else {
        return false;
    };
    let (Some(hour), Some(minute), Some(second)) = (field(8, 0), field(10, 0), field(12, 0)) else {
        return false;
    };

    (1..=12).contains(&month)
        && (1..=days_in_month(year, month)).contains(&day)
        && hour <= 23
        && minute <= 59
        && second <= 59
        && well_formed_offset(bytes)
}

// Do not let an unknown marker silently become UTC.
fn well_formed_offset(bytes: &[u8]) -> bool {
    let Some(marker) = bytes.get(14) else {
        return true;
    };

    match marker {
        b'Z' => true,
        b'+' | b'-' => {
            let Some(hours) = bytes.get(15..17).and_then(two_digits) else {
                return false;
            };
            // The apostrophe is optional in the wild, and so are the minutes.
            let minutes_at = if bytes.get(17) == Some(&b'\'') {
                18
            } else {
                17
            };
            let minutes = match bytes.get(minutes_at..minutes_at + 2) {
                Some(field) => two_digits(field),
                None => Some(0),
            };

            hours <= 23 && minutes.is_some_and(|minutes| minutes <= 59)
        }
        _ => false,
    }
}

fn two_digits(bytes: &[u8]) -> Option<u32> {
    match bytes {
        [tens, ones] if tens.is_ascii_digit() && ones.is_ascii_digit() => {
            Some(u32::from((tens - b'0') * 10 + (ones - b'0')))
        }
        _ => None,
    }
}

fn four_digits(bytes: &[u8]) -> Option<u32> {
    let (high, low) = (two_digits(bytes.get(..2)?)?, two_digits(bytes.get(2..)?)?);

    Some(high * 100 + low)
}

// Proleptic Gregorian, matching upstream's `days_from_civil`.
fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400)) => {
            29
        }
        2 => 28,
        _ => 0,
    }
}

// Match upstream verification's private signer selection. Its
// `SubjectKeyIdentifier` path falls back to the first certificate.
fn signer_certificate(cms: &[u8]) -> Result<Certificate, MalformedCms> {
    let signed = signed_data_of(cms)?;

    let signer = signed
        .signer_infos
        .0
        .iter()
        .next()
        .ok_or(MalformedCms("signature /Contents carries no SignerInfo"))?;
    let certificates = signed
        .certificates
        .as_ref()
        .ok_or(MalformedCms("signature /Contents carries no certificates"))?;

    let named = certificates
        .0
        .iter()
        .filter_map(as_certificate)
        .find(|cert| match &signer.sid {
            SignerIdentifier::IssuerAndSerialNumber(issuer_and_serial) => {
                cert.tbs_certificate.issuer == issuer_and_serial.issuer
                    && cert.tbs_certificate.serial_number == issuer_and_serial.serial_number
            }
            SignerIdentifier::SubjectKeyIdentifier(_) => true,
        });

    named
        .or_else(|| certificates.0.iter().filter_map(as_certificate).next())
        .cloned()
        .ok_or(MalformedCms(
            "signature /Contents carries no X.509 signer certificate",
        ))
}

fn as_certificate(choice: &CertificateChoices) -> Option<&Certificate> {
    match choice {
        CertificateChoices::Certificate(cert) => Some(cert),
        _ => None,
    }
}

#[derive(NifMap)]
pub struct CertificateNif<'a> {
    der: Binary<'a>,
    subject: Option<String>,
    subject_common_name: Option<String>,
    issuer: Option<String>,
    serial: String,
    not_before: i64,
    not_after: i64,
}

fn certificate_to_nif<'a>(
    env: Env<'a>,
    certificate: &Certificate,
) -> NifResult<CertificateNif<'a>> {
    let der = certificate.to_der().map_err(|_| {
        tagged_err(
            atoms::invalid_pdf(),
            "certificate cannot be re-encoded".to_string(),
        )
    })?;
    let tbs = &certificate.tbs_certificate;

    Ok(CertificateNif {
        der: owned_binary(&der, "certificate")?.release(env),
        subject: render_name(&tbs.subject),
        subject_common_name: common_name(&tbs.subject),
        issuer: render_name(&tbs.issuer),
        serial: hex_upper(tbs.serial_number.as_bytes()),
        not_before: validity_epoch(tbs.validity.not_before)?,
        not_after: validity_epoch(tbs.validity.not_after)?,
    })
}

// `der` decodes no certificate date outside 1970..=9999, so this cannot fire;
// it is what keeps `DateTime.from_unix!/1` on the Elixir side total anyway.
fn validity_epoch(time: Time) -> NifResult<i64> {
    i64::try_from(time.to_unix_duration().as_secs())
        .ok()
        .filter(|secs| representable_epoch(*secs))
        .ok_or_else(|| {
            tagged_err(
                atoms::invalid_pdf(),
                "certificate validity date is not a representable date".to_string(),
            )
        })
}

// `Name` renders RFC 4514 leaf-first and preserves unreadable values as `oid=#hex`.
fn render_name(name: &Name) -> Option<String> {
    let rendered = name.to_string();

    (!rendered.is_empty()).then_some(rendered)
}

// `id-at-commonName` (RFC 4519 §2.3).
const OID_COMMON_NAME: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.4.3");

// The common name nearest the leaf, which is last in encoded order and so the
// first element of the rendered name.
fn common_name(name: &Name) -> Option<String> {
    name.0
        .iter()
        .rev()
        .flat_map(|rdn| rdn.0.iter())
        .find(|attribute| attribute.oid == OID_COMMON_NAME)
        .and_then(|attribute| attribute_string(&attribute.value))
}

// Include BMPString even though `Name` renders that string form as hexadecimal.
fn attribute_string(value: &Any) -> Option<String> {
    let text = match value.tag() {
        Tag::PrintableString => PrintableStringRef::try_from(value)
            .ok()?
            .as_str()
            .to_owned(),
        Tag::Utf8String => Utf8StringRef::try_from(value).ok()?.as_str().to_owned(),
        Tag::Ia5String => Ia5StringRef::try_from(value).ok()?.as_str().to_owned(),
        Tag::TeletexString => TeletexStringRef::try_from(value).ok()?.as_str().to_owned(),
        // `BmpString` has no borrowed `*Ref`; `from_ucs2` validates its octets.
        Tag::BmpString => BmpString::from_ucs2(value.value()).ok()?.to_string(),
        _ => return None,
    };

    Some(text)
}

fn hex_upper(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02X}")).collect()
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

// The `/Type` and `/SubFilter` an archival timestamp carries (ETSI EN 319 142-1
// §5, ISO 32000-2 §12.8.5).
const DOC_TIMESTAMP_TYPE: &str = "DocTimeStamp";
const DOC_TIMESTAMP_SUB_FILTER: &str = "ETSI.RFC3161";

// `id-signedData` — the only CMS content type an RFC 3161 token is wrapped in.
const OID_SIGNED_DATA: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.7.2");

// `id-ct-TSTInfo` — what a TimeStampToken's `SignedData` must encapsulate
// (RFC 3161 §2.4.2).
const OID_CT_TSTINFO: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.16.1.4");

fn is_doctimestamp_dict(dict: &HashMap<String, Object>) -> bool {
    let name = |key: &str| dict.get(key).and_then(Object::as_name);

    name("Type") == Some(DOC_TIMESTAMP_TYPE) && name("SubFilter") == Some(DOC_TIMESTAMP_SUB_FILTER)
}

// Every entry must be an integer. Filtering the others out instead would read
// `[0 100 /Junk 200 50]` as a well-formed four-entry range.
fn byte_range_of(dict: &HashMap<String, Object>) -> Option<[i64; 4]> {
    let array = dict.get("ByteRange")?.as_array()?;
    let values: Option<Vec<i64>> = array.iter().map(Object::as_integer).collect();

    <[i64; 4]>::try_from(values?.as_slice()).ok()
}

// An archival timestamp must cover the whole file except for its own `/Contents`,
// represented by the exact `<hex>` hole that `contents` occupies.
fn covers_whole_file(range: &[i64; 4], contents: &[u8], pdf_data: &[u8]) -> bool {
    if !byte_range_fits(range, pdf_data.len()) {
        return false;
    }

    let [offset1, length1, offset2, length2] = *range;
    let Ok(size) = i64::try_from(pdf_data.len()) else {
        return false;
    };

    // `byte_range_fits` proved both spans are non-negative and end within the
    // file, so neither sum here can overflow.
    if offset1 != 0 || offset2 + length2 != size {
        return false;
    }

    let Some(hole) = contents.len().checked_mul(2).and_then(|n| n.checked_add(2)) else {
        return false;
    };
    let (Ok(start), Ok(end)) = (usize::try_from(length1), usize::try_from(offset2)) else {
        return false;
    };

    // `hole` is at least two, so the `end - 1` below cannot underflow once the
    // first comparison has held.
    end.checked_sub(start) == Some(hole)
        && pdf_data.get(start) == Some(&b'<')
        && pdf_data.get(end - 1) == Some(&b'>')
}

// Require the RFC 3161 CMS shape: SignedData containing `id-ct-TSTInfo` and at
// least one signer. This does not verify the signer or establish trust.
fn cms_wrapped_timestamp(contents: &[u8]) -> Option<Timestamp> {
    let token = trim_der_padding(contents);
    let signed = signed_data_of(token).ok()?;

    if signed.encap_content_info.econtent_type != OID_CT_TSTINFO {
        return None;
    }
    if signed.signer_infos.0.is_empty() {
        return None;
    }

    Timestamp::from_der(token).ok()
}

fn digest_matches(algorithm: HashAlgorithm, bytes: &[u8], imprint: &[u8]) -> bool {
    match algorithm {
        HashAlgorithm::Sha1 => Sha1::digest(bytes).as_slice() == imprint,
        HashAlgorithm::Sha256 => Sha256::digest(bytes).as_slice() == imprint,
        HashAlgorithm::Sha384 => Sha384::digest(bytes).as_slice() == imprint,
        HashAlgorithm::Sha512 => Sha512::digest(bytes).as_slice() == imprint,
        // An OID upstream does not recognize. Nothing can be compared, so this
        // is not a match rather than a match taken on trust.
        HashAlgorithm::Unknown => false,
    }
}

// A damaged candidate is an absence, not a document error, so a decoy cannot
// hide a valid archival timestamp elsewhere. Only an unreadable PDF is an error.
fn document_timestamp(pdf_data: &[u8]) -> NifResult<Option<Timestamp>> {
    let doc = PdfDocument::from_bytes(pdf_data.to_vec()).map_err(to_nif_err)?;

    // Try likely later objects first, but inspect the entire object inventory.
    for id in doc.all_object_ids().into_iter().rev() {
        // A free entry fails to load and the sweep moves on.
        let Ok(object) = doc.load_object(ObjectRef { id, gen: 0 }) else {
            continue;
        };
        let Some(dict) = object.as_dict() else {
            continue;
        };

        // Cheapest gates first, so the parse and the digest run at most once per
        // genuine candidate.
        if !is_doctimestamp_dict(dict) {
            continue;
        }
        let Some(range) = byte_range_of(dict) else {
            continue;
        };
        let Some(contents) = dict.get("Contents").and_then(Object::as_string) else {
            continue;
        };
        if !covers_whole_file(&range, contents, pdf_data) {
            continue;
        }
        let Some(timestamp) = cms_wrapped_timestamp(contents) else {
            continue;
        };
        let Ok(covered) = ByteRangeCalculator::extract_signed_bytes(pdf_data, &range) else {
            continue;
        };

        if digest_matches(
            timestamp.hash_algorithm(),
            &covered,
            timestamp.message_imprint_ref(),
        ) {
            return Ok(Some(timestamp));
        }
    }

    Ok(None)
}

// Dirty for its own work rather than for a lock — it takes no resource at all.
// It parses the whole document and digests the bytes a candidate covers, both of
// which scale with the file.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_document_timestamp<'a>(
    env: Env<'a>,
    pdf_data: Binary,
) -> NifResult<Option<TimestampNif<'a>>> {
    document_timestamp(&pdf_data)?
        .as_ref()
        .map(|timestamp| timestamp_to_nif(env, timestamp))
        .transpose()
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

// Decode without `finish()` so PDF signature padding is tolerated.
fn signed_data_of(cms: &[u8]) -> Result<SignedData, MalformedCms> {
    let mut reader =
        SliceReader::new(cms).map_err(|_| MalformedCms("signature /Contents is empty"))?;
    let content = ContentInfo::decode(&mut reader)
        .map_err(|_| MalformedCms("signature /Contents is not a CMS blob"))?;

    // Believe the blob is a `SignedData` because it says so, not because its
    // payload happens to decode as one. ISO 32000-2 §12.8.3.3 requires this type,
    // and without the check a `ContentInfo` declaring any other one is accepted
    // whenever its content parses.
    if content.content_type != OID_SIGNED_DATA {
        return Err(MalformedCms("signature /Contents is not CMS SignedData"));
    }

    let der = content
        .content
        .to_der()
        .map_err(|_| MalformedCms("signature /Contents holds unencodable CMS content"))?;

    SignedData::from_der(&der)
        .map_err(|_| MalformedCms("signature /Contents is not CMS SignedData"))
}

// `Ok(None)` means the blob parsed as CMS `SignedData` and carries no such
// attribute; malformed CMS or an empty attribute value is an error.
fn signature_timestamp_token(signed: &SignedData) -> Result<Option<Vec<u8>>, MalformedCms> {
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

// A B-T timestamp covers the signature octets of the same `SignerInfo` that
// carries the timestamp attribute (RFC 5126 §6.1.1), not their DER wrapper.
fn signer_signature_value(signed: &SignedData) -> Option<&[u8]> {
    signed
        .signer_infos
        .0
        .iter()
        .next()
        .map(|signer| signer.signature.as_bytes())
}

// Attachment and token authenticity are independent verdicts.
fn attachment_verdict(timestamp: &Timestamp, value: &[u8]) -> Atom {
    let algorithm = timestamp.hash_algorithm();

    if algorithm == HashAlgorithm::Unknown {
        atoms::unknown()
    } else if digest_matches(algorithm, value, timestamp.message_imprint_ref()) {
        atoms::valid()
    } else {
        atoms::invalid()
    }
}

fn no_timestamp() -> rustler::Error {
    tagged_err(
        atoms::not_found(),
        "signature carries no timestamp to check",
    )
}

// Dirty for the same reason as the verify NIFs above: a CMS parse and a digest,
// no resource and no lock.
//
// Use the same permissive token parser as `timestamp/1`; this call judges
// attachment, not token authenticity.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_verify_timestamp(contents: Option<Binary>) -> NifResult<Atom> {
    let malformed = |MalformedCms(reason)| tagged_err(atoms::invalid_pdf(), reason);

    let signed = signed_data_of(cms_blob(contents.as_deref())?).map_err(malformed)?;
    let token = signature_timestamp_token(&signed)
        .map_err(malformed)?
        .ok_or_else(no_timestamp)?;
    let value = signer_signature_value(&signed).ok_or_else(no_timestamp)?;

    Ok(attachment_verdict(&parse_timestamp(&token)?, value))
}

// Dirty for the same reason, and the same argument shape as
// `signature_verify_detached`. A document timestamp's `/Contents` is the token
// itself, and the value it is made over is the bytes its `/ByteRange` covers.
//
// Coverage extent is a separate question; this checks only the declared range.
#[rustler::nif(schedule = "DirtyCpu")]
fn signature_verify_document_timestamp(
    contents: Option<Binary>,
    byte_range: Vec<i64>,
    pdf_data: Binary,
) -> NifResult<Atom> {
    let timestamp = parse_timestamp(contents_of(contents.as_deref())?)?;
    let covered = signed_bytes(&pdf_data, &byte_range)?;

    Ok(attachment_verdict(&timestamp, &covered))
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

// The `Calendar.ISO` range accepted by `DateTime.from_unix/1`.
const MIN_EPOCH: i64 = -377_705_116_800;
const MAX_EPOCH: i64 = 253_402_300_799;

fn representable_epoch(secs: i64) -> bool {
    (MIN_EPOCH..=MAX_EPOCH).contains(&secs)
}

fn timestamp_to_nif<'a>(env: Env<'a>, timestamp: &Timestamp) -> NifResult<TimestampNif<'a>> {
    let time = timestamp.time();
    if !representable_epoch(time) {
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
    let token = der_value_only(token).ok_or_else(|| {
        tagged_err(
            atoms::invalid_pdf(),
            "trailing data after the timestamp token".to_string(),
        )
    })?;

    Timestamp::from_der(token).map_err(to_nif_err)
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
    let malformed = |MalformedCms(reason)| tagged_err(atoms::invalid_pdf(), reason);

    let signed = signed_data_of(contents_of(contents.as_deref())?).map_err(malformed)?;
    let found = signature_timestamp_token(&signed).map_err(malformed)?;

    let Some(token) = found else {
        return Ok(None);
    };

    timestamp_to_nif(env, &parse_timestamp(&token)?).map(Some)
}

#[cfg(test)]
mod tests {
    use core::str::FromStr;

    use cms::{
        cert::x509::{
            attr::AttributeTypeAndValue,
            certificate::Rfc5280,
            name::{RdnSequence, RelativeDistinguishedName},
            serial_number::SerialNumber,
        },
        signed_data::SignerInfos,
    };
    use der::{asn1::SetOfVec, Any, Tag};
    // Only the canaries reach upstream's picker now; `signer_certificate` is what
    // the NIF calls.
    use pdf_oxide::signatures::{extract_signer_certificate_der, SigningCredentials};

    use super::*;

    fn fixture(name: &str) -> PdfDocument {
        let path = format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        );

        PdfDocument::open(path).expect("fixture opens")
    }

    fn fixture_bytes(name: &str) -> Vec<u8> {
        let path = format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        );

        std::fs::read(path).expect("fixture reads")
    }

    // Never pass the cyclic fixture to upstream's enumerator; it aborts.

    fn infos_of(doc: &PdfDocument) -> NifResult<Vec<SignatureInfo>> {
        signature_infos(doc).map(|out| out.into_iter().map(|(info, _name)| info).collect())
    }

    fn signature_blob(name: &str) -> Vec<u8> {
        let doc = fixture(name);
        let contents = infos_of(&doc).expect("listing")[0]
            .contents
            .clone()
            .expect("/Contents");

        trim_der_padding(&contents).to_vec()
    }

    // Pins the upstream detached treatment that requires the local path.
    #[test]
    fn upstream_still_verifies_a_pkcs7_sha1_signature_as_detached() {
        let name = "form_signature_pkcs7_sha1.pdf";
        let pdf = fixture_bytes(name);
        let blob = signature_blob(name);
        let doc = fixture(name);
        let range = <[i64; 4]>::try_from(infos_of(&doc).expect("listing")[0].byte_range())
            .expect("four entries");
        let covered = ByteRangeCalculator::extract_signed_bytes(&pdf, &range).expect("covered");

        assert_eq!(
            verify_signer_detached(&blob, &covered).expect("upstream reads the blob"),
            SignerVerify::Invalid,
            "upstream now reads the encapsulated digest; delete the local path, not this assertion"
        );

        let signed = signed_data_of(&blob).expect("CMS SignedData");
        let digest = encapsulated_sha1_digest(&signed).expect("an encapsulated digest");

        assert_eq!(
            verify_signer_detached(&blob, digest).expect("upstream reads the blob"),
            SignerVerify::Valid
        );
        assert!(digest_matches(HashAlgorithm::Sha1, &covered, digest));
    }

    #[test]
    fn reads_only_an_id_data_octet_string_of_the_right_width() {
        let blob = signature_blob("form_signature_pkcs7_sha1.pdf");
        let signed = signed_data_of(&blob).expect("CMS SignedData");

        assert_eq!(
            encapsulated_sha1_digest(&signed).map(<[u8]>::len),
            Some(SHA1_DIGEST_LEN)
        );

        let detached = signed_data_of(&signature_blob("form_signature_cms.pdf")).expect("CMS");
        assert_eq!(encapsulated_sha1_digest(&detached), None);

        let mut mistyped = signed_data_of(&blob).expect("CMS SignedData");
        mistyped.encap_content_info.econtent_type = OID_CT_TSTINFO;
        assert_eq!(encapsulated_sha1_digest(&mistyped), None);

        let mut narrow = signed_data_of(&blob).expect("CMS SignedData");
        narrow.encap_content_info.econtent =
            Some(Any::new(Tag::OctetString, vec![0u8; SHA1_DIGEST_LEN - 1]).expect("octets"));
        assert_eq!(encapsulated_sha1_digest(&narrow), None);

        let mut retagged = signed_data_of(&blob).expect("CMS SignedData");
        retagged.encap_content_info.econtent =
            Some(Any::new(Tag::Utf8String, vec![b'a'; SHA1_DIGEST_LEN]).expect("a string"));
        assert_eq!(encapsulated_sha1_digest(&retagged), None);
    }

    #[test]
    fn upstream_still_returns_the_first_certificate_rather_than_the_signer() {
        let blob = signature_blob("form_signature_chain.pdf");

        let theirs = extract_signer_certificate_der(&blob).expect("upstream picks one");
        let ours = signer_certificate(&blob)
            .expect("the SID names one")
            .to_der()
            .expect("ours re-encodes");

        assert_ne!(
            theirs, ours,
            "upstream now matches the signer; delete signer_certificate, not this assertion"
        );
    }

    #[test]
    fn upstream_still_normalizes_an_out_of_range_pdf_date() {
        for (claim, normalizes_to) in [
            // February 31st lands on March 2nd.
            ("D:20240231000000Z", "D:20240302000000Z"),
            // An hour of 99 adds four days and three hours.
            ("D:20240101990000Z", "D:20240105030000Z"),
            // An offset of 99 hours subtracts them.
            ("D:20240101000000+99'00'", "D:20231227210000Z"),
            // A field that is present but not digits reads as an absent one.
            ("D:2024AB", "D:20240101000000Z"),
        ] {
            assert_eq!(
                parse_pdf_date_to_epoch(claim),
                parse_pdf_date_to_epoch(normalizes_to),
                "upstream now refuses {claim}; delete well_formed_pdf_date, not this assertion"
            );
        }
    }

    // No fixture carries a malformed `/M`: a signer writes the date from a clock.
    #[test]
    fn accepts_the_date_shapes_the_grammar_allows() {
        for date in [
            // Every truncation, since each field after the year is optional.
            "D:2024",
            "D:202404",
            "D:20240421",
            "D:2024042112",
            "D:202404211200",
            "D:20240421120000",
            // The `D:` prefix is optional in the wild, as upstream allows.
            "20240421120000Z",
            // Every offset spelling, including the trailing bytes after a `Z`
            // that upstream ignores and real producers emit.
            "D:20240421120000Z",
            "D:20240421120000Z00'00'",
            "D:20240421120000+03",
            "D:20240421120000+03'",
            "D:20240421120000+03'00",
            "D:20240421120000+03'00'",
            "D:20240421120000-04'30'",
            // The boundaries of each field.
            "D:20240421235959Z",
            "D:20241231000000Z",
            "D:20240421120000+23'59'",
        ] {
            assert!(well_formed_pdf_date(date), "{date}");
        }
    }

    #[test]
    fn refuses_a_date_no_clock_or_calendar_produces() {
        for date in [
            // The four shapes upstream normalizes instead of refusing.
            "D:20240231000000Z",
            "D:20240101990000Z",
            "D:20240101000000+99'00'",
            "D:2024AB",
            // A year that is not four digits at all.
            "D:20",
            "D:not-a-date",
            "",
            // Half a field, which is neither present nor absent.
            "D:202404211",
            // Out of range, one field at a time.
            "D:20241301000000Z",
            "D:20240001000000Z",
            "D:20240400000000Z",
            "D:20240421126000Z",
            "D:20240421120060Z",
            // An offset upstream would read as UTC.
            "D:20240421120000X",
            "D:20240421120000+24'00'",
            "D:20240421120000+03'60'",
            "D:20240421120000+3'00'",
            "D:20240421120000+",
        ] {
            assert!(!well_formed_pdf_date(date), "{date}");
        }
    }

    #[test]
    fn counts_february_by_the_proleptic_gregorian_rule() {
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2000, 2), 29);
        assert_eq!(days_in_month(0, 2), 29);
        assert_eq!(days_in_month(1900, 2), 28);
        assert_eq!(days_in_month(2023, 2), 28);

        assert!(well_formed_pdf_date("D:20240229000000Z"));
        assert!(!well_formed_pdf_date("D:20230229000000Z"));
        assert!(!well_formed_pdf_date("D:19000229000000Z"));
    }

    // The complement: with one certificate the first *is* the signer, so the
    // change must be a no-op for every fixture that predates it.
    #[test]
    fn signer_certificate_matches_upstream_on_a_single_certificate_blob() {
        for name in ["form_signature_cms.pdf", "form_signature_pades.pdf"] {
            let blob = signature_blob(name);

            assert_eq!(
                signer_certificate(&blob)
                    .expect("ours")
                    .to_der()
                    .expect("ours re-encodes"),
                extract_signer_certificate_der(&blob).expect("theirs"),
                "{name}"
            );
        }
    }

    fn name_of(rendered: &str) -> Name {
        Name::from_str(rendered).expect("a distinguished name")
    }

    // Signing fixtures do not cover these synthetic name shapes.
    #[test]
    fn renders_a_name_leaf_first_and_reads_the_leaf_common_name() {
        let name = name_of("CN=leaf,O=Org,C=UA");

        assert_eq!(render_name(&name).as_deref(), Some("CN=leaf,O=Org,C=UA"));
        assert_eq!(common_name(&name).as_deref(), Some("leaf"));
    }

    #[test]
    fn reads_the_common_name_nearest_the_leaf() {
        let name = name_of("CN=leaf,CN=root,C=UA");

        assert!(render_name(&name)
            .expect("rendered")
            .starts_with("CN=leaf,"));
        assert_eq!(common_name(&name).as_deref(), Some("leaf"));
    }

    // A multi-valued RDN returns its attributes in DER encoding order.
    #[test]
    fn keeps_a_multi_valued_rdn_together() {
        let name = name_of("CN=leaf+O=Org,C=UA");

        assert_eq!(render_name(&name).as_deref(), Some("O=Org+CN=leaf,C=UA"));
        assert_eq!(common_name(&name).as_deref(), Some("leaf"));
    }

    #[test]
    fn reports_a_name_that_names_nothing_as_absent() {
        let empty = Name::default();

        assert_eq!(render_name(&empty), None);
        assert_eq!(common_name(&empty), None);
    }

    #[test]
    fn reports_a_common_name_in_a_non_string_tag_as_absent() {
        let name = name_of("O=Org");

        assert_eq!(common_name(&name), None);
        assert_eq!(common_name(&non_string_common_name()), None);
        assert!(render_name(&non_string_common_name())
            .expect("rendered")
            .contains('#'));
    }

    fn non_string_common_name() -> Name {
        let attribute = AttributeTypeAndValue {
            oid: OID_COMMON_NAME,
            value: Any::new(Tag::Integer, vec![1]).expect("an integer"),
        };

        RdnSequence(vec![RelativeDistinguishedName::from(
            SetOfVec::try_from(vec![attribute]).expect("a set"),
        )])
    }

    #[test]
    fn reads_a_common_name_held_in_a_bmp_string() {
        assert_eq!(
            common_name(&bmp_string_common_name()).as_deref(),
            Some("Kü")
        );
    }

    #[test]
    fn x509_cert_still_renders_a_bmp_string_attribute_as_hex() {
        assert_eq!(
            render_name(&bmp_string_common_name()).as_deref(),
            Some("2.5.4.3=#1e04004b00fc")
        );
    }

    // "Kü" as big-endian UCS-2.
    fn bmp_string_common_name() -> Name {
        let attribute = AttributeTypeAndValue {
            oid: OID_COMMON_NAME,
            value: Any::new(Tag::BmpString, vec![0x00, 0x4B, 0x00, 0xFC]).expect("a BMPString"),
        };

        RdnSequence(vec![RelativeDistinguishedName::from(
            SetOfVec::try_from(vec![attribute]).expect("a set"),
        )])
    }

    #[test]
    fn keeps_the_sign_byte_on_a_high_bit_serial() {
        let positive = SerialNumber::<Rfc5280>::from_der(&[0x02, 0x02, 0x00, 0x80])
            .expect("a serial whose leading bit is set");

        assert_eq!(hex_upper(positive.as_bytes()), "0080");
    }

    #[test]
    fn upstream_still_renders_an_unreadable_name_as_a_placeholder() {
        let blob = signature_blob("form_signature_cms.pdf");
        let mut certificate = signer_certificate(&blob).expect("the fixture's signer");

        // A T.61 string containing non-UTF-8.
        let attribute = AttributeTypeAndValue {
            oid: OID_COMMON_NAME,
            value: Any::new(Tag::TeletexString, vec![0xE9]).expect("a T.61 string"),
        };
        certificate.tbs_certificate.subject = RdnSequence(vec![RelativeDistinguishedName::from(
            SetOfVec::try_from(vec![attribute]).expect("a set"),
        )]);

        let der = certificate.to_der().expect("re-encodes");
        let theirs = SigningCredentials::from_der(der)
            .expect("upstream reads the certificate")
            .subject()
            .expect("upstream renders a subject");

        assert_eq!(
            theirs, "<X509Error: Invalid X.509 name>",
            "upstream now renders the name; delete render_name, not this assertion"
        );
        assert_eq!(
            render_name(&certificate.tbs_certificate.subject).as_deref(),
            Some("2.5.4.3=#1401e9")
        );
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
        assert_eq!(der_value_only(&blob), Some(&blob[..]));
    }

    #[test]
    fn accepts_only_a_zero_tail_after_a_caller_supplied_value() {
        let value = [0x30, 0x03, 1, 2, 3];

        assert_eq!(der_value_only(&value), Some(&value[..]));
        assert_eq!(
            der_value_only(&[0x30, 0x03, 1, 2, 3, 0, 0]),
            Some(&value[..])
        );
        assert_eq!(der_value_only(&[0x30, 0x03, 1, 2, 3, 1]), None);
        assert_eq!(der_value_only(&[0x30, 0x03, 1, 2, 3, 0, 1, 0]), None);
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
    fn recognizes_only_a_dictionary_typed_as_an_archival_timestamp() {
        let dict = |entries: &[(&str, &str)]| {
            entries
                .iter()
                .map(|(key, name)| ((*key).to_string(), Object::Name((*name).to_string())))
                .collect::<HashMap<_, _>>()
        };

        assert!(is_doctimestamp_dict(&dict(&[
            ("Type", "DocTimeStamp"),
            ("SubFilter", "ETSI.RFC3161"),
        ])));

        // An ordinary document timestamp field's sub-filter on a signature: the
        // pair the byte scan cannot tell from the real thing.
        assert!(!is_doctimestamp_dict(&dict(&[
            ("Type", "Sig"),
            ("SubFilter", "ETSI.RFC3161"),
        ])));
        assert!(!is_doctimestamp_dict(&dict(&[
            ("Type", "DocTimeStamp"),
            ("SubFilter", "ETSI.CAdES.detached"),
        ])));
        assert!(!is_doctimestamp_dict(&dict(&[("Type", "DocTimeStamp")])));
        assert!(!is_doctimestamp_dict(&HashMap::new()));
    }

    // A file whose bytes 100..200 are a well-formed hex string for `contents`,
    // which is the hole a genuine `/ByteRange` excludes.
    fn file_with_hex_hole(contents: &[u8], size: usize) -> Vec<u8> {
        let mut pdf = vec![b'x'; size];
        let hex = contents
            .iter()
            .flat_map(|b| format!("{b:02X}").into_bytes());

        pdf[100] = b'<';
        for (at, byte) in hex.enumerate() {
            pdf[101 + at] = byte;
        }
        pdf[100 + contents.len() * 2 + 1] = b'>';
        pdf
    }

    #[test]
    fn accepts_only_a_byte_range_reaching_both_ends_of_the_file() {
        // 49 bytes of `/Contents` fill a 100-byte hole from 100 to 200.
        let contents = vec![0xAB; 49];
        let pdf = file_with_hex_hole(&contents, 300);

        assert!(covers_whole_file(&[0, 100, 200, 100], &contents, &pdf));

        // One byte short of the end — an earlier revision's timestamp.
        assert!(!covers_whole_file(&[0, 100, 200, 99], &contents, &pdf));
        // Starts past byte zero.
        assert!(!covers_whole_file(&[1, 99, 200, 100], &contents, &pdf));
        // The spans overlap rather than straddling a hole.
        assert!(!covers_whole_file(&[0, 250, 200, 100], &contents, &pdf));
        // Wrap-around inputs `byte_range_fits` is what refuses.
        assert!(!covers_whole_file(&[0, -1, 0, 300], &contents, &pdf));
        assert!(!covers_whole_file(&[0, 0, 0, i64::MAX], &contents, &pdf));
    }

    // Reach both ends while excluding a hole wider than `/Contents`.
    #[test]
    fn refuses_a_hole_wider_than_its_own_contents() {
        let contents = vec![0xAB; 49];
        let pdf = file_with_hex_hole(&contents, 300);

        // One byte too wide at either end, both ends still reached.
        assert!(!covers_whole_file(&[0, 99, 200, 100], &contents, &pdf));
        assert!(!covers_whole_file(&[0, 100, 201, 99], &contents, &pdf));
        // Wide enough to swallow most of the file.
        assert!(!covers_whole_file(&[0, 10, 290, 10], &contents, &pdf));

        // The right width, but the hole is not a hex string — so it is some
        // other run of bytes the same size as this `/Contents`.
        let plain = vec![b'x'; 300];
        assert!(!covers_whole_file(&[0, 100, 200, 100], &contents, &plain));
    }

    #[test]
    fn reads_a_byte_range_only_when_every_entry_is_an_integer() {
        let range = |objects: Vec<Object>| {
            let mut dict = HashMap::new();
            dict.insert("ByteRange".to_string(), Object::Array(objects));
            byte_range_of(&dict)
        };
        let int = |n: i64| Object::Integer(n);

        assert_eq!(
            range(vec![int(0), int(1), int(2), int(3)]),
            Some([0, 1, 2, 3])
        );

        // Four integers and a name: filtering the name away would read this as
        // a well-formed range.
        assert_eq!(
            range(vec![
                int(0),
                int(1),
                Object::Name("Junk".to_string()),
                int(2),
                int(3),
            ]),
            None
        );
        assert_eq!(range(vec![int(0), int(1), int(2)]), None);
        assert_eq!(range(Vec::new()), None);
    }

    #[test]
    fn upstream_still_over_reports_a_document_timestamp() {
        let decoy = fixture_bytes("signature_doctimestamp_decoy.pdf");

        assert!(
            pdf_oxide::signatures::has_document_timestamp(&decoy),
            "upstream no longer over-reports this decoy"
        );
        assert!(
            document_timestamp(&decoy)
                .expect("the decoy is a readable PDF")
                .is_none(),
            "the decoy carries no archival timestamp"
        );
    }

    #[test]
    fn finds_the_archival_timestamp_a_real_one_carries() {
        let lta = fixture_bytes("form_signature_pades_lta.pdf");

        assert!(document_timestamp(&lta)
            .expect("the fixture is a readable PDF")
            .is_some());
    }

    // The fixture preserves the real range and imprint but replaces the token
    // with its unsigned `TSTInfo`.
    #[test]
    fn refuses_a_token_nobody_signed() {
        let unsigned = fixture_bytes("signature_doctimestamp_unsigned.pdf");

        assert!(document_timestamp(&unsigned)
            .expect("still a readable PDF")
            .is_none());
    }

    // Empty only the signer set so the test isolates that gate.
    #[test]
    fn refuses_a_cms_wrapper_carrying_no_signer() {
        let token = signature_blob("signature_doctimestamp_covering.pdf");

        assert!(
            cms_wrapped_timestamp(&token).is_some(),
            "the untouched token reads, so the refusal below is about the signer"
        );

        let mut signed = signed_data_of(&token).expect("a real timestamp token");
        signed.signer_infos = SignerInfos(Default::default());

        let signerless = ContentInfo {
            content_type: OID_SIGNED_DATA,
            content: Any::encode_from(&signed).expect("re-encodes"),
        }
        .to_der()
        .expect("re-encodes");

        assert!(cms_wrapped_timestamp(&signerless).is_none());
    }

    // A real token over the bytes this `/ByteRange` actually covers, so the
    // imprint matches and only the width of the excluded hole separates it from
    // an archival timestamp.
    #[test]
    fn refuses_a_timestamp_excluding_more_than_its_contents() {
        let gapped = fixture_bytes("signature_doctimestamp_gapped.pdf");

        assert!(document_timestamp(&gapped)
            .expect("still a readable PDF")
            .is_none());
    }

    // Alter a covered byte without changing any offsets.
    #[test]
    fn loses_the_archival_timestamp_when_a_covered_byte_changes() {
        let mut lta = fixture_bytes("form_signature_pades_lta.pdf");

        // `(Alice)` is the ordinary text field's value, well inside the first
        // covered span; a same-length edit keeps every offset valid.
        let at = lta
            .windows(7)
            .position(|w| w == b"(Alice)")
            .expect("the text field's value");
        lta[at + 5] = b'f';

        assert!(document_timestamp(&lta)
            .expect("still a readable PDF")
            .is_none());
    }

    // A same-length OID edit preserves the DER shape and isolates the declared
    // content-type check.
    #[test]
    fn refuses_a_blob_whose_content_type_is_not_signed_data() {
        const SIGNED_DATA: &[u8] = &[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02];

        let blob = signature_blob("form_signature_cms.pdf");
        let at = blob
            .windows(SIGNED_DATA.len())
            .position(|w| w == SIGNED_DATA)
            .expect("the outer content type");

        assert_eq!(
            blob.windows(SIGNED_DATA.len())
                .filter(|w| *w == SIGNED_DATA)
                .count(),
            1,
            "id-signedData is no longer unique in this blob; the swap below is ambiguous"
        );
        assert!(signed_data_of(&blob).is_ok(), "the untouched blob reads");

        let mut mistyped = blob.clone();
        mistyped[at + SIGNED_DATA.len() - 1] = 0x01;

        assert!(signed_data_of(&mistyped).is_err());
    }

    #[test]
    fn upstream_still_reads_a_mistyped_timestamp_token() {
        const TSTINFO: &[u8] = &[
            0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x01, 0x04,
        ];

        let token = signature_blob("signature_doctimestamp.pdf");

        // Twice: the encapsulated content type, then the signed `content-type`
        // attribute. DER puts `encapContentInfo` before `signerInfos`, so the
        // first is the one this gate reads.
        assert_eq!(
            token
                .windows(TSTINFO.len())
                .filter(|w| *w == TSTINFO)
                .count(),
            2,
            "id-ct-TSTInfo is no longer twice in this token; the swap below moves the wrong one"
        );
        let at = token
            .windows(TSTINFO.len())
            .position(|w| w == TSTINFO)
            .expect("the encapsulated content type");
        assert!(
            cms_wrapped_timestamp(&token).is_some(),
            "the real token reads"
        );

        let mut mistyped = token.clone();
        mistyped[at + TSTINFO.len() - 1] = 0x05;

        assert!(
            Timestamp::from_der(&mistyped).is_ok(),
            "upstream now checks the encapsulated content type"
        );
        assert!(cms_wrapped_timestamp(&mistyped).is_none());
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
            let signed = signed_data_of(&contents).expect("both fixtures carry well-formed CMS");

            assert_eq!(
                signature_timestamp_token(&signed)
                    .expect("the walk reads a well-formed SignedData")
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
            assert!(signed_data_of(blob).is_err());
        }
    }

    // Assert content octets rather than their `04 <len>` DER wrapper.
    #[test]
    fn reads_the_signature_octets_the_signer_wrote() {
        let blob = signature_blob("form_signature_cms.pdf");
        let signed = signed_data_of(&blob).expect("a well-formed CMS blob");
        let value = signer_signature_value(&signed).expect("one SignerInfo");

        assert_eq!(value.len(), 256, "RSA-2048 signs 256 bytes");
        assert!(
            blob.windows(value.len()).any(|w| w == value),
            "the signature octets are not in the blob verbatim; as_bytes may have \
             started returning the DER TLV"
        );
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
