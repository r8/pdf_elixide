use rustler::Error;

/// Converts any `Display` value into a Rustler `Error::Term`.
pub fn to_nif_err(e: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(e.to_string()))
}

/// Creates a standard "Lock is poisoned" error for poisoned mutexes.
pub fn lock_err() -> Error {
    Error::Term(Box::new("Lock is poisoned".to_string()))
}
