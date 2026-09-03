use std::any::Any;

use pdf_oxide::Error as PdfError;
use rustler::{Atom, Error};

use crate::atoms;

// The NIF returns this as `{:error, {reason, message}}`; the Elixir side
// (`PdfElixide.Native.Wrap`) turns it into a `%PdfElixide.Error{}` struct so
// callers can pattern-match on `reason`.
pub fn tagged_err(reason: Atom, message: impl Into<String>) -> Error {
    Error::Term(Box::new((reason, message.into())))
}

// Converts a `pdf_oxide::Error` into a tagged Rustler error, mapping the
// variant to one of the stable reason atoms (see [`classify`]).
pub fn to_nif_err(e: PdfError) -> Error {
    tagged_err(classify(&e), e.to_string())
}

// Preserve the per-page reason atom while adding the page index to its message.
pub fn to_nif_page_err(page_index: usize, e: PdfError) -> Error {
    tagged_err(classify(&e), format!("page {page_index}: {e}"))
}

// The prefix `TextSearcher::build_regex` puts on a rejected pattern.
const INVALID_PATTERN_PREFIX: &str = "Invalid regex pattern: ";

// Same as [`to_nif_err`], but reports a rejected search pattern as
// `:invalid_pattern`. Upstream raises it as an `InvalidPdf` like any other, so
// the message is the only thing separating the two; a reworded one degrades to
// `:invalid_pdf`.
pub fn to_search_err(e: PdfError) -> Error {
    match &e {
        PdfError::InvalidPdf(message) if message.starts_with(INVALID_PATTERN_PREFIX) => {
            tagged_err(atoms::invalid_pattern(), e.to_string())
        }
        _ => to_nif_err(e),
    }
}

// The prefix `set_form_field_value` puts on an unknown field name.
const FIELD_NOT_FOUND_PREFIX: &str = "Form field not found: ";

// Same as [`to_nif_err`], but reports an unknown form field name as
// `:not_found`, which is what `PdfElixide.Form.field/2` answers for the same
// condition. Told apart by message prefix, with the same trade-off as
// [`to_search_err`] above.
pub fn to_form_err(e: PdfError) -> Error {
    match &e {
        PdfError::InvalidPdf(message) if message.starts_with(FIELD_NOT_FOUND_PREFIX) => {
            tagged_err(atoms::not_found(), e.to_string())
        }
        _ => to_nif_err(e),
    }
}

// `Closable::with_lock` and `with_read` contain panics before they can poison a
// guard, so this is only a defensive fallback.
pub fn lock_err() -> Error {
    tagged_err(atoms::lock_poisoned(), "Lock is poisoned")
}

// Carries the panic message when it is a string, which it is for `panic!` and
// `expect`/`unwrap`.
pub fn panic_err(payload: &(dyn Any + Send)) -> Error {
    tagged_err(
        atoms::panic(),
        format!("native panic: {}", panic_message(payload)),
    )
}

// Extracts the message from a caught panic payload. `panic!` and the
// `expect`/`unwrap` family box either a `&str` or a `String`; anything else
// (a custom payload from `panic_any`) has no message to report.
fn panic_message(payload: &(dyn Any + Send)) -> &str {
    if let Some(message) = payload.downcast_ref::<&str>() {
        message
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message
    } else {
        "unknown payload"
    }
}

// `label` names the handle, e.g. `"Document"`; see `crate::resource::Closable`.
pub fn closed_err(label: &str) -> Error {
    tagged_err(atoms::closed(), format!("{label} is closed"))
}

// `:wrong_password` is synthesized while applying open options because a
// rejected password is `Ok(false)`, not a `pdf_oxide::Error` variant.
fn classify(e: &PdfError) -> Atom {
    match e {
        PdfError::EncryptedPdf => atoms::encrypted(),
        PdfError::InvalidHeader(_)
        | PdfError::InvalidPdf(_)
        | PdfError::ParseError { .. }
        | PdfError::ParseWarning { .. }
        | PdfError::InvalidXref
        | PdfError::UnexpectedEof
        | PdfError::InvalidObjectType { .. } => atoms::invalid_pdf(),
        PdfError::UnsupportedVersion(_)
        | PdfError::Unsupported(_)
        | PdfError::UnsupportedFilter(_) => atoms::unsupported(),
        PdfError::ObjectNotFound(_, _) => atoms::not_found(),
        PdfError::Io(_) => atoms::io(),
        _ => atoms::other(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Only `panic_message` is unit-testable here: everything that builds a
    // tagged error needs a live BEAM to make its atom.
    #[test]
    fn reports_the_message_of_a_string_payload() {
        let literal: Box<dyn Any + Send> = Box::new("boom");
        let owned: Box<dyn Any + Send> = Box::new(String::from("boom, formatted"));

        assert_eq!(panic_message(&*literal), "boom");
        assert_eq!(panic_message(&*owned), "boom, formatted");
    }

    #[test]
    fn falls_back_for_a_payload_that_is_not_a_string() {
        let payload: Box<dyn Any + Send> = Box::new(42_u8);

        assert_eq!(panic_message(&*payload), "unknown payload");
    }
}
