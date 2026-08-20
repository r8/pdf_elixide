use pdf_oxide::{
    extractors::forms::field_flags, Annotation, AnnotationFlags, AnnotationSubtype, LinkAction,
    LinkDestination, WidgetFieldType,
};
use rustler::{NifMap, NifStruct, NifTaggedEnum, NifUnitEnum};

use crate::{
    color::{annotation_color_to_nif, AnnotationColorNif},
    geometry::{rect_from_corners, RectNif},
};

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

#[derive(NifTaggedEnum, Debug, PartialEq)]
pub enum WidgetFieldTypeNif {
    Text,
    Checkbox(bool),
    Radio(Option<String>),
    Button,
    Choice(Vec<String>, Option<String>),
    Signature,
    Unknown,
}

// Upstream's classifier reads Table 227's Radio and Pushbutton bits backwards,
// so the `/Btn` trio is re-derived here. Which of the three arrives says only
// that `/FT` was `/Btn`, which is why no `/FT` string is needed.
fn widget_field_type_nif(
    field_type: WidgetFieldType,
    flags: Option<u32>,
    appearance_state: Option<&str>,
) -> WidgetFieldTypeNif {
    match field_type {
        WidgetFieldType::Checkbox { .. }
        | WidgetFieldType::Radio { .. }
        | WidgetFieldType::Button => {
            button_field_type_nif(flags.unwrap_or_default(), appearance_state)
        }
        WidgetFieldType::Text => WidgetFieldTypeNif::Text,
        WidgetFieldType::Choice { options, selected } => {
            WidgetFieldTypeNif::Choice(options, selected)
        }
        WidgetFieldType::Signature => WidgetFieldTypeNif::Signature,
        WidgetFieldType::Unknown => WidgetFieldTypeNif::Unknown,
    }
}

// The payloads are upstream's, kept identical so only the classification changes.
fn button_field_type_nif(flags: u32, appearance_state: Option<&str>) -> WidgetFieldTypeNif {
    if flags & field_flags::PUSH_BUTTON != 0 {
        WidgetFieldTypeNif::Button
    } else if flags & field_flags::RADIO != 0 {
        WidgetFieldTypeNif::Radio(appearance_state.map(String::from))
    } else {
        let checked = appearance_state.is_some_and(|state| state != "Off" && !state.is_empty());

        WidgetFieldTypeNif::Checkbox(checked)
    }
}

