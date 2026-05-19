use pdf_oxide::extractors::{
    forms::{FieldType, FieldValue},
    FormField,
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

pub fn form_field_to_nif(field: FormField) -> FieldNif {
    FieldNif {
        name: field.name,
        kind: field_type_to_atom(field.field_type),
        value: field_value_to_nif(field.value),
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

fn field_value_to_nif(value: FieldValue) -> Option<FieldValueNif> {
    match value {
        FieldValue::Text(s) => Some(FieldValueNif::Text(s)),
        FieldValue::Boolean(b) => Some(FieldValueNif::Boolean(b)),
        FieldValue::Name(s) => Some(FieldValueNif::Name(s)),
        FieldValue::Array(a) => Some(FieldValueNif::Array(a)),
        FieldValue::None => None,
    }
}
