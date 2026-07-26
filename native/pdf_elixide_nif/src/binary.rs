use rustler::{Encoder, Env, NifResult, OwnedBinary, Term};

use crate::{atoms, error::tagged_err};

/// Copies a byte slice into a freshly allocated Erlang binary. `label` names the
/// payload in the error message, e.g. `"font"`.
///
/// `OwnedBinary::new` returns `None` when the allocation fails, which must never
/// become an `expect`: Rustler catches a NIF panic and re-raises it as an opaque
/// `:nif_panicked`, bypassing the `{reason, message}` contract that
/// `PdfElixide.Native.Wrap` turns into a `%PdfElixide.Error{}`.
pub fn owned_binary(bytes: &[u8], label: &str) -> NifResult<OwnedBinary> {
    let mut bin = OwnedBinary::new(bytes.len())
        .ok_or_else(|| tagged_err(atoms::other(), format!("failed to allocate {label} binary")))?;
    bin.as_mut_slice().copy_from_slice(bytes);

    Ok(bin)
}

/// Same as [`owned_binary`], released into a term for a NIF that builds its own
/// return value. A bare `Vec<u8>`/`&[u8]` would encode as a list of integers, so
/// everything binary-shaped goes through here.
pub fn binary_term<'a>(env: Env<'a>, bytes: &[u8], label: &str) -> NifResult<Term<'a>> {
    Ok(owned_binary(bytes, label)?.release(env).encode(env))
}
