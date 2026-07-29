use pdf_oxide::{
    editor::form_fields::{FormFieldValue, FormFieldWrapper},
    extractors::{
        forms::{FieldType, FieldValue},
        FormField,
    },
};
use rustler::{Atom, NifStruct, NifTaggedEnum};

use crate::atoms;

#[derive(NifStruct, Debug)]
#[module = "PdfElixide.Form.Field"]
pub struct FieldNif {
    name: String,
    kind: Atom,
    value: Option<FieldValueNif>,
}

// `PartialEq` is for the tests below, which compare the two decoding spellings
// against each other; nothing in the NIF path needs it.
#[derive(NifTaggedEnum, Debug, PartialEq)]
pub enum FieldValueNif {
    Text(String),
    Boolean(bool),
    Name(String),
    Array(Vec<String>),
}

pub fn document_form_field_to_nif(field: FormField) -> FieldNif {
    FieldNif {
        name: field.name,
        kind: field_type_to_atom(field.field_type),
        value: document_field_value_to_nif(field.value),
    }
}

pub fn editor_form_field_to_nif(wrapper: FormFieldWrapper) -> FieldNif {
    let kind = wrapper
        .field_type()
        .cloned()
        .map(field_type_to_atom)
        .unwrap_or_else(atoms::unknown);
    FieldNif {
        name: wrapper.name().to_string(),
        kind,
        value: editor_field_value_to_nif(wrapper.value()),
    }
}

fn field_type_to_atom(field_type: FieldType) -> Atom {
    match field_type {
        FieldType::Button => atoms::button(),
        FieldType::Text => atoms::text(),
        FieldType::Choice => atoms::choice(),
        FieldType::Signature => atoms::signature(),
        FieldType::Unknown(_) => atoms::unknown(),
    }
}

fn document_field_value_to_nif(value: FieldValue) -> Option<FieldValueNif> {
    match value {
        FieldValue::Text(s) => Some(FieldValueNif::Text(s)),
        FieldValue::Boolean(b) => Some(FieldValueNif::Boolean(b)),
        FieldValue::Name(s) => Some(FieldValueNif::Name(s)),
        FieldValue::Array(a) => Some(FieldValueNif::Array(a)),
        FieldValue::None => None,
    }
}

fn editor_field_value_to_nif(value: FormFieldValue) -> Option<FieldValueNif> {
    match value {
        FormFieldValue::Text(s) => Some(FieldValueNif::Text(s)),
        FormFieldValue::Boolean(b) => Some(FieldValueNif::Boolean(b)),
        FormFieldValue::Choice(s) => Some(FieldValueNif::Name(s)),
        FormFieldValue::MultiChoice(v) => Some(FieldValueNif::Array(v)),
        FormFieldValue::None => None,
    }
}

pub fn editor_field_value_from_nif(value: Option<FieldValueNif>) -> FormFieldValue {
    match value {
        Some(FieldValueNif::Text(s)) => FormFieldValue::Text(s),
        Some(FieldValueNif::Boolean(b)) => FormFieldValue::Boolean(b),
        Some(FieldValueNif::Name(s)) => FormFieldValue::Choice(s),
        Some(FieldValueNif::Array(v)) => FormFieldValue::MultiChoice(v),
        None => FormFieldValue::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every `FieldValue` variant, so the two tests below cannot quietly cover
    /// four of five. Spelled as a function rather than a const because the
    /// payloads are heap strings.
    fn every_field_value() -> Vec<FieldValue> {
        vec![
            FieldValue::Text(String::from("typed")),
            FieldValue::Boolean(true),
            FieldValue::Name(String::from("Off")),
            FieldValue::Array(vec![String::from("a"), String::from("b")]),
            FieldValue::None,
        ]
    }

    /// The binding decodes field values *twice* — once from the read-only
    /// extractor's `FieldValue` (`document_field_value_to_nif`) and once from
    /// the editor's `FormFieldValue` (`editor_field_value_to_nif`) — and the
    /// two must agree, because `PdfElixide.Form` presents one shape whichever
    /// handle it was given.
    ///
    /// They are not obviously the same mapping: the editor's spelling is
    /// asymmetric, sending `Choice` to `:name` and `MultiChoice` to `:array`.
    /// Composing through upstream's own `From<FieldValue> for FormFieldValue`,
    /// which the binding calls nowhere, pins both halves at once and catches
    /// what a round-trip cannot — a *consistent* swap on both sides.
    ///
    /// Unreachable from `mix test`: no fixture carries a choice field with a
    /// `/V`, so the `Name` and `Array` arms are produced nowhere in the Elixir
    /// suite.
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

    /// `editor_field_value_from_nif` is the inverse used by `Form.set_value/3`,
    /// so a value read off an editor field and written straight back must land
    /// unchanged. `FieldValue::None` folds to `nil` on the way out and back to
    /// `FormFieldValue::None` on the way in, which is the one asymmetric step.
    #[test]
    fn an_editor_value_survives_a_decode_and_encode_round_trip() {
        for value in every_field_value() {
            let editor_value = FormFieldValue::from(value.clone());
            let round_tripped =
                editor_field_value_from_nif(editor_field_value_to_nif(editor_value.clone()));

            assert_eq!(round_tripped, editor_value, "{value:?}");
        }
    }
}
