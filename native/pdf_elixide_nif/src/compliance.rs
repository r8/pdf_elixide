use pdf_oxide::{
    compliance::{
        validate_pdf_a, validate_pdf_ua, validate_pdf_x, ActionType, ComplianceError,
        ComplianceWarning, ConversionAction, ConversionConfig, ConversionError, PdfAConverter,
        PdfALevel, PdfAPart, PdfUaLevel, PdfXLevel, UaComplianceError, UaValidationResult,
        ValidationResult, XComplianceError, XValidationResult,
    },
    editor::DocumentEditor,
    error::Result,
    object::Object,
    PdfDocument,
};
use rustler::{Binary, NifMap, NifResult, NifUnitEnum, ResourceArc};

use crate::{
    atoms,
    editor::{ensure_rebuild_keeps_redactions, ensure_rewrite_keeps_metadata},
    error::{tagged_err, to_nif_err},
    open_editor::Rebuild,
    DocumentResource, EditorResource,
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

fn into_all<T: Into<U>, U>(list: Vec<T>) -> Vec<U> {
    list.into_iter().map(Into::into).collect()
}

impl ReportNif {
    fn from_pdf_a(standard: StandardNif, result: ValidationResult) -> Self {
        Self {
            standard,
            compliant: result.is_compliant,
            declared: result.detected_level.map(Into::into),
            errors: into_all(result.errors),
            warnings: into_all(result.warnings),
        }
    }

    fn from_pdf_ua(standard: StandardNif, result: UaValidationResult) -> Self {
        Self {
            standard,
            compliant: result.is_compliant,
            declared: None,
            errors: into_all(result.errors),
            warnings: into_all(result.warnings),
        }
    }

    fn from_pdf_x(standard: StandardNif, result: XValidationResult) -> Self {
        Self {
            standard,
            compliant: result.is_compliant,
            declared: result.detected_level.map(Into::into),
            errors: into_all(result.errors),
            warnings: into_all(result.warnings),
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

#[derive(NifMap)]
struct ConvertOptionsNif<'a> {
    embed_fonts: bool,
    remove_javascript: bool,
    remove_embedded_files: bool,
    icc_profile: Option<Binary<'a>>,
}

impl ConvertOptionsNif<'_> {
    // No input reaches the transparency fix, which has no pixel budget, and
    // `add_structure` declares a structure tree it does not build.
    fn config(&self) -> ConversionConfig {
        ConversionConfig {
            embed_fonts: self.embed_fonts,
            remove_javascript: self.remove_javascript,
            remove_embedded_files: self.remove_embedded_files,
            flatten_transparency: false,
            add_structure: false,
            icc_profile: self.icc_profile.map(|profile| profile.as_slice().to_vec()),
            ..ConversionConfig::default()
        }
    }
}

// Variant names are the atoms, as for `StandardNif`.
#[allow(non_camel_case_types)]
#[derive(NifUnitEnum, Debug)]
enum ActionTypeNif {
    added_xmp_metadata,
    added_pdfa_identification,
    embedded_font,
    added_output_intent,
    removed_javascript,
    removed_encryption,
    flattened_transparency,
    removed_embedded_files,
    added_structure,
    fixed_annotation,
    added_language,
}

impl From<ActionType> for ActionTypeNif {
    fn from(action: ActionType) -> Self {
        match action {
            ActionType::AddedXmpMetadata => Self::added_xmp_metadata,
            ActionType::AddedPdfaIdentification => Self::added_pdfa_identification,
            ActionType::EmbeddedFont => Self::embedded_font,
            ActionType::AddedOutputIntent => Self::added_output_intent,
            ActionType::RemovedJavaScript => Self::removed_javascript,
            ActionType::RemovedEncryption => Self::removed_encryption,
            ActionType::FlattenedTransparency => Self::flattened_transparency,
            ActionType::RemovedEmbeddedFiles => Self::removed_embedded_files,
            ActionType::AddedStructure => Self::added_structure,
            ActionType::FixedAnnotation => Self::fixed_annotation,
            ActionType::AddedLanguage => Self::added_language,
        }
    }
}

#[derive(NifMap, Debug)]
struct ActionNif {
    kind: ActionTypeNif,
    description: String,
    fixed: Option<String>,
}

impl From<ConversionAction> for ActionNif {
    fn from(action: ConversionAction) -> Self {
        Self {
            kind: action.action_type.into(),
            description: action.description,
            fixed: action.fixed_error.map(|code| code.to_string()),
        }
    }
}

#[derive(NifMap, Debug)]
struct FailureNif {
    code: String,
    reason: String,
}

impl From<ConversionError> for FailureNif {
    fn from(error: ConversionError) -> Self {
        Self {
            code: error.error_code.to_string(),
            reason: error.reason,
        }
    }
}

#[derive(NifMap, Debug)]
struct ConversionNif {
    report: ReportNif,
    actions: Vec<ActionNif>,
    failures: Vec<FailureNif>,
}

#[derive(Debug)]
enum ConvertError {
    Upstream(pdf_oxide::Error),
    IgnoredProfile,
    Declares {
        requested: PdfALevel,
        declared: Option<PdfALevel>,
    },
    CompressedMetadata {
        level: PdfALevel,
        added: bool,
    },
    // Conversion must preserve the visible page count.
    Miscount {
        expected: usize,
        got: usize,
    },
}

impl From<pdf_oxide::Error> for ConvertError {
    fn from(e: pdf_oxide::Error) -> Self {
        Self::Upstream(e)
    }
}

impl From<ConvertError> for rustler::Error {
    fn from(e: ConvertError) -> Self {
        match e {
            ConvertError::Upstream(e) => to_nif_err(e),
            ConvertError::IgnoredProfile => tagged_err(
                atoms::unsupported(),
                "The document already has an output intent, which a conversion keeps, \
                 so the :icc_profile given would not be used. Nothing has been \
                 converted. Convert without :icc_profile.",
            ),
            ConvertError::Declares {
                requested,
                declared,
            } => {
                let requested = StandardNif::from(requested);
                let message = match declared {
                    Some(level) => format!(
                        "The converted document declares :{:?}, which a conversion does \
                         not change, so it would not identify itself as :{requested:?}. \
                         Nothing has been converted. Convert to the level the document \
                         declares, or remove its metadata first with sanitize/2; see \
                         PdfElixide.Compliance.convert/3.",
                        StandardNif::from(level)
                    ),
                    None => format!(
                        "The conversion could not declare :{requested:?} in the document's \
                         XMP metadata, or the document declares a level this library does \
                         not recognise, so the result would not identify itself as \
                         :{requested:?}. Nothing has been converted. Remove the document's \
                         metadata first with sanitize/2; see PdfElixide.Compliance.convert/3."
                    ),
                };

                tagged_err(atoms::unsupported(), message)
            }
            ConvertError::CompressedMetadata { level, added } => {
                let level = StandardNif::from(level);
                let found = if added {
                    format!(
                        "A conversion declares :{level:?} in the document's existing XMP \
                         metadata"
                    )
                } else {
                    format!("The document's XMP metadata already declares :{level:?}")
                };

                tagged_err(
                    atoms::unsupported(),
                    format!(
                        "{found} and keeps that metadata compressed, which PDF/A-1 forbids. \
                         Nothing has been converted. Remove the document's metadata first \
                         with sanitize/2, and the conversion writes a new, uncompressed \
                         declaration; see PdfElixide.Compliance.convert/3."
                    ),
                )
            }
            ConvertError::Miscount { expected, got } => tagged_err(
                atoms::invalid_pdf(),
                format!(
                    "The conversion produced {got} pages where {expected} were expected. \
                     Nothing has been converted."
                ),
            ),
        }
    }
}

fn ensure_profile_used(
    wants_profile: bool,
    actions: &[ConversionAction],
) -> std::result::Result<(), ConvertError> {
    if wants_profile
        && !actions
            .iter()
            .any(|action| action.action_type == ActionType::AddedOutputIntent)
    {
        return Err(ConvertError::IgnoredProfile);
    }

    Ok(())
}

fn ensure_declares(
    report: &ValidationResult,
    level: PdfALevel,
) -> std::result::Result<(), ConvertError> {
    if report.detected_level == Some(level) {
        return Ok(());
    }

    Err(ConvertError::Declares {
        requested: level,
        declared: report.detected_level,
    })
}

// A later write cannot remove a stream filter from existing PDF/A-1 metadata.
fn ensure_uncompressed_metadata(
    doc: &PdfDocument,
    level: PdfALevel,
    actions: &[ConversionAction],
) -> std::result::Result<(), ConvertError> {
    if level.part() != PdfAPart::Part1 {
        return Ok(());
    }

    let catalog = doc.catalog()?;
    let Some(entry) = catalog.as_dict().and_then(|dict| dict.get("Metadata")) else {
        return Ok(());
    };

    match doc.resolve_object(entry)? {
        Object::Stream { dict, .. } if dict.contains_key("Filter") => {
            Err(ConvertError::CompressedMetadata {
                level,
                added: actions
                    .iter()
                    .any(|action| action.action_type == ActionType::AddedPdfaIdentification),
            })
        }
        _ => Ok(()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn editor_convert_to_pdf_a(
    resource: ResourceArc<EditorResource>,
    standard: StandardNif,
    options: ConvertOptionsNif,
) -> NifResult<ConversionNif> {
    convert_to_pdf_a(&resource, standard, options)
}

// Font discovery and embedding perform filesystem I/O.
#[rustler::nif(schedule = "DirtyIo")]
fn editor_convert_to_pdf_a_embedding(
    resource: ResourceArc<EditorResource>,
    standard: StandardNif,
    options: ConvertOptionsNif,
) -> NifResult<ConversionNif> {
    convert_to_pdf_a(&resource, standard, options)
}

fn convert_to_pdf_a(
    resource: &EditorResource,
    standard: StandardNif,
    options: ConvertOptionsNif,
) -> NifResult<ConversionNif> {
    let Standard::PdfA(level) = Standard::from(standard) else {
        return Err(tagged_err(
            atoms::other(),
            "Only a PDF/A standard can be converted to.",
        ));
    };
    let wants_profile = options.icc_profile.is_some();
    let converter = PdfAConverter::new(level).with_config(options.config());

    resource.editor.with_lock(|editor| {
        ensure_rewrite_keeps_metadata(editor)?;
        ensure_rebuild_keeps_redactions(editor, Rebuild::Conversion(level))?;

        let count = editor.visible_page_count();
        if count == 0 {
            return Err(tagged_err(
                atoms::unsupported(),
                "This editor has no pages, which a conversion cannot start from. \
                 Nothing has been converted.",
            ));
        }
        editor.check_selection(&(0..count).collect::<Vec<_>>())?;

        let (result, report) = editor.rebuild(Rebuild::Conversion(level), |mut scratch| {
            let mut doc = PdfDocument::from_bytes(scratch.save_to_bytes()?)?;
            let result = converter.convert(&mut doc)?;
            ensure_profile_used(wants_profile, &result.actions)?;
            // Return the same report `validate/2` gives for the written file.
            let report = validate_pdf_a(&mut doc, level)?;
            ensure_declares(&report, level)?;
            ensure_uncompressed_metadata(&doc, level, &result.actions)?;
            let fresh = DocumentEditor::from_bytes(doc.source_bytes.to_vec())?;
            let got = fresh.current_page_count();
            if got != count {
                return Err(ConvertError::Miscount {
                    expected: count,
                    got,
                });
            }

            Ok::<_, ConvertError>(((result, report), fresh))
        })?;

        Ok(ConversionNif {
            report: ReportNif::from_pdf_a(standard, report),
            actions: into_all(result.actions),
            failures: into_all(result.errors),
        })
    })
}

#[cfg(test)]
mod tests {
    use pdf_oxide::compliance::ErrorCode;

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

            assert_eq!(
                into_all::<_, IssueNif>(ua1.errors),
                into_all::<_, IssueNif>(ua2.errors),
                "{name}"
            );
            assert_eq!(
                into_all::<_, IssueNif>(ua1.warnings),
                into_all::<_, IssueNif>(ua2.warnings),
                "{name}"
            );
        }
    }

    // `annotations.pdf` has annotations without `/AP` and one at `/CA 0.5`.
    #[test]
    fn upstream_still_never_reports_pdf_a_transparency_or_missing_appearances() {
        let mut doc = fixture("annotations.pdf");
        let errors = validate_pdf_a(&mut doc, PdfALevel::A1b).unwrap().errors;

        assert!(!errors.iter().any(|error| matches!(
            error.code,
            ErrorCode::TransparencyNotAllowed | ErrorCode::MissingAppearanceStream
        )));
    }

    #[test]
    fn upstream_still_passes_an_unembedded_symbol_font_on_conversion() {
        let mut doc = fixture("symbol_font.pdf");
        let converted = PdfAConverter::new(PdfALevel::A2b)
            .with_config(ConversionConfig {
                embed_fonts: false,
                ..ConversionConfig::default()
            })
            .convert(&mut doc)
            .unwrap();

        assert!(converted.validation.is_compliant);
        assert!(
            !validate_pdf_a(&mut doc, PdfALevel::A2b)
                .unwrap()
                .is_compliant
        );
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
