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

/// Creates a standard "Lock is poisoned" error for poisoned locks.
pub fn lock_err() -> Error {
    tagged_err(atoms::lock_poisoned(), "Lock is poisoned")
}

/// Creates the error reported for a handle that was released with `close`
/// (see `crate::resource::Closable`). `label` names the handle, e.g. `"Document"`.
pub fn closed_err(label: &str) -> Error {
    tagged_err(atoms::closed(), format!("{label} is closed"))
}

/// Maps a `pdf_oxide::Error` variant to a stable reason atom. Anything not
/// explicitly mapped (including feature-gated variants) falls through to
/// `:other`, with the original message preserved by the caller.
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
