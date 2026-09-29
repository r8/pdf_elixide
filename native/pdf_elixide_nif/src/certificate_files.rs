// Certificates read out of PEM text and PKCS#12 files. Only certificates are
// read: a key block or key bag is never decoded, let alone decrypted.

use std::collections::{HashMap, HashSet};

use cbc::cipher::{block_padding::Pkcs7, BlockCipherDecrypt, BlockModeDecrypt, KeyInit, KeyIvInit};
use cms::{
    cert::x509::{
        ext::pkix::{AuthorityKeyIdentifier, SubjectKeyIdentifier},
        Certificate,
    },
    content_info::ContentInfo,
    encrypted_data::EncryptedData,
};
use der::{
    asn1::{ContextSpecific, OctetString},
    oid::{AssociatedOid, ObjectIdentifier},
    Decode, Encode,
};
use des::TdesEde3;
use hmac::{Hmac, Mac};
use pkcs12::{
    kdf::{self, Pkcs12KeyType},
    pbe_params::{Pbes2Params, Pkcs12PbeParams},
    pfx::{Pfx, Version},
    safe_bag::SafeContents,
    AuthenticatedSafe, CertBag, MacData, SafeBag, PKCS_12_CERT_BAG_OID, PKCS_12_KEY_BAG_OID,
    PKCS_12_PBEWITH_SHAAND40_BIT_RC2_CBC, PKCS_12_PBE_WITH_SHAAND3_KEY_TRIPLE_DES_CBC,
    PKCS_12_PKCS8_KEY_BAG_OID, PKCS_12_SAFE_CONTENTS_BAG_OID, PKCS_12_X509_CERT_OID,
};
use pkcs5::pbes2;
use rc2::Rc2;
use sha1::Sha1;
use sha2::Sha256;

