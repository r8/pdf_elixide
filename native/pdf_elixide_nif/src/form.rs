use pdf_oxide::{
    editor::form_fields::{FormFieldValue, FormFieldWrapper},
    extractors::{
        forms::{field_flags, FieldType, FieldValue},
        FormField,
    },
};
use rustler::{NifStruct, NifUnitEnum, NifUntaggedEnum};

// The two bits ISO 32000-1 defines that upstream's `field_flags` module does
// not; every other value below is taken from there rather than spelled here, so
// the numbers stay sourced from the crate that reads them.
const NO_TOGGLE_TO_OFF: u32 = 1 << 14;
const FILE_SELECT: u32 = 1 << 20;

// One untagged type serves reads and writes so a reported field value can be
// written back without translation.
#[derive(NifUntaggedEnum, Debug, PartialEq)]
pub enum FieldValueNif {
    Boolean(bool),
    Text(String),
    List(Vec<String>),
}

// The `/Ff` bits ISO 32000-1 Table 226 gives every field, whatever its `/FT`.
#[derive(NifStruct, Debug, PartialEq)]
#[module = "PdfElixide.Form.Field.Flags"]
pub struct CommonFlagsNif {
    read_only: bool,
    required: bool,
    no_export: bool,
    raw: u32,
}

// One flags struct per kind rather than a union: bit 26 is RadiosInUnison on a
// `/Btn` and RichText on a `/Tx`, so a shared struct would misreport one of them.
#[derive(NifStruct, Debug, PartialEq)]
#[module = "PdfElixide.Form.Field.Text.Flags"]
pub struct TextFlagsNif {
    read_only: bool,
    required: bool,
    no_export: bool,
    multiline: bool,
    password: bool,
    file_select: bool,
    do_not_spell_check: bool,
    do_not_scroll: bool,
    comb: bool,
    rich_text: bool,
    raw: u32,
}

#[derive(NifStruct, Debug, PartialEq)]
#[module = "PdfElixide.Form.Field.Button.Flags"]
pub struct ButtonFlagsNif {
    read_only: bool,
    required: bool,
    no_export: bool,
    no_toggle_to_off: bool,
    radio: bool,
    push_button: bool,
    radios_in_unison: bool,
    raw: u32,
}

#[derive(NifStruct, Debug, PartialEq)]
#[module = "PdfElixide.Form.Field.Choice.Flags"]
pub struct ChoiceFlagsNif {
    read_only: bool,
    required: bool,
    no_export: bool,
    combo: bool,
    edit: bool,
    sort: bool,
    multi_select: bool,
    do_not_spell_check: bool,
    commit_on_sel_change: bool,
    raw: u32,
}

#[derive(NifUnitEnum, Debug, PartialEq)]
pub enum TextKindNif {
    SingleLine,
    Multiline,
}

#[derive(NifUnitEnum, Debug, PartialEq)]
pub enum ButtonKindNif {
    CheckBox,
    Radio,
    Push,
}

