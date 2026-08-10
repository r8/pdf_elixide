use rustler::{Encoder, Env, NifResult, OwnedBinary, Term};

use crate::{atoms, error::tagged_err};

// Preserve allocation failure in the tagged error contract; never replace this
// with an `expect` that Rustler would expose as opaque `:nif_panicked`.
pub fn owned_binary(bytes: &[u8], label: &str) -> NifResult<OwnedBinary> {
    let mut bin = OwnedBinary::new(bytes.len())
        .ok_or_else(|| tagged_err(atoms::other(), format!("failed to allocate {label} binary")))?;
    bin.as_mut_slice().copy_from_slice(bytes);

    Ok(bin)
}

// Same as [`owned_binary`], released into a term for a NIF that builds its own
// return value. A bare `Vec<u8>`/`&[u8]` would encode as a list of integers, so
// everything binary-shaped goes through here.
pub fn binary_term<'a>(env: Env<'a>, bytes: &[u8], label: &str) -> NifResult<Term<'a>> {
    Ok(owned_binary(bytes, label)?.release(env).encode(env))
}
