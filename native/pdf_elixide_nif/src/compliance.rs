use pdf_oxide::{
    compliance::{
        validate_pdf_a, validate_pdf_ua, validate_pdf_x, ComplianceError, ComplianceWarning,
        PdfALevel, PdfUaLevel, PdfXLevel, UaComplianceError, UaValidationResult, ValidationResult,
        XComplianceError, XValidationResult,
    },
    error::Result,
    PdfDocument,
};
use rustler::{NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    atoms,
    error::{tagged_err, to_nif_err},
    DocumentResource,
};

// Variant names are the atoms, spelled so `NifUnitEnum`'s snake-casing leaves
// them alone.
#[allow(non_camel_case_types)]
#[derive(NifUnitEnum, Clone, Copy, Debug, PartialEq, Eq)]
enum StandardNif {
    pdf_a_1a,
    pdf_a_1b,
    pdf_a_2a,
    pdf_a_2b,
    pdf_a_2u,
    pdf_a_3a,
    pdf_a_3b,
    pdf_a_3u,
    pdf_ua_1,
    pdf_x_1a_2001,
    pdf_x_1a_2003,
    pdf_x_3_2002,
    pdf_x_3_2003,
    pdf_x_4,
    pdf_x_4p,
    pdf_x_5g,
    pdf_x_5n,
    pdf_x_5pg,
    pdf_x_6,
}

enum Standard {
    PdfA(PdfALevel),
    PdfUa(PdfUaLevel),
    PdfX(PdfXLevel),
}

impl From<StandardNif> for Standard {
    fn from(standard: StandardNif) -> Self {
        match standard {
            StandardNif::pdf_a_1a => Self::PdfA(PdfALevel::A1a),
            StandardNif::pdf_a_1b => Self::PdfA(PdfALevel::A1b),
            StandardNif::pdf_a_2a => Self::PdfA(PdfALevel::A2a),
            StandardNif::pdf_a_2b => Self::PdfA(PdfALevel::A2b),
            StandardNif::pdf_a_2u => Self::PdfA(PdfALevel::A2u),
            StandardNif::pdf_a_3a => Self::PdfA(PdfALevel::A3a),
            StandardNif::pdf_a_3b => Self::PdfA(PdfALevel::A3b),
            StandardNif::pdf_a_3u => Self::PdfA(PdfALevel::A3u),
            StandardNif::pdf_ua_1 => Self::PdfUa(PdfUaLevel::Ua1),
            StandardNif::pdf_x_1a_2001 => Self::PdfX(PdfXLevel::X1a2001),
            StandardNif::pdf_x_1a_2003 => Self::PdfX(PdfXLevel::X1a2003),
            StandardNif::pdf_x_3_2002 => Self::PdfX(PdfXLevel::X32002),
            StandardNif::pdf_x_3_2003 => Self::PdfX(PdfXLevel::X32003),
            StandardNif::pdf_x_4 => Self::PdfX(PdfXLevel::X4),
            StandardNif::pdf_x_4p => Self::PdfX(PdfXLevel::X4p),
            StandardNif::pdf_x_5g => Self::PdfX(PdfXLevel::X5g),
            StandardNif::pdf_x_5n => Self::PdfX(PdfXLevel::X5n),
            StandardNif::pdf_x_5pg => Self::PdfX(PdfXLevel::X5pg),
            StandardNif::pdf_x_6 => Self::PdfX(PdfXLevel::X6),
        }
    }
}

impl From<PdfALevel> for StandardNif {
    fn from(level: PdfALevel) -> Self {
        match level {
            PdfALevel::A1a => Self::pdf_a_1a,
            PdfALevel::A1b => Self::pdf_a_1b,
            PdfALevel::A2a => Self::pdf_a_2a,
            PdfALevel::A2b => Self::pdf_a_2b,
            PdfALevel::A2u => Self::pdf_a_2u,
            PdfALevel::A3a => Self::pdf_a_3a,
            PdfALevel::A3b => Self::pdf_a_3b,
            PdfALevel::A3u => Self::pdf_a_3u,
        }
    }
}

impl From<PdfXLevel> for StandardNif {
    fn from(level: PdfXLevel) -> Self {
        match level {
            PdfXLevel::X1a2001 => Self::pdf_x_1a_2001,
            PdfXLevel::X1a2003 => Self::pdf_x_1a_2003,
            PdfXLevel::X32002 => Self::pdf_x_3_2002,
            PdfXLevel::X32003 => Self::pdf_x_3_2003,
            PdfXLevel::X4 => Self::pdf_x_4,
            PdfXLevel::X4p => Self::pdf_x_4p,
            PdfXLevel::X5g => Self::pdf_x_5g,
            PdfXLevel::X5n => Self::pdf_x_5n,
            PdfXLevel::X5pg => Self::pdf_x_5pg,
            PdfXLevel::X6 => Self::pdf_x_6,
        }
    }
}

#[derive(NifMap, Debug, PartialEq)]
struct IssueNif {
    code: String,
    message: String,
    clause: Option<String>,
    location: Option<String>,
    page: Option<usize>,
    object: Option<u32>,
    wcag: Option<String>,
}

impl From<ComplianceError> for IssueNif {
    fn from(error: ComplianceError) -> Self {
        Self {
            code: error.code.to_string(),
            message: error.message,
            clause: error.clause,
            location: error.location,
            page: None,
            object: None,
            wcag: None,
        }
    }
}

