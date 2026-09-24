use std::{io::Cursor, panic, thread};

use office_oxide::{cfb::CFB_SIGNATURE, core::opc::OpcReader};
use pdf_oxide::{
    converters::{office::OfficeConverter, pptx_layout, xlsx_layout},
    error::Result,
    PdfDocument,
};
use rustler::{Binary, NifMap, NifResult, NifUnitEnum, OwnedBinary, ResourceArc};

use crate::{
    atoms,
    binary::owned_binary,
    error::{panic_err, tagged_err, to_nif_err},
    warnings, DocumentResource,
};

#[derive(NifUnitEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum OfficeModeNif {
    Auto,
    Layout,
    Flow,
}

#[derive(NifMap, Debug)]
pub struct OfficeOptionsNif {
    mode: OfficeModeNif,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Family {
    Docx,
    Pptx,
    Xlsx,
}

impl Family {
    fn label(self) -> &'static str {
        match self {
            Family::Docx => "DOCX",
            Family::Pptx => "PPTX",
            Family::Xlsx => "XLSX",
        }
    }
}

fn export_bytes(doc: &PdfDocument, family: Family, mode: OfficeModeNif) -> Result<Vec<u8>> {
    match (family, mode) {
        (Family::Docx, OfficeModeNif::Auto) => doc.to_docx_bytes(),
        (Family::Docx, OfficeModeNif::Layout) => doc.to_docx_bytes_layout(),
        (Family::Docx, OfficeModeNif::Flow) => doc.to_docx_bytes_flow(),
        (Family::Pptx, OfficeModeNif::Auto) => doc.to_pptx_bytes(),
        (Family::Pptx, OfficeModeNif::Layout) => pptx_layout::to_pptx_bytes_layout(doc),
        (Family::Pptx, OfficeModeNif::Flow) => doc.to_pptx_bytes_flow(),
        (Family::Xlsx, OfficeModeNif::Auto) => doc.to_xlsx_bytes(),
        (Family::Xlsx, OfficeModeNif::Layout) => xlsx_layout::to_xlsx_bytes_layout(doc),
        (Family::Xlsx, OfficeModeNif::Flow) => doc.to_xlsx_bytes_flow(),
    }
}

