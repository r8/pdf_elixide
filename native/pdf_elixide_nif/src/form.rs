use pdf_oxide::{
    editor::form_fields::{FormFieldValue, FormFieldWrapper},
    extractors::{
        forms::{field_flags, FieldType, FieldValue},
        FormField,
    },
    fdf::{FdfWriter, XfdfWriter},
};
use rustler::{NifResult, NifStruct, NifUnitEnum, NifUntaggedEnum};

use crate::{
    error::to_nif_err,
    form_tree::{Resolved, ResolvedAttrs},
    geometry::{rect_from_corners, RectNif},
};

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

// One `/Opt` entry (Table 231): a bare export value, or an `[export, display]`
// pair whose second element is what a viewer shows. Untagged so a bare entry
// encodes as a string and a pair as a two-tuple, with no wrapping tag.
#[derive(NifUntaggedEnum, Clone, Debug, PartialEq)]
pub enum ChoiceOptionNif {
    Pair((String, String)),
    Export(String),
}

// `/Q` (Table 222). A value outside 0-2 names no alignment the specification
// defines, so it reports as absent rather than as a fourth answer — the same
// tolerance `form_tree` gives a non-integer `/Ff`.
#[derive(NifUnitEnum, Clone, Copy, Debug, PartialEq)]
pub enum AlignmentNif {
    Left,
    Center,
    Right,
}

fn alignment_nif(quadding: Option<u32>) -> Option<AlignmentNif> {
    match quadding? {
        0 => Some(AlignmentNif::Left),
        1 => Some(AlignmentNif::Center),
        2 => Some(AlignmentNif::Right),
        _ => None,
    }
}

// The `/TU`, `/Rect`, `/DV`, `/MaxLen` and `/Q` entries upstream parses onto
// `FormField`. Both paths build it from that one struct — the editor reaches it
// through `FormFieldWrapper::original()` — so a field read from a document and
// the same field read from an editor cannot disagree about them.
#[derive(Debug, Default)]
struct FieldMeta {
    tooltip: Option<String>,
    rect: Option<RectNif>,
    default_value: Option<FieldValueNif>,
    max_length: Option<u32>,
    alignment: Option<AlignmentNif>,
}