// Keep the loaders BEAM-independent; the reason atom is built at the NIF boundary.
#[derive(Debug, PartialEq)]
pub(crate) enum CertificateRefusal {
    Malformed(String),
    WrongPassword,
    NoCertificate(&'static str),
    Unsupported(String),
}

use CertificateRefusal::{Malformed, NoCertificate, Unsupported, WrongPassword};

// RFC 7468 §5.1 asks parsers to accept the two legacy spellings too.
const PEM_CERTIFICATE_LABELS: [&[u8]; 3] =
    [b"CERTIFICATE", b"X509 CERTIFICATE", b"X.509 CERTIFICATE"];

pub(crate) fn pem_certificates(input: &[u8]) -> Result<Vec<Certificate>, CertificateRefusal> {
    const BEGIN: &[u8] = b"-----BEGIN ";
    const DASHES: &[u8] = b"-----";

    let mut certificates = Vec::new();
    let mut at = 0;

    // Only certificate boundaries are recognized, so another block cannot fail
    // the call however it is shaped. One linear pass: each step moves `at` on.
    while let Some(offset) = find_bytes(&input[at..], BEGIN) {
        let start = at + offset;
        let after = &input[start + BEGIN.len()..];
        let label = PEM_CERTIFICATE_LABELS.into_iter().find(|label| {
            after
                .strip_prefix(*label)
                .is_some_and(|rest| rest.starts_with(DASHES))
        });

        let Some(label) = label else {
            at = start + BEGIN.len();
            continue;
        };

        let block = &input[start..];
        let end_marker = [b"-----END ", label, DASHES].concat();
        let end = find_bytes(block, &end_marker)
            .ok_or_else(|| Malformed("unterminated PEM CERTIFICATE block".to_string()))?
            + end_marker.len();

        certificates.push(pem_certificate(&block[..end])?);
        at = start + end;
    }

    if certificates.is_empty() {
        return Err(NoCertificate("the PEM input holds no CERTIFICATE block"));
    }

    Ok(certificates)
}

fn pem_certificate(block: &[u8]) -> Result<Certificate, CertificateRefusal> {
    let mut der = Vec::new();

    // Detect the wrap width: Java tools emit 76 columns where OpenSSL emits 64.
    der::pem::Decoder::new_detect_wrap(block)
        .and_then(|mut decoder| decoder.decode_to_end(&mut der).map(|_| ()))
        .map_err(|error| Malformed(format!("malformed PEM block: {error}")))?;

    Certificate::from_der(&der).map_err(|_| {
        Malformed("a PEM CERTIFICATE block is not a DER-encoded X.509 certificate".to_string())
    })
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

// Bound the attacker-controlled work across every derivation in one call.
const KDF_ITERATION_BUDGET: u64 = 10_000_000;

const ID_DATA: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.7.1");
const ID_ENCRYPTED_DATA: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.7.6");
const ID_SHA1: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.14.3.2.26");
const ID_SHA256: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.2.1");
// What this build's `pkcs5` decrypts; anything else is reported unsupported
// rather than malformed.
const PBES2_CIPHERS: [ObjectIdentifier; 5] = [
    pbes2::AES_128_CBC_OID,
    pbes2::AES_192_CBC_OID,
    pbes2::AES_256_CBC_OID,
    pbes2::AES_128_GCM_OID,
    pbes2::AES_256_GCM_OID,
];

// Each level is decoded again from its parent's bytes and recursed into, so the
// cap is what keeps crafted nesting from costing quadratic work or the stack.
const MAX_SAFE_CONTENTS_DEPTH: usize = 8;
const LOCAL_KEY_ID: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.21");

pub(crate) fn pkcs12_certificates(
    data: &[u8],
    password: &str,
) -> Result<Vec<Certificate>, CertificateRefusal> {
    pkcs12_certificates_within(data, password, KDF_ITERATION_BUDGET)
}

fn pkcs12_certificates_within(
    data: &[u8],
    password: &str,
    budget: u64,
) -> Result<Vec<Certificate>, CertificateRefusal> {
    let mut budget = Budget(budget);
    let pfx = Pfx::from_der(data).map_err(|_| malformed("not a PKCS#12 file"))?;

    if pfx.version != Version::V3 {
        return Err(malformed("not a version 3 PKCS#12 file"));
    }

    if pfx.auth_safe.content_type != ID_DATA {
        return Err(Unsupported(
            "a PKCS#12 file protected by a public-key signature is not supported".to_string(),
        ));
    }

    let auth_safe = octet_string_content(&pfx.auth_safe)?;

    if let Some(mac) = &pfx.mac_data {
        verify_mac(mac, password, &auth_safe, &mut budget)?;
    }

    let safes = AuthenticatedSafe::from_der(&auth_safe)
        .map_err(|_| malformed("malformed PKCS#12 authenticated safe"))?;
    let mut found = Found::default();

    for safe in &safes {
        let contents = match safe.content_type {
            ID_DATA => octet_string_content(safe)?,
            ID_ENCRYPTED_DATA => match decrypt_safe(safe, password, &mut budget)? {
                Some(contents) => contents,
                None => continue,
            },
            _ => {
                return Err(Unsupported(
                    "a PKCS#12 safe protected by public-key encryption is not supported"
                        .to_string(),
                ))
            }
        };

        let bags = SafeContents::from_der(&contents)
            .map_err(|_| malformed("malformed PKCS#12 safe contents"))?;
        found.read(&bags, 0)?;
    }

    found.into_order()
}

fn malformed(reason: &str) -> CertificateRefusal {
    Malformed(reason.to_string())
}

struct Budget(u64);

impl Budget {
    // Charged before the derivation runs, so a refused count costs nothing.
    fn charge(&mut self, iterations: i64) -> Result<(), CertificateRefusal> {
        let iterations = u64::try_from(iterations)
            .ok()
            .filter(|&count| count > 0)
            .ok_or_else(|| malformed("PKCS#12 iteration count below 1"))?;

        self.0 = self.0.checked_sub(iterations).ok_or_else(|| {
            Unsupported(
                "the PKCS#12 file asks for more key-derivation work than this library performs"
                    .to_string(),
            )
        })?;

        Ok(())
    }
}

fn octet_string_content(info: &ContentInfo) -> Result<Vec<u8>, CertificateRefusal> {
    info.content
        .to_der()
        .ok()
        .and_then(|der| OctetString::from_der(&der).ok())
        .map(|octets| octets.into_bytes().into_vec())
        .ok_or_else(|| malformed("malformed PKCS#12 data content"))
}

fn verify_mac(
    mac: &MacData,
    password: &str,
    data: &[u8],
    budget: &mut Budget,
) -> Result<(), CertificateRefusal> {
    budget.charge(mac.iterations.into())?;

    let salt = mac.mac_salt.as_bytes();
    let expected = mac.mac.digest.as_bytes();
    let rounds = mac.iterations;

    let verified = match mac.mac.algorithm.oid {
        ID_SHA1 => {
            let key = derive::<Sha1>(password, salt, Pkcs12KeyType::Mac, rounds, 20)?;
            Hmac::<Sha1>::new_from_slice(&key)
                .map(|hmac| hmac.chain_update(data).verify_slice(expected).is_ok())
        }
        ID_SHA256 => {
            let key = derive::<Sha256>(password, salt, Pkcs12KeyType::Mac, rounds, 32)?;
            Hmac::<Sha256>::new_from_slice(&key)
                .map(|hmac| hmac.chain_update(data).verify_slice(expected).is_ok())
        }
        _ => {
            return Err(Unsupported(
                "the PKCS#12 file uses an unsupported integrity algorithm".to_string(),
            ))
        }
    };

    match verified {
        Ok(true) => Ok(()),
        Ok(false) => Err(WrongPassword),
        Err(_) => Err(malformed("malformed PKCS#12 integrity data")),
    }
}

fn derive<D>(
    password: &str,
    salt: &[u8],
    id: Pkcs12KeyType,
    rounds: i32,
    len: usize,
) -> Result<Vec<u8>, CertificateRefusal>
where
    D: kdf_digest::Digest + kdf_digest::FixedOutputReset + kdf_digest::block_api::BlockSizeUser,
{
    kdf::derive_key_utf8::<D>(password, salt, id, rounds, len).map_err(|_| {
        Unsupported("the password holds a character PKCS#12 cannot encode".to_string())
    })
}

// `sha1` re-exports the `digest` version the PKCS#12 KDF is written against.
use sha1::digest as kdf_digest;

// An encrypted safe with no content holds no bags.
fn decrypt_safe(
    safe: &ContentInfo,
    password: &str,
    budget: &mut Budget,
) -> Result<Option<Vec<u8>>, CertificateRefusal> {
    let encrypted = safe
        .content
        .to_der()
        .ok()
        .and_then(|der| EncryptedData::from_der(&der).ok())
        .ok_or_else(|| malformed("malformed PKCS#12 encrypted safe"))?;
    let info = &encrypted.enc_content_info;

    let Some(ciphertext) = info.encrypted_content.as_ref() else {
        return Ok(None);
    };

    let parameters = info
        .content_enc_alg
        .parameters
        .as_ref()
        .and_then(|any| any.to_der().ok())
        .ok_or_else(|| malformed("PKCS#12 encryption parameters are missing"))?;
    let ciphertext = ciphertext.as_bytes();

    let decrypted = match info.content_enc_alg.oid {
        pbes2::PBES2_OID => {
            // `pkcs5` refuses an algorithm it does not know as undecodable, so
            // classify the two identifiers first to tell "unsupported" from
            // "malformed".
            let identifiers = Pbes2Params::from_der(&parameters)
                .map_err(|_| malformed("malformed PBES2 parameters"))?;

            if identifiers.kdf.oid != pbes2::PBKDF2_OID {
                return Err(Unsupported(format!(
                    "PKCS#12 key derivation {} is not supported",
                    identifiers.kdf.oid
                )));
            }

            if !PBES2_CIPHERS.contains(&identifiers.encryption.oid) {
                return Err(Unsupported(format!(
                    "PKCS#12 encryption scheme {} is not supported",
                    identifiers.encryption.oid
                )));
            }

            let parameters = pbes2::Parameters::from_der(&parameters)
                .map_err(|_| malformed("malformed PBES2 parameters"))?;
            let pbkdf2 = parameters
                .kdf
                .pbkdf2()
                .ok_or_else(|| malformed("malformed PBES2 parameters"))?;
            budget.charge(pbkdf2.iteration_count.into())?;

            match parameters.decrypt(password.as_bytes(), ciphertext) {
                Ok(plaintext) => Some(plaintext),
                Err(pkcs5::Error::UnsupportedAlgorithm { oid }) => {
                    return Err(Unsupported(format!(
                        "PKCS#12 algorithm {oid} is not supported"
                    )))
                }
                Err(_) => None,
            }
        }
        oid @ (PKCS_12_PBE_WITH_SHAAND3_KEY_TRIPLE_DES_CBC
        | PKCS_12_PBEWITH_SHAAND40_BIT_RC2_CBC) => {
            let parameters = Pkcs12PbeParams::from_der(&parameters)
                .map_err(|_| malformed("malformed PKCS#12 PBE parameters"))?;
            // Two derivations: the key, then the IV.
            budget.charge(parameters.iterations.into())?;
            budget.charge(parameters.iterations.into())?;

            let (salt, rounds) = (parameters.salt.as_bytes(), parameters.iterations);

            if oid == PKCS_12_PBE_WITH_SHAAND3_KEY_TRIPLE_DES_CBC {
                pbes1_decrypt::<TdesEde3>(ciphertext, password, salt, rounds, 24)?
            } else {
                pbes1_decrypt::<Rc2>(ciphertext, password, salt, rounds, 5)?
            }
        }
        _ => {
            return Err(Unsupported(
                "the PKCS#12 file uses an unsupported encryption scheme".to_string(),
            ))
        }
    };

    decrypted
        .map(Some)
        .ok_or_else(|| malformed("PKCS#12 decryption failed"))
}

// The PKCS#12 PBE of RFC 7292 Appendix B: KDF-derived key and IV, then CBC.
fn pbes1_decrypt<T>(
    ciphertext: &[u8],
    password: &str,
    salt: &[u8],
    rounds: i32,
    key_len: usize,
) -> Result<Option<Vec<u8>>, CertificateRefusal>
where
    T: KeyInit + BlockCipherDecrypt,
{
    let key = derive::<Sha1>(
        password,
        salt,
        Pkcs12KeyType::EncryptionKey,
        rounds,
        key_len,
    )?;
    let iv = derive::<Sha1>(password, salt, Pkcs12KeyType::Iv, rounds, 8)?;

    Ok(cbc::Decryptor::<T>::new_from_slices(&key, &iv)
        .ok()
        .and_then(|cipher| cipher.decrypt_padded_vec::<Pkcs7>(ciphertext).ok()))
}

// Certificates in file order, with the key IDs they pair with. Nothing is keyed
// by an alias, so certificates sharing a subject or friendly name all survive.
#[derive(Default)]
struct Found {
    certificates: Vec<FoundCertificate>,
    key_ids: HashSet<Vec<u8>>,
}

struct FoundCertificate {
    certificate: Certificate,
    local_key_id: Option<Vec<u8>>,
    subject: Vec<u8>,
    issuer: Vec<u8>,
    key_id: Option<Vec<u8>>,
    authority_key_id: Option<Vec<u8>>,
}

// Unconsumed candidates for one lookup key, in file order. The cursor only
// moves forward past emitted certificates, which keeps the walk linear.
#[derive(Default)]
struct Candidates {
    indices: Vec<usize>,
    cursor: usize,
}

impl Candidates {
    fn next(&mut self, emitted: &[bool]) -> Option<usize> {
        while self
            .indices
            .get(self.cursor)
            .is_some_and(|&index| emitted[index])
        {
            self.cursor += 1;
        }

        self.indices.get(self.cursor).copied()
    }
}

impl Found {
    fn read(&mut self, bags: &[SafeBag], depth: usize) -> Result<(), CertificateRefusal> {
        for bag in bags {
            match bag.bag_id {
                PKCS_12_CERT_BAG_OID => {
                    let bag_value = ContextSpecific::<CertBag>::from_der(&bag.bag_value)
                        .map_err(|_| malformed("malformed PKCS#12 certificate bag"))?
                        .value;

                    if bag_value.cert_id != PKCS_12_X509_CERT_OID {
                        continue;
                    }

                    self.certificates.push(found_certificate(
                        bag_value.cert_value.as_bytes(),
                        local_key_id(bag),
                    )?);
                }
                // Only the attribute is read; the key itself stays untouched.
                PKCS_12_KEY_BAG_OID | PKCS_12_PKCS8_KEY_BAG_OID => {
                    self.key_ids.extend(local_key_id(bag));
                }
                PKCS_12_SAFE_CONTENTS_BAG_OID => {
                    if depth == MAX_SAFE_CONTENTS_DEPTH {
                        return Err(Unsupported(format!(
                            "PKCS#12 safe contents nested deeper than {MAX_SAFE_CONTENTS_DEPTH} levels"
                        )));
                    }

                    let nested = ContextSpecific::<SafeContents>::from_der(&bag.bag_value)
                        .map_err(|_| malformed("malformed PKCS#12 nested safe contents"))?
                        .value;
                    self.read(&nested, depth + 1)?;
                }
                _ => {}
            }
        }

        Ok(())
    }

    // Put certificates paired with keys and their available issuers first, then
    // the rest in file order. Each step emits a new certificate, so cycles stop;
    // key identifiers narrow ambiguous names. This verifies no signature.
    fn into_order(self) -> Result<Vec<Certificate>, CertificateRefusal> {
        let Found {
            certificates,
            key_ids,
        } = self;

        if certificates.is_empty() {
            return Err(NoCertificate("the PKCS#12 file holds no certificate"));
        }

        let mut by_subject: HashMap<&[u8], Candidates> = HashMap::new();
        let mut by_subject_and_key: HashMap<(&[u8], &[u8]), Candidates> = HashMap::new();
        let mut by_subject_without_key: HashMap<&[u8], Candidates> = HashMap::new();

        for (index, found) in certificates.iter().enumerate() {
            let subject = found.subject.as_slice();
            by_subject.entry(subject).or_default().indices.push(index);

            let candidates = match &found.key_id {
                Some(key_id) => by_subject_and_key.entry((subject, key_id)).or_default(),
                None => by_subject_without_key.entry(subject).or_default(),
            };
            candidates.indices.push(index);
        }

        let mut emitted = vec![false; certificates.len()];
        let mut order = Vec::with_capacity(certificates.len());

        for index in 0..certificates.len() {
            let keyed = certificates[index]
                .local_key_id
                .as_ref()
                .is_some_and(|id| key_ids.contains(id));

            if !keyed || emitted[index] {
                continue;
            }

            let mut current = index;

            loop {
                emitted[current] = true;
                order.push(current);

                let found = &certificates[current];
                let issuer = found.issuer.as_slice();
                let self_issued = found.issuer == found.subject;
                let authority_key_id = found.authority_key_id.as_deref();

                // A self-issued certificate is followed only through a key
                // identifier naming another key: a key-rollover link names its
                // previous one, and nothing else tells that issuer apart from
                // every certificate of the same name.
                let by_key = authority_key_id
                    .filter(|key_id| !self_issued || found.key_id.as_deref() != Some(*key_id))
                    .and_then(|key_id| by_subject_and_key.get_mut(&(issuer, key_id)))
                    .and_then(|candidates| candidates.next(&emitted));

                let next = match (self_issued, authority_key_id) {
                    (true, _) => by_key,
                    (false, Some(_)) => by_key.or_else(|| {
                        by_subject_without_key
                            .get_mut(issuer)
                            .and_then(|candidates| candidates.next(&emitted))
                    }),
                    (false, None) => by_subject
                        .get_mut(issuer)
                        .and_then(|candidates| candidates.next(&emitted)),
                };

                match next {
                    Some(next) => current = next,
                    None => break,
                }
            }
        }

        order.extend((0..certificates.len()).filter(|&index| !emitted[index]));

        let mut certificates: Vec<Option<Certificate>> = certificates
            .into_iter()
            .map(|found| Some(found.certificate))
            .collect();

        Ok(order
            .into_iter()
            .filter_map(|index| certificates[index].take())
            .collect())
    }
}

fn found_certificate(
    der: &[u8],
    local_key_id: Option<Vec<u8>>,
) -> Result<FoundCertificate, CertificateRefusal> {
    let certificate = Certificate::from_der(der)
        .map_err(|_| malformed("a PKCS#12 certificate is not a DER-encoded X.509 certificate"))?;
    let tbs = certificate.tbs_certificate();
    let (subject, issuer) = tbs
        .subject()
        .to_der()
        .and_then(|subject| Ok((subject, tbs.issuer().to_der()?)))
        .map_err(|_| malformed("a PKCS#12 certificate name cannot be re-encoded"))?;

    let extension = |oid| {
        tbs.extensions()?
            .iter()
            .find(|extension| extension.extn_id == oid)
            .map(|extension| extension.extn_value.as_bytes())
    };
    // An identifier that does not decode only loses its tie-break in ordering.
    let key_id = extension(SubjectKeyIdentifier::OID)
        .and_then(|value| SubjectKeyIdentifier::from_der(value).ok())
        .map(|identifier| identifier.0.as_bytes().to_vec());
    let authority_key_id = extension(AuthorityKeyIdentifier::OID)
        .and_then(|value| AuthorityKeyIdentifier::from_der(value).ok())
        .and_then(|identifier| identifier.key_identifier)
        .map(|identifier| identifier.as_bytes().to_vec());

    Ok(FoundCertificate {
        certificate,
        local_key_id,
        subject,
        issuer,
        key_id,
        authority_key_id,
    })
}

fn local_key_id(bag: &SafeBag) -> Option<Vec<u8>> {
    bag.bag_attributes
        .as_ref()?
        .iter()
        .find(|attribute| attribute.oid == LOCAL_KEY_ID)?
        .values
        .iter()
        .next()
        .map(|value| value.value().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_bytes(name: &str) -> Vec<u8> {
        let path = format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        );

        std::fs::read(path).expect("fixture reads")
    }

    fn fixture_certificates() -> Vec<Certificate> {
        pem_certificates(&fixture_bytes("certificate_chain.pem")).expect("fixture chain")
    }

    fn pem_block(label: &str, der: &[u8], width: usize, eol: &str) -> Vec<u8> {
        let body = der::pem::encode_string(label, der::pem::LineEnding::LF, der).expect("encodes");
        let base64: String = body
            .lines()
            .filter(|line| !line.starts_with("-----"))
            .collect();
        let lines: Vec<&str> = base64
            .as_bytes()
            .chunks(width)
            .map(|chunk| std::str::from_utf8(chunk).expect("ascii"))
            .collect();

        format!(
            "-----BEGIN {label}-----{eol}{}{eol}-----END {label}-----{eol}",
            lines.join(eol)
        )
        .into_bytes()
    }

    #[test]
    fn pem_reads_crlf_and_76_column_blocks() {
        let [leaf, intermediate, ..] = &fixture_certificates()[..] else {
            panic!("fixture carries a chain");
        };
        let mut input = b"explanatory text\r\n".to_vec();
        input.extend(pem_block(
            "CERTIFICATE",
            &leaf.to_der().unwrap(),
            76,
            "\r\n",
        ));
        input.extend(pem_block(
            "X509 CERTIFICATE",
            &intermediate.to_der().unwrap(),
            64,
            "\n",
        ));

        assert_eq!(
            pem_certificates(&input),
            Ok(vec![leaf.clone(), intermediate.clone()])
        );
    }

    #[test]
    fn pem_refuses_an_unterminated_or_mismatched_certificate_block() {
        let leaf = fixture_certificates().remove(0);
        let block = pem_block("CERTIFICATE", &leaf.to_der().unwrap(), 64, "\n");
        let text = String::from_utf8(block).unwrap();

        for broken in [
            text.replace("-----END CERTIFICATE-----\n", ""),
            text.replace("END CERTIFICATE", "END PRIVATE KEY"),
        ] {
            assert!(
                matches!(pem_certificates(broken.as_bytes()), Err(Malformed(_))),
                "{broken:?}"
            );
        }
    }

    #[test]
    fn pem_ignores_every_other_block_however_it_is_shaped() {
        let leaf = fixture_certificates().remove(0);
        let mut input = b"-----BEGIN PRIVATE KEY-----\n!!! never terminated\n".to_vec();
        input.extend(b"-----BEGIN CERTIFICATE REQUEST-----\n");
        input.extend(pem_block("CERTIFICATE", &leaf.to_der().unwrap(), 64, "\n"));

        assert_eq!(pem_certificates(&input), Ok(vec![leaf]));

        for no_certificate in [
            &b"-----BEGIN PRIVATE KEY-----\n!!!\n-----END PRIVATE KEY-----\n"[..],
            b"-----BEGIN CERTIFICATE",
            b"",
        ] {
            assert!(matches!(
                pem_certificates(no_certificate),
                Err(NoCertificate(_))
            ));
        }
    }

    fn truststore(certificates: &[Certificate], password: &str) -> Vec<u8> {
        let mut store = p12_keystore::KeyStore::new();
        for (index, certificate) in certificates.iter().enumerate() {
            let entry = p12_keystore::Certificate::from_der(&certificate.to_der().unwrap())
                .expect("keystore certificate");
            store.add_entry(
                &format!("trusted {index}"),
                p12_keystore::KeyStoreEntry::Certificate(entry),
            );
        }

        store.writer(password).write().expect("writes")
    }

    #[test]
    fn pkcs12_returns_a_keyless_store_in_file_order() {
        let chain = fixture_certificates();
        let store = truststore(&chain, "secret");

        assert_eq!(pkcs12_certificates(&store, "secret"), Ok(chain));
        assert_eq!(
            pkcs12_certificates(&truststore(&[], "secret"), "secret"),
            Err(NoCertificate("the PKCS#12 file holds no certificate"))
        );
    }

    #[test]
    fn pkcs12_reports_a_wrong_password_apart_from_a_malformed_file() {
        let store = truststore(&fixture_certificates()[2..], "secret");

        assert_eq!(pkcs12_certificates(&store, "wrong"), Err(WrongPassword));
        assert!(matches!(
            pkcs12_certificates(b"\x30\x03\x02\x01\x03", "secret"),
            Err(Malformed(_))
        ));
    }

    #[test]
    fn pkcs12_returns_the_key_chain_leaf_first() {
        let expected = fixture_certificates();

        for name in ["certificate_chain.p12", "certificate_chain_legacy.p12"] {
            assert_eq!(
                pkcs12_certificates(&fixture_bytes(name), "pdf_elixide"),
                Ok(expected.clone()),
                "{name}"
            );
        }
    }

    // The fixture spends 2 048 iterations on its MAC and 2 048 on its
    // certificate safe; decrypting its key bag would take a third 2 048.
    #[test]
    fn pkcs12_derives_keys_only_for_the_mac_and_the_certificates() {
        let data = fixture_bytes("certificate_chain.p12");

        assert_eq!(
            pkcs12_certificates_within(&data, "pdf_elixide", 5_000),
            Ok(fixture_certificates())
        );
        assert!(matches!(
            pkcs12_certificates_within(&data, "pdf_elixide", 3_000),
            Err(Unsupported(_))
        ));
    }

    #[test]
    fn pkcs12_refuses_an_iteration_count_before_spending_it() {
        let mut pfx = Pfx::from_der(&fixture_bytes("certificate_chain.p12")).expect("pfx");
        pfx.mac_data.as_mut().expect("mac").iterations = i32::MAX;

        assert!(matches!(
            pkcs12_certificates(&pfx.to_der().unwrap(), "pdf_elixide"),
            Err(Unsupported(_))
        ));

        pfx.mac_data.as_mut().expect("mac").iterations = 0;

        assert!(matches!(
            pkcs12_certificates(&pfx.to_der().unwrap(), "pdf_elixide"),
            Err(Malformed(_))
        ));
    }

    // `SafeBag`'s encoder adds the explicit `[0]` its decoder leaves in
    // `bag_value`, so a bag built here carries the bare value.
    fn bag_value(value: &impl Encode) -> Vec<u8> {
        value.to_der().unwrap()
    }

    fn certificate_bag(certificate: &Certificate) -> SafeBag {
        let bag = CertBag {
            cert_id: PKCS_12_X509_CERT_OID,
            cert_value: OctetString::new(certificate.to_der().unwrap()).unwrap(),
        };

        SafeBag {
            bag_id: PKCS_12_CERT_BAG_OID,
            bag_value: bag_value(&bag),
            bag_attributes: None,
        }
    }

    fn nested_bag(bags: Vec<SafeBag>) -> SafeBag {
        SafeBag {
            bag_id: PKCS_12_SAFE_CONTENTS_BAG_OID,
            bag_value: bag_value(&bags),
            bag_attributes: None,
        }
    }

    fn data_content(der: Vec<u8>) -> ContentInfo {
        ContentInfo {
            content_type: ID_DATA,
            content: der::Any::from_der(&OctetString::new(der).unwrap().to_der().unwrap()).unwrap(),
        }
    }

    // No exporter writes nested safe contents, so the file is assembled here,
    // MAC-less so no password is involved.
    fn pfx_of(bags: Vec<SafeBag>) -> Vec<u8> {
        let safes: AuthenticatedSafe = vec![data_content(bags.to_der().unwrap())];

        Pfx {
            version: Version::V3,
            auth_safe: data_content(safes.to_der().unwrap()),
            mac_data: None,
        }
        .to_der()
        .unwrap()
    }

    #[test]
    fn pkcs12_reads_nested_safe_contents_in_stored_order() {
        let [leaf, intermediate, root] = &fixture_certificates()[..] else {
            panic!("fixture carries a chain");
        };
        let data = pfx_of(vec![
            certificate_bag(leaf),
            nested_bag(vec![certificate_bag(intermediate)]),
            certificate_bag(root),
        ]);

        assert_eq!(
            pkcs12_certificates(&data, ""),
            Ok(vec![leaf.clone(), intermediate.clone(), root.clone()])
        );

        let all_nested = pfx_of(vec![nested_bag(vec![certificate_bag(root)])]);
        assert_eq!(pkcs12_certificates(&all_nested, ""), Ok(vec![root.clone()]));
    }

    #[test]
    fn pkcs12_caps_how_deep_safe_contents_nest() {
        let root = fixture_certificates().remove(2);
        let nested = |levels: usize| {
            let bags = (0..levels).fold(vec![certificate_bag(&root)], |bags, _| {
                vec![nested_bag(bags)]
            });
            pfx_of(bags)
        };

        assert_eq!(
            pkcs12_certificates(&nested(MAX_SAFE_CONTENTS_DEPTH), ""),
            Ok(vec![root.clone()])
        );
        assert!(matches!(
            pkcs12_certificates(&nested(MAX_SAFE_CONTENTS_DEPTH + 1), ""),
            Err(Unsupported(_))
        ));
    }

    #[test]
    fn pkcs12_reports_an_algorithm_this_build_lacks_as_unsupported() {
        let mut pfx = Pfx::from_der(&fixture_bytes("certificate_chain.p12")).expect("pfx");
        pfx.mac_data = None;

        let mut safes =
            AuthenticatedSafe::from_der(&octet_string_content(&pfx.auth_safe).unwrap()).unwrap();
        let safe = safes
            .iter_mut()
            .find(|safe| safe.content_type == ID_ENCRYPTED_DATA)
            .expect("an encrypted safe");
        let mut encrypted = EncryptedData::from_der(&safe.content.to_der().unwrap()).unwrap();
        let algorithm = &mut encrypted.enc_content_info.content_enc_alg;

        // HMAC-SHA1 decodes as a PBKDF2 PRF, but `pkcs5` decrypts with it only
        // under a feature this crate leaves off.
        let mut parameters =
            pbes2::Parameters::from_der(&algorithm.parameters.as_ref().unwrap().to_der().unwrap())
                .unwrap();
        let pbes2::Kdf::Pbkdf2(pbkdf2) = &mut parameters.kdf else {
            panic!("fixture derives with PBKDF2");
        };
        pbkdf2.prf = pbes2::Pbkdf2Prf::HmacWithSha1;
        algorithm.parameters = Some(der::Any::from_der(&parameters.to_der().unwrap()).unwrap());

        safe.content = der::Any::from_der(&encrypted.to_der().unwrap()).unwrap();
        pfx.auth_safe = data_content(safes.to_der().unwrap());

        assert!(matches!(
            pkcs12_certificates(&pfx.to_der().unwrap(), "pdf_elixide"),
            Err(Unsupported(message)) if message.starts_with("PKCS#12 algorithm ")
        ));
    }
}
