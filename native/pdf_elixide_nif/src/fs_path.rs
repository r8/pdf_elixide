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

// Compiled on every host so the UTF-8 decoder is tested outside Windows too.
#[cfg_attr(unix, allow(dead_code))]
fn decode_utf8_only(bytes: &[u8]) -> Option<PathBuf> {
    std::str::from_utf8(bytes).ok().map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

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