// The decoded `/F` annotation flags (ISO 32000-1 §12.5.3, Table 165), mirroring
// `PdfElixide.Document.Permissions`: one boolean per bit plus `raw`, the
// undecoded integer.
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
        color: annotation_color_to_nif(annotation.color),
        interior_color: annotation_color_to_nif(annotation.interior_color),
        opacity: annotation.opacity,
        flags: flags_to_nif(annotation.flags),
        border: annotation.border.map(|border| border.to_vec()),
        field_type: annotation.field_type.map(|field_type| {
            widget_field_type_nif(
                field_type,
                annotation.field_flags,
                annotation.appearance_state.as_deref(),
            )
        }),
        field_name: annotation.field_name,
        field_value: annotation.field_value,
        default_value: annotation.default_value,
        field_flags: annotation.field_flags,
        options: annotation.options,
        appearance_state: annotation.appearance_state,
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::PdfDocument;

    use super::*;

    type Bit = (u32, u32, &'static str, fn(&FlagsNif) -> bool);

    const BITS: [Bit; 10] = [
        (1, AnnotationFlags::INVISIBLE, "invisible", |f| f.invisible),
        (2, AnnotationFlags::HIDDEN, "hidden", |f| f.hidden),
        (3, AnnotationFlags::PRINT, "print", |f| f.print),
        (4, AnnotationFlags::NO_ZOOM, "no_zoom", |f| f.no_zoom),
        (5, AnnotationFlags::NO_ROTATE, "no_rotate", |f| f.no_rotate),
        (6, AnnotationFlags::NO_VIEW, "no_view", |f| f.no_view),
        (7, AnnotationFlags::READ_ONLY, "read_only", |f| f.read_only),
        (8, AnnotationFlags::LOCKED, "locked", |f| f.locked),
        (9, AnnotationFlags::TOGGLE_NO_VIEW, "toggle_no_view", |f| {
            f.toggle_no_view
        }),
        (
            10,
            AnnotationFlags::LOCKED_CONTENTS,
            "locked_contents",
            |f| f.locked_contents,
        ),
    ];

    // Reading a fixture is the only way to reach the parser: `field_type` is
    // what it decides, not what the PDF declares.
    #[test]
    fn upstream_still_reads_the_button_flag_bits_backwards() {
        let doc = PdfDocument::open(format!(
            "{}/../../test/fixtures/form_flags.pdf",
            env!("CARGO_MANIFEST_DIR")
        ))
        .expect("fixture opens");

        let annotations = doc.get_annotations(0).expect("annotations extract");

        let of = |name: &str| {
            annotations
                .iter()
                .find(|annotation| annotation.field_name.as_deref() == Some(name))
                .map(|annotation| (annotation.field_flags, annotation.field_type.clone()))
                .expect("the fixture's widget")
        };

        assert_eq!(
            of("push"),
            (
                Some(field_flags::PUSH_BUTTON),
                Some(WidgetFieldType::Radio { selected: None })
            ),
            "upstream now reads bit 17 as Pushbutton"
        );

        assert_eq!(
            of("radio"),
            (Some(field_flags::RADIO), Some(WidgetFieldType::Button)),
            "upstream now reads bit 16 as Radio"
        );
    }

    #[test]
    fn the_button_trio_is_reclassified_from_the_flags() {
        assert_eq!(
            button_field_type_nif(field_flags::PUSH_BUTTON, Some("Choice1")),
            WidgetFieldTypeNif::Button
        );
        assert_eq!(
            button_field_type_nif(field_flags::RADIO, Some("Choice1")),
            WidgetFieldTypeNif::Radio(Some(String::from("Choice1")))
        );
        assert_eq!(
            button_field_type_nif(0, Some("Yes")),
            WidgetFieldTypeNif::Checkbox(true)
        );
        assert_eq!(
            button_field_type_nif(0, Some("Off")),
            WidgetFieldTypeNif::Checkbox(false)
        );
        assert_eq!(
            button_field_type_nif(0, None),
            WidgetFieldTypeNif::Checkbox(false)
        );
    }

    #[test]
    fn every_other_widget_type_passes_through() {
        assert_eq!(
            widget_field_type_nif(WidgetFieldType::Text, Some(field_flags::RADIO), None),
            WidgetFieldTypeNif::Text
        );
        assert_eq!(
            widget_field_type_nif(WidgetFieldType::Signature, None, None),
            WidgetFieldTypeNif::Signature
        );
        assert_eq!(
            widget_field_type_nif(WidgetFieldType::Unknown, None, None),
            WidgetFieldTypeNif::Unknown
        );
        assert_eq!(
            widget_field_type_nif(
                WidgetFieldType::Choice {
                    options: vec![String::from("One")],
                    selected: Some(String::from("One")),
                },
                None,
                None,
            ),
            WidgetFieldTypeNif::Choice(vec![String::from("One")], Some(String::from("One")))
        );
    }

    #[test]
    fn each_flag_bit_sets_exactly_its_own_field() {
        for (position, bit, name, _) in BITS {
            let decoded = flags_to_nif(AnnotationFlags::new(bit));

            for (other_position, _, other_name, accessor) in BITS {
                assert_eq!(
                    accessor(&decoded),
                    position == other_position,
                    "bit {position} (/{name}) set {other_name}"
                );
            }
        }
    }

    #[test]
    fn the_flag_constants_still_match_the_spec_bit_positions() {
        for (position, bit, name, _) in BITS {
            assert_eq!(bit, 1 << (position - 1), "/{name}");
        }
    }

    #[test]
    fn raw_carries_the_undecoded_bits() {
        let all_defined = all_defined_bits();
        let with_reserved = all_defined | 1 << 31;

        assert_eq!(flags_to_nif(AnnotationFlags::new(0)).raw, 0);
        assert_eq!(
            flags_to_nif(AnnotationFlags::new(all_defined)).raw,
            i64::from(all_defined)
        );
        assert_eq!(
            flags_to_nif(AnnotationFlags::new(with_reserved)).raw,
            i64::from(with_reserved)
        );
    }

    #[test]
    fn a_reserved_bit_sets_no_field_but_survives_in_raw() {
        let decoded = flags_to_nif(AnnotationFlags::new(1 << 10));

        for (_, _, name, accessor) in BITS {
            assert!(!accessor(&decoded), "reserved bit 11 set {name}");
        }
        assert_eq!(decoded.raw, 1024);
    }

    fn all_defined_bits() -> u32 {
        BITS.iter().fold(0, |acc, (_, bit, _, _)| acc | bit)
    }

    #[test]
    fn decodes_the_empty_and_full_flag_sets() {
        let empty = flags_to_nif(AnnotationFlags::new(0));
        let full = flags_to_nif(AnnotationFlags::new(all_defined_bits()));

        for (_, _, name, accessor) in BITS {
            assert!(!accessor(&empty), "{name} set on empty flags");
            assert!(accessor(&full), "{name} unset on full flags");
        }
    }
}
