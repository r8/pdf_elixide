use pdf_oxide::{
    editor::form_fields::{FormFieldValue, FormFieldWrapper},
    extractors::{
        forms::{FieldType, FieldValue},
        FormField,
    },
};
use rustler::{NifStruct, NifUntaggedEnum};

// One untagged type serves reads and writes so a reported field value can be
// written back without translation.
#[derive(NifUntaggedEnum, Debug, PartialEq)]
pub enum FieldValueNif {
    Boolean(bool),
    Text(String),
    List(Vec<String>),
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Text"]
pub struct TextFieldNif {
    name: String,
    value: Option<FieldValueNif>,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Button"]
pub struct ButtonFieldNif {
    name: String,
    value: Option<FieldValueNif>,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Choice"]
pub struct ChoiceFieldNif {
    name: String,
    value: Option<FieldValueNif>,
}

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field.Unknown"]
pub struct UnknownFieldNif {
    name: String,
    raw_type: Option<String>,
    value: Option<FieldValueNif>,
}

// One AcroForm field. Untagged so each variant encodes as the bare struct —
// Elixir sees `%PdfElixide.Form.Field.Text{}` and friends directly, with no
// wrapping tuple. The `AnnotationColorNif` shape (see color.rs).
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
) -> Option<FieldNif> {
    match field_type {
        Some(FieldType::Text) => Some(FieldNif::Text(TextFieldNif { name, value })),
        Some(FieldType::Button) => Some(FieldNif::Button(ButtonFieldNif { name, value })),
        Some(FieldType::Choice) => Some(FieldNif::Choice(ChoiceFieldNif { name, value })),
        Some(FieldType::Signature) => None,
        // `Unknown("")` is how the extractor spells "no /FT at all" (a grouping
        // parent); the editor path spells the same condition `None`. Both land
        // as `raw_type: nil` so the two sources cannot disagree.
        Some(FieldType::Unknown(s)) => Some(FieldNif::Unknown(UnknownFieldNif {
            name,
            raw_type: (!s.is_empty()).then(|| s.clone()),
            value,
        })),
        None => Some(FieldNif::Unknown(UnknownFieldNif {
            name,
            raw_type: None,
            value,
        })),
    }
}

pub fn document_form_field_to_nif(field: FormField) -> Option<FieldNif> {
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
    )
}

pub fn editor_form_field_to_nif(wrapper: FormFieldWrapper) -> Option<FieldNif> {
    field_nif(
        wrapper.name().to_string(),
        wrapper.field_type(),
        editor_field_value_to_nif(wrapper.value()),
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
            field_nif(name(), Some(&FieldType::Text), None),
            Some(FieldNif::Text(_))
        ));
        assert!(matches!(
            field_nif(name(), Some(&FieldType::Button), None),
            Some(FieldNif::Button(_))
        ));
        assert!(matches!(
            field_nif(name(), Some(&FieldType::Choice), None),
            Some(FieldNif::Choice(_))
        ));
        assert!(field_nif(name(), Some(&FieldType::Signature), None).is_none());

        // The three ways of arriving at `Unknown`, and what each says about
        // `raw_type`. The empty string and `None` are the same condition — a
        // field with no `/FT` — spelled differently by the two upstream paths.
        let empty = FieldType::Unknown(String::new());
        let named = FieldType::Unknown(String::from("Barcode"));

        for field_type in [Some(&empty), None] {
            match field_nif(name(), field_type, None) {
                Some(FieldNif::Unknown(f)) => assert_eq!(f.raw_type, None, "{field_type:?}"),
                other => panic!("expected Unknown, got {other:?}"),
            }
        }

        match field_nif(name(), Some(&named), None) {
            Some(FieldNif::Unknown(f)) => assert_eq!(f.raw_type.as_deref(), Some("Barcode")),
            other => panic!("expected Unknown, got {other:?}"),
        }
    }
}
