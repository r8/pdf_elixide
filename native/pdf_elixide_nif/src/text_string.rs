// PDF text strings (ISO 32000-1 §7.9.2.2): how this crate reads and writes them.

// The shared decoder handles UTF-16, UTF-8 and PDFDocEncoding. Strip PDF 2.0's
// UTF-8 BOM first because the decoder otherwise preserves it as U+FEFF.
pub(crate) fn decode_pdf_text_string(bytes: &[u8]) -> String {
    let body = match bytes {
        [0xEF, 0xBB, 0xBF, rest @ ..] => rest,
        other => other,
    };

    pdf_oxide::optional_content::decode_pdf_text_string(body)
}

// `DocumentInfo` writes string bytes verbatim, so non-ASCII needs a UTF-8 BOM.
pub(crate) fn encode_pdf_text_string(value: &str) -> String {
    if value.is_ascii() {
        value.to_string()
    } else {
        format!("\u{FEFF}{value}")
    }
}

#[cfg(test)]
mod tests {
    use super::{decode_pdf_text_string as decode, encode_pdf_text_string as encode};

    #[test]
    fn decodes_ascii_unchanged() {
        assert_eq!(decode(b"Test Title"), "Test Title");
        assert_eq!(decode(b""), "");
    }

    #[test]
    fn decodes_pdfdoc_encoding_not_latin1() {
        // 0x80-0x9F are PDFDocEncoding glyphs, not the C1 controls a Latin-1
        // decoder would produce: en dash, right single quote, trademark
        // (ISO 32000-1 Table D.2).
        assert_eq!(
            decode(b"PDFDoc: \x85 \x90 \x92"),
            "PDFDoc: \u{2013} \u{2019} \u{2122}"
        );
    }

    #[test]
    fn decodes_the_latin1_range_as_latin1() {
        assert_eq!(decode(b"caf\xE9, na\xEFve"), "café, naïve");
    }

    #[test]
    fn drops_codes_undefined_in_pdfdoc_encoding() {
        // Upstream's table `filter_map`s, so 0x9F — the one undefined code —
        // disappears rather than becoming U+FFFD.
        assert_eq!(decode(b"a\x9Fb"), "ab");
    }

    #[test]
    fn decodes_utf16be_with_a_bom() {
        assert_eq!(decode(b"\xFE\xFF\x00H\x00i"), "Hi");
        // Surrogate pairs survive: U+1F642.
        assert_eq!(decode(b"\xFE\xFF\xD8\x3D\xDE\x42"), "🙂");
    }

    #[test]
    fn decodes_utf16le_with_a_bom() {
        assert_eq!(decode(b"\xFF\xFEH\x00i\x00"), "Hi");
    }

    #[test]
    fn drops_a_trailing_odd_byte_in_utf16() {
        assert_eq!(decode(b"\xFE\xFF\x00H\x00"), "H");
    }

    #[test]
    fn falls_back_to_lossy_utf8_on_an_unpaired_surrogate() {
        // Record the shared decoder's lossy fallback for an unpaired surrogate.
        assert_eq!(
            decode(b"\xFE\xFF\xD8\x3D\x00A"),
            "\u{FFFD}\u{FFFD}\u{FFFD}=\u{0}A"
        );
    }

    #[test]
    fn strips_the_pdf_2_0_utf8_bom() {
        assert_eq!(decode(b"\xEF\xBB\xBFCaf\xC3\xA9"), "Café");
        // BOM only: empty, so `read_metadata`'s trim-to-`None` rule applies.
        assert_eq!(decode(b"\xEF\xBB\xBF"), "");
    }

    #[test]
    fn decodes_raw_utf8_without_a_bom() {
        assert_eq!(decode(b"Caf\xC3\xA9"), "Café");
    }

    #[test]
    fn encodes_ascii_unchanged() {
        assert_eq!(encode("Test Title"), "Test Title");
        assert_eq!(encode(""), "");
        assert_eq!(encode("D:20240115120000Z"), "D:20240115120000Z");
    }

    #[test]
    fn prefixes_non_ascii_with_the_utf8_bom() {
        let encoded = encode("Título");

        assert!(encoded.as_bytes().starts_with(b"\xEF\xBB\xBF"));
        assert_eq!(&encoded[3..], "Título");
    }

    #[test]
    fn round_trips_through_the_shared_decoder() {
        for value in ["Test Title", "Título", "Café ✓", "Título 🙂", "  padded  "] {
            assert_eq!(decode(encode(value).as_bytes()), value);
        }
    }
}