fn export(
    resource: &DocumentResource,
    family: Family,
    options: OfficeOptionsNif,
) -> NifResult<OwnedBinary> {
    resource.doc.with_read(|doc| {
        // Flow export can swallow per-page failures, so authenticate first
        // rather than returning a blank package.
        if !doc.is_authenticated() {
            return Err(tagged_err(
                atoms::encrypted(),
                format!(
                    "the document is encrypted; authenticate before exporting to {}",
                    family.label()
                ),
            ));
        }

        let bytes = export_bytes(doc, family, options.mode).map_err(to_nif_err)?;

        owned_binary(&bytes, &format!("{} export", family.label()))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_docx(
    resource: ResourceArc<DocumentResource>,
    options: OfficeOptionsNif,
) -> NifResult<OwnedBinary> {
    export(&resource, Family::Docx, options)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_pptx(
    resource: ResourceArc<DocumentResource>,
    options: OfficeOptionsNif,
) -> NifResult<OwnedBinary> {
    export(&resource, Family::Pptx, options)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn document_to_xlsx(
    resource: ResourceArc<DocumentResource>,
    options: OfficeOptionsNif,
) -> NifResult<OwnedBinary> {
    export(&resource, Family::Xlsx, options)
}

// The main-part content types each `office_oxide` reader accepts.
const DOCX_TYPES: &[&str] = &[
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml",
    "application/vnd.ms-word.document.macroEnabled.main+xml",
    "application/vnd.ms-word.template.macroEnabledTemplate.main+xml",
];
const PPTX_TYPES: &[&str] = &[
    "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
    "application/vnd.openxmlformats-officedocument.presentationml.slideshow.main+xml",
    "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml",
    "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml",
    "application/vnd.ms-powerpoint.slideshow.macroEnabled.main+xml",
];
const XLSX_TYPES: &[&str] = &[
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.template.main+xml",
    "application/vnd.ms-excel.sheet.macroEnabled.main+xml",
    "application/vnd.ms-excel.template.macroEnabled.main+xml",
];

#[derive(Debug, PartialEq, Eq)]
enum NotOffice {
    Compound,
    Unreadable(String),
    NoMainPart,
    UnknownContentType(Option<String>),
}

impl NotOffice {
    fn message(&self) -> String {
        let detail = match self {
            NotOffice::Compound => {
                "a legacy binary Office file or a password-protected package".to_string()
            }
            NotOffice::Unreadable(reason) => reason.clone(),
            NotOffice::NoMainPart => "no main document part".to_string(),
            NotOffice::UnknownContentType(Some(ct)) => format!("main part is {ct}"),
            NotOffice::UnknownContentType(None) => "main part has no content type".to_string(),
        };

        format!("not a DOCX, PPTX or XLSX package: {detail}")
    }
}

fn detect(bytes: &[u8]) -> std::result::Result<Family, NotOffice> {
    // Recognize compound files before ZIP parsing so legacy or encrypted Office
    // input gets the intended unsupported-file diagnostic.
    if bytes.starts_with(&CFB_SIGNATURE) {
        return Err(NotOffice::Compound);
    }

    let opc =
        OpcReader::new(Cursor::new(bytes)).map_err(|e| NotOffice::Unreadable(e.to_string()))?;
    let main = opc
        .main_document_part()
        .map_err(|_| NotOffice::NoMainPart)?;
    let content_type = opc.content_types().resolve(&main);

    match content_type {
        Some(ct) if DOCX_TYPES.contains(&ct) => Ok(Family::Docx),
        Some(ct) if PPTX_TYPES.contains(&ct) => Ok(Family::Pptx),
        Some(ct) if XLSX_TYPES.contains(&ct) => Ok(Family::Xlsx),
        // The readers check only an `Override`, so a main part without one
        // converts; its directory is then the only sign of which format it is.
        other if !opc.content_types().overrides().contains_key(&main) => match main.directory() {
            dir if dir.eq_ignore_ascii_case("/word/") => Ok(Family::Docx),
            dir if dir.eq_ignore_ascii_case("/ppt/") => Ok(Family::Pptx),
            dir if dir.eq_ignore_ascii_case("/xl/") => Ok(Family::Xlsx),
            _ => Err(NotOffice::UnknownContentType(other.map(str::to_string))),
        },
        other => Err(NotOffice::UnknownContentType(other.map(str::to_string))),
    }
}

enum Failure {
    NotOffice(NotOffice),
    Conversion(pdf_oxide::Error),
}

fn convert(bytes: &[u8]) -> std::result::Result<Vec<u8>, Failure> {
    let family = detect(bytes).map_err(Failure::NotOffice)?;
    let converter = OfficeConverter::new();

    match family {
        Family::Docx => converter.convert_docx_bytes(bytes),
        Family::Pptx => converter.convert_pptx_bytes(bytes),
        Family::Xlsx => converter.convert_xlsx_bytes(bytes),
    }
    .map_err(Failure::Conversion)
}

// Conversion recurses after parsing, so use the stack size assumed by the
// parser's nesting limit rather than the dirty scheduler's smaller stack.
const CONVERT_STACK_SIZE: usize = 16 * 1024 * 1024;

fn convert_on_own_stack(bytes: &[u8]) -> NifResult<Vec<u8>> {
    let joined = thread::scope(|scope| {
        thread::Builder::new()
            .stack_size(CONVERT_STACK_SIZE)
            .spawn_scoped(scope, || {
                // The warning sink is thread-local, so drain it here even after
                // a caught panic.
                let result = panic::catch_unwind(|| convert(bytes));
                warnings::collect_global();

                result
            })
            .map(|handle| handle.join().and_then(|result| result))
    });

    // `rustler::Error` is not `Send`, so the thread returns data and the
    // tagged error is built here.
    match joined {
        Ok(Ok(Ok(pdf))) => Ok(pdf),
        Ok(Ok(Err(Failure::NotOffice(e)))) => Err(tagged_err(atoms::unsupported(), e.message())),
        Ok(Ok(Err(Failure::Conversion(e)))) => Err(to_nif_err(e)),
        Ok(Err(payload)) => Err(panic_err(&*payload)),
        Err(e) => Err(tagged_err(
            atoms::other(),
            format!("could not start the conversion thread: {e}"),
        )),
    }
}

// Dirty without a lock: it takes no resource, but unzipping, parsing and laying
// out a whole document is CPU-bound. With no handle there is no `Closable` to
// contain a panic; joining the conversion thread contains it instead.
#[rustler::nif(schedule = "DirtyCpu")]
fn office_to_pdf(bytes: Binary) -> NifResult<OwnedBinary> {
    let pdf = convert_on_own_stack(bytes.as_slice())?;

    owned_binary(&pdf, "converted PDF")
}

#[cfg(test)]
mod tests {
    use office_oxide::core::opc::{OpcWriter, PartName};

    use super::*;

    const OFFICE_DOCUMENT: &str =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument";

    fn package(part: &str, content_type: &str, with_rel: bool) -> Vec<u8> {
        let mut opc = OpcWriter::new(Cursor::new(Vec::new())).expect("writer");
        let name = PartName::new(part).expect("part name");
        opc.add_part(&name, content_type, b"<x/>").expect("part");
        if with_rel {
            opc.add_package_rel(OFFICE_DOCUMENT, &part[1..]);
        }

        opc.finish().expect("finish").into_inner()
    }

    #[test]
    fn detects_each_family_by_main_part_content_type() {
        for (types, family) in [
            (DOCX_TYPES, Family::Docx),
            (PPTX_TYPES, Family::Pptx),
            (XLSX_TYPES, Family::Xlsx),
        ] {
            for ct in types {
                assert_eq!(detect(&package("/main.xml", ct, true)), Ok(family), "{ct}");
            }
        }
    }

    #[test]
    fn finds_the_main_part_without_a_package_relationship() {
        let bytes = package("/word/document.xml", DOCX_TYPES[0], false);

        assert_eq!(detect(&bytes), Ok(Family::Docx));
    }

    #[test]
    fn refuses_a_package_with_no_main_part() {
        let opc = OpcWriter::new(Cursor::new(Vec::new())).expect("writer");
        let bytes = opc.finish().expect("finish").into_inner();

        assert_eq!(detect(&bytes), Err(NotOffice::NoMainPart));
    }
}
