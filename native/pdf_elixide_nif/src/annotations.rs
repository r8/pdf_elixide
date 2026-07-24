use pdf_oxide::{
    Annotation, AnnotationFlags, AnnotationSubtype, LinkAction, LinkDestination, WidgetFieldType,
};
use rustler::{NifMap, NifStruct, NifTaggedEnum, NifUnitEnum};

use crate::geometry::{rect_from_corners, RectNif};

/// A single annotation, mirroring `pdf_oxide::Annotation` minus its `raw_dict`
/// (a recursive PDF object we don't surface). `annotation_type` is renamed to
/// `:type` on the Elixir side by `PdfElixide.Document.Annotation.from_nif/1`.
#[derive(NifMap, Debug)]
pub struct AnnotationNif {
    page: usize,
    annotation_type: String,
    subtype: SubtypeNif,
    raw_subtype: Option<String>,
    contents: Option<String>,
    rect: Option<RectNif>,
    author: Option<String>,
    subject: Option<String>,
    creation_date: Option<String>,
    modification_date: Option<String>,
    destination: Option<LinkDestinationNif>,
    action: Option<LinkActionNif>,
    quad_points: Option<Vec<Vec<f64>>>,
    color: Option<AnnotationColorNif>,
    interior_color: Option<AnnotationColorNif>,
    opacity: Option<f64>,
    flags: FlagsNif,
    border: Option<Vec<f64>>,
    field_type: Option<WidgetFieldTypeNif>,
    field_name: Option<String>,
    field_value: Option<String>,
    default_value: Option<String>,
    field_flags: Option<u32>,
    options: Option<Vec<String>>,
    appearance_state: Option<String>,
}

/// Parsed annotation subtype, encoded as a snake_case atom (`:text`, `:link`,
/// `:highlight`, `:widget`, `:three_d`, `:unknown`, …).
#[derive(NifUnitEnum, Debug)]
pub enum SubtypeNif {
    Text,
    Link,
    FreeText,
    Line,
    Square,
    Circle,
    Polygon,
    PolyLine,
    Highlight,
    Underline,
    Squiggly,
    StrikeOut,
    Stamp,
    Caret,
    Ink,
    Popup,
    FileAttachment,
    Sound,
    Movie,
    Widget,
    Screen,
    PrinterMark,
    TrapNet,
    Watermark,
    ThreeD,
    Redact,
    RichMedia,
    Unknown,
}

impl From<AnnotationSubtype> for SubtypeNif {
    fn from(subtype: AnnotationSubtype) -> Self {
        match subtype {
            AnnotationSubtype::Text => SubtypeNif::Text,
            AnnotationSubtype::Link => SubtypeNif::Link,
            AnnotationSubtype::FreeText => SubtypeNif::FreeText,
            AnnotationSubtype::Line => SubtypeNif::Line,
            AnnotationSubtype::Square => SubtypeNif::Square,
            AnnotationSubtype::Circle => SubtypeNif::Circle,
            AnnotationSubtype::Polygon => SubtypeNif::Polygon,
            AnnotationSubtype::PolyLine => SubtypeNif::PolyLine,
            AnnotationSubtype::Highlight => SubtypeNif::Highlight,
            AnnotationSubtype::Underline => SubtypeNif::Underline,
            AnnotationSubtype::Squiggly => SubtypeNif::Squiggly,
            AnnotationSubtype::StrikeOut => SubtypeNif::StrikeOut,
            AnnotationSubtype::Stamp => SubtypeNif::Stamp,
            AnnotationSubtype::Caret => SubtypeNif::Caret,
            AnnotationSubtype::Ink => SubtypeNif::Ink,
            AnnotationSubtype::Popup => SubtypeNif::Popup,
            AnnotationSubtype::FileAttachment => SubtypeNif::FileAttachment,
            AnnotationSubtype::Sound => SubtypeNif::Sound,
            AnnotationSubtype::Movie => SubtypeNif::Movie,
            AnnotationSubtype::Widget => SubtypeNif::Widget,
            AnnotationSubtype::Screen => SubtypeNif::Screen,
            AnnotationSubtype::PrinterMark => SubtypeNif::PrinterMark,
            AnnotationSubtype::TrapNet => SubtypeNif::TrapNet,
            AnnotationSubtype::Watermark => SubtypeNif::Watermark,
            AnnotationSubtype::ThreeD => SubtypeNif::ThreeD,
            AnnotationSubtype::Redact => SubtypeNif::Redact,
            AnnotationSubtype::RichMedia => SubtypeNif::RichMedia,
            AnnotationSubtype::Unknown => SubtypeNif::Unknown,
        }
    }
}

/// A link destination, encoded as a flat tagged tuple:
/// `{:named, name}` or `{:explicit, page, fit_type, params}`.
#[derive(NifTaggedEnum, Debug)]
pub enum LinkDestinationNif {
    Named(String),
    Explicit(u32, String, Vec<f64>),
}

impl From<LinkDestination> for LinkDestinationNif {
    fn from(dest: LinkDestination) -> Self {
        match dest {
            LinkDestination::Named(name) => LinkDestinationNif::Named(name),
            LinkDestination::Explicit {
                page,
                fit_type,
                params,
            } => LinkDestinationNif::Explicit(
                page,
                fit_type,
                params.into_iter().map(f64::from).collect(),
            ),
        }
    }
}

/// A link action, encoded as a flat tagged tuple: `{:uri, url}`,
/// `{:goto, destination}`, `{:goto_remote, file, destination | nil}`, or
/// `{:other, action_type}`.
#[derive(NifTaggedEnum, Debug)]
pub enum LinkActionNif {
    Uri(String),
    Goto(LinkDestinationNif),
    GotoRemote(String, Option<LinkDestinationNif>),
    Other(String),
}

