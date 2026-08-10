// Decoding of filesystem path arguments. Named `fs_path` and not `path`
// because `paths.rs` beside it is vector *graphics* path extraction.

use std::path::PathBuf;

use rustler::{Binary, NifResult};

// `BadArg` keeps an undecodable path an `ArgumentError`, not a PDF error.
pub fn path_arg(path: Binary) -> NifResult<PathBuf> {
    decode(path.as_slice()).ok_or(rustler::Error::BadArg)
}

#[cfg(unix)]
fn decode(bytes: &[u8]) -> Option<PathBuf> {
    use std::{ffi::OsStr, os::unix::ffi::OsStrExt};

    Some(OsStr::from_bytes(bytes).into())
}

#[cfg(not(unix))]
fn decode(bytes: &[u8]) -> Option<PathBuf> {
    decode_utf8_only(bytes)
}

// The branch Windows takes, which has no choice: `OsStringExt::from_wide`
// consumes `u16`, so there is no bytes-to-path mapping to use.
//
// Compiled unconditionally rather than behind `#[cfg(windows)]` so the unit
// test below reaches it on every host, not only the Windows CI leg.
#[cfg_attr(unix, allow(dead_code))]
fn decode_utf8_only(bytes: &[u8]) -> Option<PathBuf> {
    std::str::from_utf8(bytes).ok().map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Both branches run on every host here, which no other gate manages: the
    // Elixir contract test can only ever assert the one its own platform takes.

    #[test]
    fn utf8_only_rejects_bytes_with_no_utf8_spelling() {
        assert_eq!(decode_utf8_only(&[0xFF]), None);
        assert_eq!(decode_utf8_only(b"caf\xE9.pdf"), None);
    }

    #[test]
    fn utf8_only_accepts_non_ascii_utf8() {
        assert_eq!(
            decode_utf8_only("café.pdf".as_bytes()),
            Some(PathBuf::from("café.pdf"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn unix_decode_keeps_bytes_utf8_would_reject() {
        use std::os::unix::ffi::OsStrExt;

        let bytes = b"caf\xE9.pdf";

        assert_eq!(decode(bytes).unwrap().as_os_str().as_bytes(), bytes);
    }
}