impl From<&FormField> for FieldMeta {
    fn from(field: &FormField) -> Self {
        FieldMeta {
            tooltip: field.tooltip.clone(),
            // Converted here rather than through `FormFieldWrapper::bounds()`,
            // which hands this corner array to a width/height constructor and
            // so reports the far corner as the size.
            rect: field
                .bounds
                .map(|[x1, y1, x2, y2]| rect_from_corners(x1, y1, x2, y2)),
            default_value: field
                .default_value
                .clone()
                .and_then(document_field_value_to_nif),
            max_length: field.max_length,
            alignment: alignment_nif(field.alignment),
        }
    }
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
    default_value: Option<FieldValueNif>,
    flags: TextFlagsNif,
    tooltip: Option<String>,
    rect: Option<RectNif>,
    max_length: Option<u32>,
    alignment: Option<AlignmentNif>,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Button"]
pub struct ButtonFieldNif {
    name: String,
    kind: ButtonKindNif,
    value: Option<FieldValueNif>,
    default_value: Option<FieldValueNif>,
    flags: ButtonFlagsNif,
    tooltip: Option<String>,
    rect: Option<RectNif>,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Choice"]
pub struct ChoiceFieldNif {
    name: String,
    kind: ChoiceKindNif,
    value: Option<FieldValueNif>,
    default_value: Option<FieldValueNif>,
    flags: ChoiceFlagsNif,
    tooltip: Option<String>,
    rect: Option<RectNif>,
    alignment: Option<AlignmentNif>,
    options: Option<Vec<ChoiceOptionNif>>,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Unknown"]
pub struct UnknownFieldNif {
    name: String,
    raw_type: Option<String>,
    value: Option<FieldValueNif>,
    default_value: Option<FieldValueNif>,
    flags: CommonFlagsNif,
    tooltip: Option<String>,
    rect: Option<RectNif>,
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

// Upstream's own list (`FormExtractor::parse_field_value`), which it applies
// only when the `/FT` it read off the own dictionary already said `/Btn`.
fn button_value_nif(name: String) -> FieldValueNif {
    match name.as_str() {
        "Yes" | "On" => FieldValueNif::Boolean(true),
        "No" | "Off" => FieldValueNif::Boolean(false),
        _ => FieldValueNif::Text(name),
    }
}

// Upstream parses `/V` and `/DV` against the `/FT` it read off the own
// dictionary, so a button typed only by an ancestor arrives with `/Yes` and
// `/Off` still text. Gated on the own type because an own-typed button has had
// both mapped already, and a text field's literal `"Yes"` must stay a string.
fn remap_inherited_button_value(
    field_type: &Option<FieldType>,
    own_type: Option<&FieldType>,
    value: Option<FieldValueNif>,
) -> Option<FieldValueNif> {
    match (field_type, value) {
        (Some(FieldType::Button), Some(FieldValueNif::Text(text)))
            if own_type != Some(&FieldType::Button) =>
        {
            Some(button_value_nif(text))
        }
        (_, value) => value,
    }
}

// Drop signatures from reads here; inherited signature types are filtered by
// `form_tree`, while the editor separately guards direct writes.
fn field_nif(
    name: String,
    own_type: Option<&FieldType>,
    own_flags: Option<u32>,
    value: Option<FieldValueNif>,
    meta: FieldMeta,
    attrs: Option<ResolvedAttrs<'_>>,
) -> Option<FieldNif> {
    // Refused whatever the walk resolved for this *name*: §12.7.3.2 requires
    // fully qualified names to be unique and the walk answers with the first
    // field of a name, so in a form breaking that rule a later `/Sig` row would
    // otherwise inherit the first row's type and become fillable.
    if own_type == Some(&FieldType::Signature) {
        return None;
    }

    let FieldMeta {
        tooltip,
        rect,
        default_value,
        max_length,
        alignment,
    } = meta;

    // The walk's reading wins outright for a field it reached, rejections
    // included, so a declaration it dropped does not fall back to upstream's
    // own. The source answers only for a field the walk never reached.
    // Normalizing `/Q` after the choice keeps `/Q 7` reporting nil either way.
    let (field_type, bits, options, max_length, alignment) = match attrs {
        Some(attrs) => (
            attrs.field_type,
            attrs.flags.unwrap_or_default(),
            attrs.options,
            attrs.max_length,
            alignment_nif(attrs.quadding),
        ),
        None => (
            own_type.cloned(),
            own_flags.unwrap_or_default(),
            None,
            max_length,
            alignment,
        ),
    };

    let value = remap_inherited_button_value(&field_type, own_type, value);
    let default_value = remap_inherited_button_value(&field_type, own_type, default_value);

    match field_type {
        Some(FieldType::Text) => Some(FieldNif::Text(TextFieldNif {
            name,
            kind: text_kind_nif(bits),
            value,
            default_value,
            flags: text_flags_nif(bits),
            tooltip,
            rect,
            max_length,
            alignment,
        })),
        // `/MaxLen` and `/Q` are text- and variable-text-field entries, so a
        // button carrying either is malformed and the value is dropped.
        Some(FieldType::Button) => Some(FieldNif::Button(ButtonFieldNif {
            name,
            kind: button_kind_nif(bits),
            value,
            default_value,
            flags: button_flags_nif(bits),
            tooltip,
            rect,
        })),
        Some(FieldType::Choice) => Some(FieldNif::Choice(ChoiceFieldNif {
            name,
            kind: choice_kind_nif(bits),
            value,
            default_value,
            flags: choice_flags_nif(bits),
            tooltip,
            rect,
            alignment,
            options: options.map(<[ChoiceOptionNif]>::to_vec),
        })),
        Some(FieldType::Signature) => None,
        // `Unknown("")` is how the extractor spells "no /FT at all" (a grouping
        // parent); the editor path spells the same condition `None`. Both land
        // as `raw_type: nil` so the two sources cannot disagree.
        Some(FieldType::Unknown(s)) => Some(FieldNif::Unknown(UnknownFieldNif {
            name,
            raw_type: (!s.is_empty()).then_some(s),
            value,
            default_value,
            flags: common_flags_nif(bits),
            tooltip,
            rect,
        })),
        None => Some(FieldNif::Unknown(UnknownFieldNif {
            name,
            raw_type: None,
            value,
            default_value,
            flags: common_flags_nif(bits),
            tooltip,
            rect,
        })),
    }
}

pub fn document_form_field_to_nif(
    field: FormField,
    attrs: Option<ResolvedAttrs<'_>>,
) -> Option<FieldNif> {
    // Built before the destructure below consumes `field`. Cloning what it
    // could have moved is the price of both paths running through one
    // conversion, which is what stops them disagreeing.
    let meta = FieldMeta::from(&field);
    // Destructured because `value` moves into the mapper while `field_type` is
    // still borrowed by `field_nif`.
    let FormField {
        // `full_name`, not the partial `/T` `name`: it is the key
        // `set_form_field_value` matches on and the one the editor path
        // produces, and the two sources must agree.
        full_name,
        field_type,
        value,
        flags,
        ..
    } = field;

    field_nif(
        full_name,
        Some(&field_type),
        flags,
        document_field_value_to_nif(value),
        meta,
        attrs,
    )
}

pub fn editor_form_field_to_nif(
    wrapper: FormFieldWrapper,
    attrs: Option<ResolvedAttrs<'_>>,
) -> Option<FieldNif> {
    // Off the source `FormField`, not the wrapper's own accessors: `bounds()`
    // misreads the `/Rect` corners as a size and `get_default_value()` discards
    // what it read. `original()` is `None` only for a field this binding never
    // creates, and an all-absent `FieldMeta` is the honest answer for one.
    let meta = wrapper.original().map(FieldMeta::from).unwrap_or_default();

    field_nif(
        wrapper.name().to_string(),
        wrapper.field_type(),
        wrapper.flags(),
        editor_field_value_to_nif(wrapper.value()),
        meta,
        attrs,
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

#[derive(NifUnitEnum, Debug)]
pub enum FormDataFormatNif {
    Fdf,
    Xfdf,
}

// `Choice` originates from a `/V` name and must retain that type when exported.
fn export_field_value(value: FormFieldValue) -> FieldValue {
    match value {
        FormFieldValue::Text(s) => FieldValue::Text(s),
        FormFieldValue::Boolean(b) => FieldValue::Boolean(b),
        FormFieldValue::Choice(s) => FieldValue::Name(s),
        FormFieldValue::MultiChoice(v) => FieldValue::Array(v),
        FormFieldValue::None => FieldValue::None,
    }
}

pub fn export_form_field(wrapper: FormFieldWrapper) -> Option<FormField> {
    let mut field = wrapper.original()?.clone();
    field.value = export_field_value(wrapper.value());

    Some(field)
}

// Check both sources: the row catches duplicate names and `Resolved` catches an
// inherited `/FT`.
pub fn is_exportable(field: &FormField, resolved: &Resolved) -> bool {
    field.field_type != FieldType::Signature && !resolved.is_signature(&field.full_name)
}

pub fn export_bytes(
    fields: Vec<FormField>,
    format: FormDataFormatNif,
    file_spec: Option<String>,
) -> NifResult<Vec<u8>> {
    match format {
        FormDataFormatNif::Fdf => {
            let writer = FdfWriter::from_fields(fields);
            let writer = match file_spec {
                Some(spec) => writer.with_file_spec(spec),
                None => writer,
            };

            writer.to_bytes().map_err(to_nif_err)
        }
        FormDataFormatNif::Xfdf => {
            let writer = XfdfWriter::from_fields(fields);
            let writer = match file_spec {
                Some(spec) => writer.with_file_spec(spec),
                None => writer,
            };

            Ok(writer.to_bytes())
        }
    }
}

#[cfg(test)]
mod tests {
    use pdf_oxide::{
        document::PdfDocument, editor::DocumentEditor, extractors::FormExtractor, geometry::Rect,
        object::Object,
    };

    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "{}/../../test/fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            name
        )
    }

    // The `form_metadata.pdf` field carrying every new entry at once.
    fn metadata_field(name: &str) -> FormFieldWrapper {
        let mut editor = DocumentEditor::open(fixture("form_metadata.pdf")).expect("fixture opens");

        editor
            .get_form_fields()
            .expect("fields extract")
            .into_iter()
            .find(|field| field.name() == name)
            .unwrap_or_else(|| panic!("no field named {name}"))
    }

    fn meta() -> FieldMeta {
        FieldMeta::default()
    }

    fn meta_with_default(value: FieldValueNif) -> FieldMeta {
        FieldMeta {
            default_value: Some(value),
            ..FieldMeta::default()
        }
    }

    // A field the walk did not reach, so the source's own reading answers.
    fn unreached() -> Option<ResolvedAttrs<'static>> {
        None
    }