impl From<LinkAction> for LinkActionNif {
    fn from(action: LinkAction) -> Self {
        match action {
            LinkAction::Uri(uri) => LinkActionNif::Uri(uri),
            LinkAction::GoTo(dest) => LinkActionNif::Goto(dest.into()),
            LinkAction::GoToRemote { file, destination } => {
                LinkActionNif::GotoRemote(file, destination.map(Into::into))
            }
            LinkAction::Other { action_type } => LinkActionNif::Other(action_type),
        }
    }
}

/// A widget form field's type, encoded as an atom or a flat tagged tuple:
/// `:text`, `:button`, `:signature`, `:unknown`, `{:checkbox, checked?}`,
/// `{:radio, selected | nil}`, or `{:choice, options, selected | nil}`.
#[derive(NifTaggedEnum, Debug)]
pub enum WidgetFieldTypeNif {
    Text,
    Checkbox(bool),
    Radio(Option<String>),
    Button,
    Choice(Vec<String>, Option<String>),
    Signature,
    Unknown,
}

impl From<WidgetFieldType> for WidgetFieldTypeNif {
    fn from(field_type: WidgetFieldType) -> Self {
        match field_type {
            WidgetFieldType::Text => WidgetFieldTypeNif::Text,
            WidgetFieldType::Checkbox { checked } => WidgetFieldTypeNif::Checkbox(checked),
            WidgetFieldType::Radio { selected } => WidgetFieldTypeNif::Radio(selected),
            WidgetFieldType::Button => WidgetFieldTypeNif::Button,
            WidgetFieldType::Choice { options, selected } => {
                WidgetFieldTypeNif::Choice(options, selected)
            }
            WidgetFieldType::Signature => WidgetFieldTypeNif::Signature,
            WidgetFieldType::Unknown => WidgetFieldTypeNif::Unknown,
        }
    }
}

/// An annotation color (`/C` or `/IC`), decoded from the raw component array by
/// its length: `:transparent` (empty), `{:gray, g}`, `{:rgb, r, g, b}`,
/// `{:cmyk, c, m, y, k}`, or `{:other, components}` for any other length.
#[derive(NifTaggedEnum, Debug)]
pub enum AnnotationColorNif {
    Transparent,
    Gray(f64),
    Rgb(f64, f64, f64),
    Cmyk(f64, f64, f64, f64),
    Other(Vec<f64>),
}

fn color_to_nif(components: Option<Vec<f64>>) -> Option<AnnotationColorNif> {
    components.map(|c| match c.len() {
        0 => AnnotationColorNif::Transparent,
        1 => AnnotationColorNif::Gray(c[0]),
        3 => AnnotationColorNif::Rgb(c[0], c[1], c[2]),
        4 => AnnotationColorNif::Cmyk(c[0], c[1], c[2], c[3]),
        _ => AnnotationColorNif::Other(c),
    })
}

/// The decoded `/F` annotation flags (ISO 32000-1 §12.5.3, Table 165), mirroring
/// `PdfElixide.Document.Permissions`: one boolean per bit plus `raw`, the
/// undecoded integer.
#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Document.Annotation.Flags"]
pub struct FlagsNif {
    invisible: bool,
    hidden: bool,
    print: bool,
    no_zoom: bool,
    no_rotate: bool,
    no_view: bool,
    read_only: bool,
    locked: bool,
    toggle_no_view: bool,
    locked_contents: bool,
    raw: i64,
}

fn flags_to_nif(flags: AnnotationFlags) -> FlagsNif {
    FlagsNif {
        invisible: flags.contains(AnnotationFlags::INVISIBLE),
        hidden: flags.contains(AnnotationFlags::HIDDEN),
        print: flags.contains(AnnotationFlags::PRINT),
        no_zoom: flags.contains(AnnotationFlags::NO_ZOOM),
        no_rotate: flags.contains(AnnotationFlags::NO_ROTATE),
        no_view: flags.contains(AnnotationFlags::NO_VIEW),
        read_only: flags.contains(AnnotationFlags::READ_ONLY),
        locked: flags.contains(AnnotationFlags::LOCKED),
        toggle_no_view: flags.contains(AnnotationFlags::TOGGLE_NO_VIEW),
        locked_contents: flags.contains(AnnotationFlags::LOCKED_CONTENTS),
        raw: i64::from(flags.bits()),
    }
}

/// Converts a `pdf_oxide::Annotation` (and its zero-based page index) into its
/// NIF representation.
pub fn annotation_to_nif(annotation: Annotation, page: usize) -> AnnotationNif {
    AnnotationNif {
        page,
        annotation_type: annotation.annotation_type,
        subtype: annotation.subtype_enum.into(),
        raw_subtype: annotation.subtype,
        contents: annotation.contents,
        rect: annotation
            .rect
            .map(|[x1, y1, x2, y2]| rect_from_corners(x1, y1, x2, y2)),
        author: annotation.author,
        subject: annotation.subject,
        creation_date: annotation.creation_date,
        modification_date: annotation.modification_date,
        destination: annotation.destination.map(Into::into),
        action: annotation.action.map(Into::into),
        quad_points: annotation
            .quad_points
            .map(|quads| quads.into_iter().map(|quad| quad.to_vec()).collect()),
        color: color_to_nif(annotation.color),
        interior_color: color_to_nif(annotation.interior_color),
        opacity: annotation.opacity,
        flags: flags_to_nif(annotation.flags),
        border: annotation.border.map(|border| border.to_vec()),
        field_type: annotation.field_type.map(Into::into),
        field_name: annotation.field_name,
        field_value: annotation.field_value,
        default_value: annotation.default_value,
        field_flags: annotation.field_flags,
        options: annotation.options,
        appearance_state: annotation.appearance_state,
    }
}
