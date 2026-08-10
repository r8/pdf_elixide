use pdf_oxide::{
    editor::form_fields::{FormFieldValue, FormFieldWrapper},
    extractors::{
        forms::{FieldType, FieldValue},
        FormField,
    },
};
use rustler::{NifStruct, NifUntaggedEnum};

/// A field's value as a plain term, in **both** directions: what `fields/1`
/// reports and what `PdfElixide.Form.set_value/3` sends. One type rather than a
/// read one and a write one, because their being identical is the contract —
/// a value read off a field must be writable straight back — and two copies
/// could only maintain that by hand.
///
/// Untagged: encodes as the bare boolean/binary/list, so Elixir sees
/// `"John Doe"` rather than `{:text, "John Doe"}`. Decoding tries variants in
/// declaration order, first success wins; the three take disjoint term types —
/// the atoms `true`/`false`, binaries, proper lists of binaries — so the order
/// is cosmetic, cheapest first.
///
/// `PartialEq` is for the tests below, which compare the two decoding spellings
/// against each other; nothing in the NIF path needs it.
#[derive(NifUntaggedEnum, Debug, PartialEq)]
pub enum FieldValueNif {
    Boolean(bool),
    Text(String),
    List(Vec<String>),
}

// The three below are identical but for their `#[module]`, and stay spelled out:
// rustler needs one type per target struct, so collapsing them means a
// `macro_rules!` that hides all three module names from a grep for them. Not
// worth twelve lines, and against the explicitness the rest of the binding keeps
// (`from_nif/1`'s spelled-out heads, `defstruct @enforce_keys`).
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

/// One AcroForm field. Untagged so each variant encodes as the bare struct —
/// Elixir sees `%PdfElixide.Form.Field.Text{}` and friends directly, with no
/// wrapping tuple. The `AnnotationColorNif` shape (see color.rs).
#[derive(NifUntaggedEnum, Debug)]
pub enum FieldNif {
    Text(TextFieldNif),
    Button(ButtonFieldNif),
    Choice(ChoiceFieldNif),
    Unknown(UnknownFieldNif),
}

/// Builds the right per-kind struct, or `None` for a field this API does not
/// report. `Option<&FieldType>` unifies the document path, which always has a
/// type, with the editor path, which may not.
///
/// A `/Sig` field is dropped: its `/V` is a signature dictionary rather than a
/// fillable value, so it is not a form field in the sense this module means, and
/// reading, verifying and producing signatures is a separate capability. Dropping
/// it *here* is also what makes `Form.field/2` and `Form.value/2` answer
/// `:not_found` for one, since both filter `fields/1`.
///
/// This is the *own*-`/FT` half only; both call sites additionally filter the
/// names `form_tree` resolves. Neither half covers the other, so don't delete
/// one for the other.
///
/// Neither makes a write safe — `ensure_not_signature` (`editor.rs`) is the
/// guard, and a filter on the read side is not a substitute for it.
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

    /// Every `FieldValue` variant, so the tests below cannot quietly cover four
    /// of five. Spelled as a function rather than a const because the payloads
    /// are heap strings.
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
    /// They are not obviously the same mapping: each collapses a *different*
    /// pair onto a bare string — `Text`/`Name` on the document side,
    /// `Text`/`Choice` on the editor side. Composing through upstream's own
    /// `From<FieldValue> for FormFieldValue`, which the binding calls nowhere,
    /// pins both halves at once and catches what a round-trip cannot — a
    /// *consistent* swap on both sides.
    ///
    /// The document-path `Name` arm is unreachable from `mix test`: no fixture
    /// carries a custom button on-state, so this is its only pin. (The `Array`
    /// arm *is* reachable, via the list write that saves and reopens in
    /// `form_test.exs`.)
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

    /// A value read off a field and written straight back must land as the same
    /// PDF object. Enum-level round-tripping no longer holds — the read mapping
    /// is not injective, so `Choice("x")` reads as `"x"` and writes back as
    /// `Text("x")` — and *serialization* identity is the contract that replaces
    /// it. It holds precisely because upstream sends `Text` and `Choice` to the
    /// same `Object::text_string` (`src/editor/form_fields.rs`), which is what
    /// this test would catch upstream changing.
    ///
    /// The read and the write share `FieldValueNif`, so the composition below is
    /// exactly what a caller piping `fields/1` into `set_value/3` performs, with
    /// nothing translating between them.
    #[test]
    fn a_read_value_written_back_lands_as_the_same_pdf_object() {
        for value in every_field_value() {
            let original = FormFieldValue::from(value.clone());
            let written = set_value_from_nif(document_field_value_to_nif(value.clone()));

            assert_eq!(Object::from(&written), Object::from(&original), "{value:?}");
        }
    }

    /// The only pin for the `raw_type` payload and for the editor path's `None`
    /// arm: no fixture carries a bogus `/FT`, and the binding creates no fields,
    /// so `field_type() == None` is unreachable from `mix test`. Written over
    /// every `FieldType` so a new upstream variant cannot be silently dropped —
    /// the signature arm is the one also reachable from Elixir, over
    /// `form_signature.pdf`.
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