    fn resolved_type(field_type: FieldType) -> Option<ResolvedAttrs<'static>> {
        Some(ResolvedAttrs {
            field_type: Some(field_type),
            ..ResolvedAttrs::default()
        })
    }

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
            field_nif(
                name(),
                Some(&FieldType::Text),
                None,
                None,
                meta(),
                unreached()
            ),
            Some(FieldNif::Text(_))
        ));
        assert!(matches!(
            field_nif(
                name(),
                Some(&FieldType::Button),
                None,
                None,
                meta(),
                unreached()
            ),
            Some(FieldNif::Button(_))
        ));
        assert!(matches!(
            field_nif(
                name(),
                Some(&FieldType::Choice),
                None,
                None,
                meta(),
                unreached()
            ),
            Some(FieldNif::Choice(_))
        ));
        assert!(field_nif(
            name(),
            Some(&FieldType::Signature),
            None,
            None,
            meta(),
            unreached()
        )
        .is_none());

        // The three ways of arriving at `Unknown`, and what each says about
        // `raw_type`. The empty string and `None` are the same condition — a
        // field with no `/FT` — spelled differently by the two upstream paths.
        let empty = FieldType::Unknown(String::new());
        let named = FieldType::Unknown(String::from("Barcode"));

        for field_type in [Some(&empty), None] {
            match field_nif(name(), field_type, None, None, meta(), unreached()) {
                Some(FieldNif::Unknown(f)) => assert_eq!(f.raw_type, None, "{field_type:?}"),
                other => panic!("expected Unknown, got {other:?}"),
            }
        }