impl From<ComplianceWarning> for IssueNif {
    fn from(warning: ComplianceWarning) -> Self {
        Self {
            code: warning.code.to_string(),
            message: warning.message,
            clause: None,
            location: warning.location,
            page: None,
            object: None,
            wcag: None,
        }
    }
}

impl From<UaComplianceError> for IssueNif {
    fn from(error: UaComplianceError) -> Self {
        Self {
            code: error.code.to_string(),
            message: error.message,
            clause: error.clause,
            location: error.location,
            page: None,
            object: None,
            wcag: error.wcag_ref,
        }
    }
}

// A warning is the same type as an error here; the list it lands in carries
// the severity.
impl From<XComplianceError> for IssueNif {
    fn from(error: XComplianceError) -> Self {
        Self {
            code: error.code.to_string(),
            message: error.message,
            clause: error.clause,
            location: None,
            page: error.page,
            object: error.object_id,
            wcag: None,
        }
    }
}

#[derive(NifMap, Debug)]
struct ReportNif {
    standard: StandardNif,
    compliant: bool,
    declared: Option<StandardNif>,
    errors: Vec<IssueNif>,
    warnings: Vec<IssueNif>,
}

fn issues<T: Into<IssueNif>>(list: Vec<T>) -> Vec<IssueNif> {
    list.into_iter().map(Into::into).collect()
}

impl ReportNif {
    fn from_pdf_a(standard: StandardNif, result: ValidationResult) -> Self {
        Self {
            standard,
            compliant: result.is_compliant,
            declared: result.detected_level.map(Into::into),
            errors: issues(result.errors),
            warnings: issues(result.warnings),
        }
    }

    fn from_pdf_ua(standard: StandardNif, result: UaValidationResult) -> Self {
        Self {
            standard,
            compliant: result.is_compliant,
            declared: None,
            errors: issues(result.errors),
            warnings: issues(result.warnings),
        }
    }

    fn from_pdf_x(standard: StandardNif, result: XValidationResult) -> Self {
        Self {
            standard,
            compliant: result.is_compliant,
            declared: result.detected_level.map(Into::into),
            errors: issues(result.errors),
            warnings: issues(result.warnings),
        }
    }
}

fn validate(doc: &mut PdfDocument, standard: StandardNif) -> Result<ReportNif> {
    Ok(match Standard::from(standard) {
        Standard::PdfA(level) => ReportNif::from_pdf_a(standard, validate_pdf_a(doc, level)?),
        Standard::PdfUa(level) => ReportNif::from_pdf_ua(standard, validate_pdf_ua(doc, level)?),
        Standard::PdfX(level) => ReportNif::from_pdf_x(standard, validate_pdf_x(doc, level)?),
    })
}

enum Shared {
    Validated(ReportNif),
    NeedsLive,
}

// Upstream's validators take `&mut PdfDocument` but only ever call `&self`
// methods, so a private re-parse satisfies the signature and keeps the handle
// shared. A re-parse cannot repeat a password authentication, so only a
// document that needed one is validated in place, under the exclusive lock.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_validate(
    resource: ResourceArc<DocumentResource>,
    standard: StandardNif,
) -> NifResult<ReportNif> {
    let shared = resource.doc.with_read(|doc| {
        // Unauthenticated, the validators read ciphertext and report findings
        // about data they could not decode.
        if !doc.is_authenticated() {
            return Err(tagged_err(
                atoms::encrypted(),
                "PDF is encrypted and requires a password. Call authenticate/2 before validating.",
            ));
        }

        let mut fresh = PdfDocument::from_bytes(doc.source_bytes.clone()).map_err(to_nif_err)?;

        let result = if fresh.is_authenticated() {
            validate(&mut fresh, standard).map(Shared::Validated)
        } else {
            Ok(Shared::NeedsLive)
        };

        // Absorb before `?` can discard the fresh document, on every path.
        doc.absorb_reparse(&fresh);

        result.map_err(to_nif_err)
    })?;

    match shared {
        Shared::Validated(report) => Ok(report),
        Shared::NeedsLive => resource
            .doc
            .with_lock(|doc| validate(&mut doc.doc, standard).map_err(to_nif_err)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> PdfDocument {
        let path = format!("{}/../../test/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
        PdfDocument::open(&path).expect("fixture opens")
    }

    #[test]
    fn upstream_still_validates_ua2_as_ua1() {
        for name in ["sample.pdf", "tagged.pdf"] {
            let mut doc = fixture(name);
            let ua1 = validate_pdf_ua(&mut doc, PdfUaLevel::Ua1).unwrap();
            let ua2 = validate_pdf_ua(&mut doc, PdfUaLevel::Ua2).unwrap();

            assert_eq!(issues(ua1.errors), issues(ua2.errors), "{name}");
            assert_eq!(issues(ua1.warnings), issues(ua2.warnings), "{name}");
        }
    }

    #[test]
    fn upstream_still_leaves_pdf_a_stats_empty() {
        let mut doc = fixture("fonts.pdf");
        let stats = validate_pdf_a(&mut doc, PdfALevel::A2b).unwrap().stats;

        assert_eq!(
            (
                stats.fonts_checked,
                stats.fonts_embedded,
                stats.images_checked,
                stats.color_spaces_checked,
                stats.annotations_checked,
                stats.pages_checked,
            ),
            (0, 0, 0, 0, 0, 0)
        );
    }
}
