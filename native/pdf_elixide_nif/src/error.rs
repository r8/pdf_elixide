use std::any::Any;

use pdf_oxide::Error as PdfError;
use rustler::{Atom, Error};

use crate::atoms;

/// Builds a Rustler `Error::Term` carrying a `{reason, message}` tuple.
///
/// The NIF returns this as `{:error, {reason, message}}`; the Elixir side
/// (`PdfElixide.Native.Wrap`) turns it into a `%PdfElixide.Error{}` struct so
/// callers can pattern-match on `reason`.
pub fn tagged_err(reason: Atom, message: impl Into<String>) -> Error {
    Error::Term(Box::new((reason, message.into())))
}

/// Converts a `pdf_oxide::Error` into a tagged Rustler error, mapping the
/// variant to one of the stable reason atoms (see [`classify`]).
pub fn to_nif_err(e: PdfError) -> Error {
    tagged_err(classify(&e), e.to_string())
}

/// Same as [`to_nif_err`], but names the page the failure came from.
///
/// Used by the whole-document text loop under `on_page_error: :halt`, where the
/// caller otherwise has no way to tell *which* page failed: the reason atom and
/// upstream's message are the same whichever page produced them. The atom is
/// left to [`classify`] so a halted page reports exactly what the equivalent
/// per-page call would.
pub fn to_nif_page_err(page_index: usize, e: PdfError) -> Error {
    tagged_err(classify(&e), format!("page {page_index}: {e}"))
}

/// Creates a standard "Lock is poisoned" error for poisoned locks.
///
/// Defensive: every guard is now taken through `Closable::with_lock` /
/// `with_read`, which contain a panic before it can poison anything (see
/// `crate::resource::contain_panic`), so this should no longer be reachable.
pub fn lock_err() -> Error {
    tagged_err(atoms::lock_poisoned(), "Lock is poisoned")
}

/// Creates the error reported when a panic is caught inside a resource guard,
/// carrying the panic message when it is a string (which it is for `panic!` and
/// `expect`/`unwrap`).
pub fn panic_err(payload: &(dyn Any + Send)) -> Error {
    tagged_err(
        atoms::panic(),
        format!("native panic: {}", panic_message(payload)),
    )
}

/// Extracts the message from a caught panic payload. `panic!` and the
/// `expect`/`unwrap` family box either a `&str` or a `String`; anything else
/// (a custom payload from `panic_any`) has no message to report.
fn panic_message(payload: &(dyn Any + Send)) -> &str {
    if let Some(message) = payload.downcast_ref::<&str>() {
        message
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message
    } else {
        "unknown payload"
    }
}

/// Creates the error reported for a handle that was released with `close`
/// (see `crate::resource::Closable`). `label` names the handle, e.g. `"Document"`.
pub fn closed_err(label: &str) -> Error {
    tagged_err(atoms::closed(), format!("{label} is closed"))
}

/// Maps a `pdf_oxide::Error` variant to a stable reason atom. Anything not
/// explicitly mapped (including feature-gated variants) falls through to
/// `:other`, with the original message preserved by the caller.
///
/// **`:wrong_password` is a deliberate gap here.** Upstream has no such
/// variant: `PdfDocument::authenticate` reports a rejected password as
/// `Ok(false)`, and `EncryptedPdf` — the only password-adjacent variant — means
/// "not authenticated yet", not "wrong password". The atom is therefore
/// *synthesized* by `OpenOptionsNif::apply` (`crate::document`) from that
/// `false`, and nothing routed through `classify` can produce it.
///
/// If upstream ever does grow a wrong-password variant, it lands on the `_`
/// arm below and `open(password:)` starts reporting `%Error{reason: :other}`,
/// silently breaking every caller matching `:wrong_password`. The canary in
/// `test/pdf_elixide/upstream_drift_test.exs` is what catches that; the fix
/// then is an explicit arm here, not a relaxed assertion there.
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
        // Also where a future upstream wrong-password variant would land —
        // see the deliberate gap described above.
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