        match field_nif(name(), Some(&named), None, None, meta(), unreached()) {
            Some(FieldNif::Unknown(f)) => assert_eq!(f.raw_type.as_deref(), Some("Barcode")),
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    // A field the walk reached is dispatched on what the walk resolved, not on
    // the type upstream read off the own dictionary — which is `Unknown("")`
    // for every field typed only by an ancestor.
    #[test]
    fn a_resolved_field_type_decides_the_struct_over_the_sources_own() {
        let name = || String::from("f");
        let own = FieldType::Unknown(String::new());

        assert!(matches!(
            field_nif(
                name(),
                Some(&own),
                None,
                None,
                meta(),
                resolved_type(FieldType::Choice)
            ),
            Some(FieldNif::Choice(_))
        ));
        assert!(field_nif(
            name(),
            Some(&own),
            None,
            None,
            meta(),
            resolved_type(FieldType::Signature)
        )
        .is_none());
    }

    // Each spelling is carried in `/V` and `/DV` at once, because upstream
    // parses both against the own `/FT` and so loses both the same way.
    #[test]
    fn a_button_typed_by_inheritance_still_reports_boolean_values() {
        let name = || String::from("f");
        let own = FieldType::Unknown(String::new());
        let text = |s: &str| FieldValueNif::Text(String::from(s));

        for (spelling, expected) in [
            ("Yes", FieldValueNif::Boolean(true)),
            ("On", FieldValueNif::Boolean(true)),
            ("No", FieldValueNif::Boolean(false)),
            ("Off", FieldValueNif::Boolean(false)),
            ("Choice1", FieldValueNif::Text(String::from("Choice1"))),
        ] {
            match field_nif(
                name(),
                Some(&own),
                None,
                Some(text(spelling)),
                meta_with_default(text(spelling)),
                resolved_type(FieldType::Button),
            ) {
                Some(FieldNif::Button(f)) => {
                    assert_eq!(f.value, Some(expected), "{spelling}");
                    assert_eq!(f.default_value, f.value, "{spelling}");
                }
                other => panic!("expected Button, got {other:?}"),
            }
        }

        // Upstream typed this one itself, so only a genuine string reaches the
        // remap.
        match field_nif(
            name(),
            Some(&FieldType::Button),
            None,
            Some(text("Yes")),
            meta_with_default(text("Yes")),
            resolved_type(FieldType::Button),
        ) {
            Some(FieldNif::Button(f)) => {
                assert_eq!(f.value, Some(text("Yes")));
                assert_eq!(f.default_value, Some(text("Yes")));
            }
            other => panic!("expected Button, got {other:?}"),
        }

        match field_nif(
            name(),
            Some(&own),
            None,
            Some(text("Yes")),
            meta_with_default(text("Yes")),
            resolved_type(FieldType::Text),
        ) {
            Some(FieldNif::Text(f)) => {
                assert_eq!(f.value, Some(text("Yes")));
                assert_eq!(f.default_value, Some(text("Yes")));
            }
            other => panic!("expected Text, got {other:?}"),
        }
    }

    // Every button kind is derived from these two bits, so a drift in either
    // silently retypes every one of them.
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

    #[test]
    fn upstream_still_reads_a_field_rect_as_a_size() {
        let field = metadata_field("full_name");
        let original = field.original().expect("read from the source document");

        assert_eq!(original.bounds, Some([100.0, 700.0, 260.0, 720.0]));
        assert_eq!(
            field.bounds(),
            Some(Rect::new(100.0, 700.0, 260.0, 720.0)),
            "upstream now re-corners a field /Rect; delete the conversion in \
             FieldMeta::from, not this assertion"
        );

        // The same field through the local conversion, which is the 160 x 20
        // box the PDF actually declares.
        let meta = FieldMeta::from(original);
        let rect = meta.rect.expect("a /Rect");

        assert_eq!((rect.x, rect.y), (100.0, 700.0));
        assert_eq!((rect.width, rect.height), (160.0, 20.0));
    }

    #[test]
    fn upstream_still_discards_a_read_default_value() {
        let field = metadata_field("full_name");

        assert!(
            matches!(field.get_default_value(), None | Some(FormFieldValue::None)),
            "upstream now returns a read /DV, so read the accessor instead: {:?}",
            field.get_default_value()
        );

        // The value is there — it is the accessor that loses it.
        assert_eq!(
            field.original().and_then(|f| f.default_value.clone()),
            Some(FieldValue::Text(String::from("Jane Roe")))
        );
    }

    #[test]
    fn upstream_still_exports_a_signature_field() {
        let doc = PdfDocument::open(fixture("form_signature.pdf")).expect("fixture opens");
        let fields = FormExtractor::extract_fields(&doc).expect("fields extract");
        let bytes = export_bytes(fields, FormDataFormatNif::Fdf, None).expect("fdf writes");
        let fdf = String::from_utf8_lossy(&bytes);

        // Precondition: the fillable field really is exported, so the assertion
        // below cannot pass by nothing having been written at all.
        assert!(fdf.contains("/T (signer_name)"), "{fdf}");

        assert!(
            fdf.contains("/T (signature)"),
            "upstream now filters signature fields itself: {fdf}"
        );
    }
}
