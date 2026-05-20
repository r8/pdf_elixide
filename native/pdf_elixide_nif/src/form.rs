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

#[derive(NifTaggedEnum, Debug)]
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