#[derive(NifUnitEnum, Debug, PartialEq)]
pub enum ChoiceKindNif {
    ComboBox,
    ListBox,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Text"]
pub struct TextFieldNif {
    name: String,
    kind: TextKindNif,
    value: Option<FieldValueNif>,
    flags: TextFlagsNif,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Button"]
pub struct ButtonFieldNif {
    name: String,
    kind: ButtonKindNif,
    value: Option<FieldValueNif>,
    flags: ButtonFlagsNif,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Choice"]
pub struct ChoiceFieldNif {
    name: String,
    kind: ChoiceKindNif,
    value: Option<FieldValueNif>,
    flags: ChoiceFlagsNif,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Unknown"]
pub struct UnknownFieldNif {
    name: String,
    raw_type: Option<String>,
    value: Option<FieldValueNif>,
    flags: CommonFlagsNif,
}

// An absent `/Ff` is the spec's own default of every bit clear, not a missing
// answer, so each decoder takes the resolved bits already defaulted to 0.
fn common_flags_nif(bits: u32) -> CommonFlagsNif {
    CommonFlagsNif {
        read_only: bits & field_flags::READ_ONLY != 0,
        required: bits & field_flags::REQUIRED != 0,
        no_export: bits & field_flags::NO_EXPORT != 0,
        raw: bits,
    }
}

fn text_flags_nif(bits: u32) -> TextFlagsNif {
    TextFlagsNif {
        read_only: bits & field_flags::READ_ONLY != 0,
        required: bits & field_flags::REQUIRED != 0,
        no_export: bits & field_flags::NO_EXPORT != 0,
        multiline: bits & field_flags::MULTILINE != 0,
        password: bits & field_flags::PASSWORD != 0,
        file_select: bits & FILE_SELECT != 0,
        do_not_spell_check: bits & field_flags::DO_NOT_SPELL_CHECK != 0,
        do_not_scroll: bits & field_flags::DO_NOT_SCROLL != 0,
        comb: bits & field_flags::COMB != 0,
        rich_text: bits & field_flags::RICH_TEXT != 0,
        raw: bits,
    }
}

fn button_flags_nif(bits: u32) -> ButtonFlagsNif {
    ButtonFlagsNif {
        read_only: bits & field_flags::READ_ONLY != 0,
        required: bits & field_flags::REQUIRED != 0,
        no_export: bits & field_flags::NO_EXPORT != 0,
        no_toggle_to_off: bits & NO_TOGGLE_TO_OFF != 0,
        radio: bits & field_flags::RADIO != 0,
        push_button: bits & field_flags::PUSH_BUTTON != 0,
        radios_in_unison: bits & field_flags::RADIOS_IN_UNISON != 0,
        raw: bits,
    }
}

fn choice_flags_nif(bits: u32) -> ChoiceFlagsNif {
    ChoiceFlagsNif {
        read_only: bits & field_flags::READ_ONLY != 0,
        required: bits & field_flags::REQUIRED != 0,
        no_export: bits & field_flags::NO_EXPORT != 0,
        combo: bits & field_flags::COMBO != 0,
        edit: bits & field_flags::EDIT != 0,
        sort: bits & field_flags::SORT != 0,
        multi_select: bits & field_flags::MULTI_SELECT != 0,
        do_not_spell_check: bits & field_flags::DO_NOT_SPELL_CHECK != 0,
        commit_on_sel_change: bits & field_flags::COMMIT_ON_SEL_CHANGE != 0,
        raw: bits,
    }
}

fn text_kind_nif(bits: u32) -> TextKindNif {
    if bits & field_flags::MULTILINE != 0 {
        TextKindNif::Multiline
    } else {
        TextKindNif::SingleLine
    }
}

// Push button is tested first because Table 227 makes the two mutually
// exclusive and gives no rule for a field setting both.
fn button_kind_nif(bits: u32) -> ButtonKindNif {
    if bits & field_flags::PUSH_BUTTON != 0 {
        ButtonKindNif::Push
    } else if bits & field_flags::RADIO != 0 {
        ButtonKindNif::Radio
    } else {
        ButtonKindNif::CheckBox
    }
}

fn choice_kind_nif(bits: u32) -> ChoiceKindNif {
    if bits & field_flags::COMBO != 0 {
        ChoiceKindNif::ComboBox
    } else {
        ChoiceKindNif::ListBox
    }
}

// One AcroForm field. Untagged so each variant encodes as the bare struct —
// Elixir sees `%PdfElixide.Form.Field.Text{}` and friends directly, with no
// wrapping tuple, like `AnnotationColorNif` in color.rs.
#[derive(NifUntaggedEnum, Debug)]
pub enum FieldNif {
    Text(TextFieldNif),
    Button(ButtonFieldNif),
    Choice(ChoiceFieldNif),
    Unknown(UnknownFieldNif),
}

// Drop signatures from reads here; inherited signature types are filtered by
// `form_tree`, while the editor separately guards direct writes.
fn field_nif(
    name: String,
    field_type: Option<&FieldType>,
    value: Option<FieldValueNif>,
    flags: Option<u32>,
) -> Option<FieldNif> {
    let bits = flags.unwrap_or_default();

    match field_type {
        Some(FieldType::Text) => Some(FieldNif::Text(TextFieldNif {
            name,
            kind: text_kind_nif(bits),
            value,
            flags: text_flags_nif(bits),
        })),
        Some(FieldType::Button) => Some(FieldNif::Button(ButtonFieldNif {
            name,
            kind: button_kind_nif(bits),
            value,
            flags: button_flags_nif(bits),
        })),
        Some(FieldType::Choice) => Some(FieldNif::Choice(ChoiceFieldNif {
            name,
            kind: choice_kind_nif(bits),
            value,
            flags: choice_flags_nif(bits),
        })),
        Some(FieldType::Signature) => None,
        // `Unknown("")` is how the extractor spells "no /FT at all" (a grouping
        // parent); the editor path spells the same condition `None`. Both land
        // as `raw_type: nil` so the two sources cannot disagree.
        Some(FieldType::Unknown(s)) => Some(FieldNif::Unknown(UnknownFieldNif {
            name,
            raw_type: (!s.is_empty()).then(|| s.clone()),
            value,
            flags: common_flags_nif(bits),
        })),
        None => Some(FieldNif::Unknown(UnknownFieldNif {
            name,
            raw_type: None,
            value,
            flags: common_flags_nif(bits),
        })),
    }
}

pub fn document_form_field_to_nif(field: FormField, flags: Option<u32>) -> Option<FieldNif> {
    // Destructured because `value` moves into the mapper while `field_type` is
    // still borrowed by `field_nif`.
    let FormField {
        // `full_name`, not the partial `/T` `name`: it is the key
        // `set_form_field_value` matches on and the one the editor path
        // produces, and the two sources must agree.
        full_name,
        field_type,
        value,
        ..
    } = field;

    field_nif(
        full_name,
        Some(&field_type),
        document_field_value_to_nif(value),
        flags,
    )
}

pub fn editor_form_field_to_nif(wrapper: FormFieldWrapper, flags: Option<u32>) -> Option<FieldNif> {
    field_nif(
        wrapper.name().to_string(),
        wrapper.field_type(),
        editor_field_value_to_nif(wrapper.value()),
        flags,
    )
}

fn document_field_value_to_nif(value: FieldValue) -> Option<FieldValueNif> {
    match value {
        FieldValue::Text(s) | FieldValue::Name(s) => Some(FieldValueNif::Text(s)),
        FieldValue::Boolean(b) => Some(FieldValueNif::Boolean(b)),
        FieldValue::Array(v) => Some(FieldValueNif::List(v)),
        FieldValue::None => None,
    }
}

fn editor_field_value_to_nif(value: FormFieldValue) -> Option<FieldValueNif> {
    match value {
        FormFieldValue::Text(s) | FormFieldValue::Choice(s) => Some(FieldValueNif::Text(s)),
        FormFieldValue::Boolean(b) => Some(FieldValueNif::Boolean(b)),
        FormFieldValue::MultiChoice(v) => Some(FieldValueNif::List(v)),
        FormFieldValue::None => None,
    }
}

pub fn set_value_from_nif(value: Option<FieldValueNif>) -> FormFieldValue {
    match value {
        Some(FieldValueNif::Boolean(b)) => FormFieldValue::Boolean(b),
        Some(FieldValueNif::Text(s)) => FormFieldValue::Text(s),
        Some(FieldValueNif::List(v)) => FormFieldValue::MultiChoice(v),
        None => FormFieldValue::None,
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::object::Object;

    use super::*;

    fn every_field_value() -> Vec<FieldValue> {
        vec![
            FieldValue::Text(String::from("typed")),
            FieldValue::Boolean(true),
            FieldValue::Name(String::from("Off")),
            FieldValue::Array(vec![String::from("a"), String::from("b")]),
            FieldValue::None,
        ]
    }

    #[test]
    fn both_decoding_spellings_agree_through_upstreams_own_conversion() {
        for value in every_field_value() {
            let from_editor = editor_field_value_to_nif(FormFieldValue::from(value.clone()));

            assert_eq!(
                document_field_value_to_nif(value.clone()),
                from_editor,
                "{value:?}"
            );
        }
    }

    #[test]
    fn a_read_value_written_back_lands_as_the_same_pdf_object() {
        for value in every_field_value() {
            let original = FormFieldValue::from(value.clone());
            let written = set_value_from_nif(document_field_value_to_nif(value.clone()));

            assert_eq!(Object::from(&written), Object::from(&original), "{value:?}");
        }
    }

    #[test]
    fn kind_dispatch_and_raw_type_normalization() {
        let name = || String::from("f");

        assert!(matches!(
            field_nif(name(), Some(&FieldType::Text), None, None),
            Some(FieldNif::Text(_))
        ));
        assert!(matches!(
            field_nif(name(), Some(&FieldType::Button), None, None),
            Some(FieldNif::Button(_))
        ));
        assert!(matches!(
            field_nif(name(), Some(&FieldType::Choice), None, None),
            Some(FieldNif::Choice(_))
        ));
        assert!(field_nif(name(), Some(&FieldType::Signature), None, None).is_none());

        // The three ways of arriving at `Unknown`, and what each says about
        // `raw_type`. The empty string and `None` are the same condition — a
        // field with no `/FT` — spelled differently by the two upstream paths.
        let empty = FieldType::Unknown(String::new());
        let named = FieldType::Unknown(String::from("Barcode"));

        for field_type in [Some(&empty), None] {
            match field_nif(name(), field_type, None, None) {
                Some(FieldNif::Unknown(f)) => assert_eq!(f.raw_type, None, "{field_type:?}"),
                other => panic!("expected Unknown, got {other:?}"),
            }
        }

        match field_nif(name(), Some(&named), None, None) {
            Some(FieldNif::Unknown(f)) => assert_eq!(f.raw_type.as_deref(), Some("Barcode")),
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    // Every kind is derived from these two, and upstream's own annotation parser
    // reads them the other way round (`src/annotations.rs`, the /Btn arm), so a
    // "correction" there could reach the constants module too.
    #[test]
    fn upstream_field_flag_constants_still_match_table_227() {
        assert_eq!(field_flags::RADIO, 0x8000);
        assert_eq!(field_flags::PUSH_BUTTON, 0x10000);
    }

    #[test]
    fn each_bit_decodes_to_exactly_one_boolean() {
        type Bit<F> = (u32, &'static str, fn(&F) -> bool);

        fn assert_isolated<F: std::fmt::Debug>(decode: fn(u32) -> F, bits: &[Bit<F>], label: &str) {
            let clear = decode(0);

            for (bit, name, accessor) in bits {
                assert!(!accessor(&clear), "{label}: {name} set on cleared flags");

                let decoded = decode(*bit);

                assert!(accessor(&decoded), "{label}: {name} not set by {bit:#x}");

                for (other, other_name, other_accessor) in bits {
                    if other != bit {
                        assert!(
                            !other_accessor(&decoded),
                            "{label}: {bit:#x} also set {other_name}"
                        );
                    }
                }
            }
        }

        assert_isolated(
            common_flags_nif,
            &[
                (field_flags::READ_ONLY, "read_only", |f| f.read_only),
                (field_flags::REQUIRED, "required", |f| f.required),
                (field_flags::NO_EXPORT, "no_export", |f| f.no_export),
            ],
            "common",
        );

        assert_isolated(
            text_flags_nif,
            &[
                (field_flags::READ_ONLY, "read_only", |f| f.read_only),
                (field_flags::REQUIRED, "required", |f| f.required),
                (field_flags::NO_EXPORT, "no_export", |f| f.no_export),
                (field_flags::MULTILINE, "multiline", |f| f.multiline),
                (field_flags::PASSWORD, "password", |f| f.password),
                (FILE_SELECT, "file_select", |f| f.file_select),
                (field_flags::DO_NOT_SPELL_CHECK, "do_not_spell_check", |f| {
                    f.do_not_spell_check
                }),
                (field_flags::DO_NOT_SCROLL, "do_not_scroll", |f| {
                    f.do_not_scroll
                }),
                (field_flags::COMB, "comb", |f| f.comb),
                (field_flags::RICH_TEXT, "rich_text", |f| f.rich_text),
            ],
            "text",
        );

        assert_isolated(
            button_flags_nif,
            &[
                (field_flags::READ_ONLY, "read_only", |f| f.read_only),
                (field_flags::REQUIRED, "required", |f| f.required),
                (field_flags::NO_EXPORT, "no_export", |f| f.no_export),
                (NO_TOGGLE_TO_OFF, "no_toggle_to_off", |f| f.no_toggle_to_off),
                (field_flags::RADIO, "radio", |f| f.radio),
                (field_flags::PUSH_BUTTON, "push_button", |f| f.push_button),
                (field_flags::RADIOS_IN_UNISON, "radios_in_unison", |f| {
                    f.radios_in_unison
                }),
            ],
            "button",
        );

        assert_isolated(
            choice_flags_nif,
            &[
                (field_flags::READ_ONLY, "read_only", |f| f.read_only),
                (field_flags::REQUIRED, "required", |f| f.required),
                (field_flags::NO_EXPORT, "no_export", |f| f.no_export),
                (field_flags::COMBO, "combo", |f| f.combo),
                (field_flags::EDIT, "edit", |f| f.edit),
                (field_flags::SORT, "sort", |f| f.sort),
                (field_flags::MULTI_SELECT, "multi_select", |f| {
                    f.multi_select
                }),
                (field_flags::DO_NOT_SPELL_CHECK, "do_not_spell_check", |f| {
                    f.do_not_spell_check
                }),
                (
                    field_flags::COMMIT_ON_SEL_CHANGE,
                    "commit_on_sel_change",
                    |f| f.commit_on_sel_change,
                ),
            ],
            "choice",
        );
    }

    #[test]
    fn an_undefined_bit_survives_only_in_raw() {
        let undefined = 1 << 30;

        assert_eq!(
            common_flags_nif(undefined),
            CommonFlagsNif {
                read_only: false,
                required: false,
                no_export: false,
                raw: undefined,
            }
        );
    }

    #[test]
    fn kinds_default_to_the_spec_defaults_when_no_bit_is_set() {
        assert_eq!(text_kind_nif(0), TextKindNif::SingleLine);
        assert_eq!(button_kind_nif(0), ButtonKindNif::CheckBox);
        assert_eq!(choice_kind_nif(0), ChoiceKindNif::ListBox);
    }

    #[test]
    fn push_button_wins_over_radio() {
        assert_eq!(
            button_kind_nif(field_flags::PUSH_BUTTON | field_flags::RADIO),
            ButtonKindNif::Push
        );
        assert_eq!(button_kind_nif(field_flags::RADIO), ButtonKindNif::Radio);
        assert_eq!(
            button_kind_nif(field_flags::PUSH_BUTTON),
            ButtonKindNif::Push
        );
    }

    #[test]
    fn the_remaining_kinds_switch_on_their_own_bit() {
        assert_eq!(
            text_kind_nif(field_flags::MULTILINE),
            TextKindNif::Multiline
        );
        assert_eq!(choice_kind_nif(field_flags::COMBO), ChoiceKindNif::ComboBox);
    }
}
