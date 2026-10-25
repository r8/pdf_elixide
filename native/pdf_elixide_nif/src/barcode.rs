use barcoders::sym::{code128::Code128, code39::Code39, ean13::EAN13, ean8::EAN8, tf::TF};
use qrcode::{
    bits::Bits,
    types::{QrError, QrResult, Version},
    EcLevel, QrCode,
};
use rustler::{Binary, Encoder, Env, NifMap, NifResult, NifUnitEnum, Term};

use crate::{atoms, binary::owned_binary, error::contain_panic};

#[derive(NifUnitEnum, Clone, Copy)]
pub enum SymbologyNif {
    Code128,
    Code39,
    Code93,
    Ean13,
    Ean8,
    UpcA,
    Itf,
    Codabar,
    Qr,
}

#[derive(NifUnitEnum, Clone, Copy)]
pub enum ErrorCorrectionNif {
    Low,
    Medium,
    Quartile,
    High,
}

#[derive(NifMap)]
struct SymbolNif<'a> {
    columns: usize,
    rows: usize,
    modules: Binary<'a>,
    text: String,
}

#[derive(Debug, PartialEq)]
struct Symbol {
    columns: usize,
    rows: usize,
    // One byte per module, row by row, 1 for dark; no quiet zone.
    modules: Vec<u8>,
    text: String,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn builder_encode_barcode<'a>(
    env: Env<'a>,
    symbology: SymbologyNif,
    data: String,
    error_correction: ErrorCorrectionNif,
) -> NifResult<Term<'a>> {
    contain_panic(|| match encode(symbology, &data, error_correction) {
        Ok(symbol) => Ok(SymbolNif {
            columns: symbol.columns,
            rows: symbol.rows,
            modules: Binary::from_owned(owned_binary(&symbol.modules, "barcode")?, env),
            text: symbol.text,
        }
        .encode(env)),
        Err(message) => Ok((atoms::invalid(), message).encode(env)),
    })
}

fn name(symbology: SymbologyNif) -> &'static str {
    match symbology {
        SymbologyNif::Code128 => "Code 128",
        SymbologyNif::Code39 => "Code 39",
        SymbologyNif::Code93 => "Code 93",
        SymbologyNif::Ean13 => "EAN-13",
        SymbologyNif::Ean8 => "EAN-8",
        SymbologyNif::UpcA => "UPC-A",
        SymbologyNif::Itf => "ITF",
        SymbologyNif::Codabar => "Codabar",
        SymbologyNif::Qr => "a QR code",
    }
}

// Bound variable-length input to keep encoder checksum arithmetic within range.
const MAX_LINEAR_LENGTH: usize = 256;

// Code 93 shift characters require pairs; only checksums may use them alone.
const CODE39_PUNCTUATION: &str = "-. $/+%";
const CODE93_CHARS: &str = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%";
const CODE93_PATTERNS: [u16; 47] = [
    0b100010100,
    0b101001000,
    0b101000100,
    0b101000010,
    0b100101000,
    0b100100100,
    0b100100010,
    0b101010000,
    0b100010010,
    0b100001010,
    0b110101000,
    0b110100100,
    0b110100010,
    0b110010100,
    0b110010010,
    0b110001010,
    0b101101000,
    0b101100100,
    0b101100010,
    0b100110100,
    0b100011010,
    0b101011000,
    0b101001100,
    0b101000110,
    0b100101100,
    0b100010110,
    0b110110100,
    0b110110010,
    0b110101100,
    0b110100110,
    0b110010110,
    0b110011010,
    0b101101100,
    0b101100110,
    0b100110110,
    0b100111010,
    0b100101110,
    0b111010100,
    0b111010010,
    0b111001010,
    0b101101110,
    0b101110110,
    0b110101110,
    0b100100110,
    0b111011010,
    0b111010110,
    0b100110010,
];
const CODE93_GUARD: u16 = 0b101011110;
const CODABAR_DATA: &str = "-$:/.+";
const CODABAR_GUARDS: &str = "ABCD";
const CODABAR_CHARS: &str = "0123456789-$:/.+ABCD";
// Seven elements per character, bar first, as bits from the most significant;
// 1 is wide.
const CODABAR_WIDTHS: [u8; 20] = [
    0x03, 0x06, 0x09, 0x60, 0x12, 0x42, 0x21, 0x24, 0x30, 0x48, 0x0c, 0x18, 0x45, 0x51, 0x54, 0x15,
    0x1a, 0x29, 0x0b, 0x0e,
];
// ECI 26 declares byte-mode data as UTF-8; without one a reader may assume ISO-8859-1.
const UTF8_ECI: u32 = 26;

fn encode(
    symbology: SymbologyNif,
    data: &str,
    error_correction: ErrorCorrectionNif,
) -> Result<Symbol, String> {
    let name = name(symbology);
    if data.is_empty() {
        return Err(format!("{name} cannot encode an empty string"));
    }

    let linear = |modules: Vec<u8>, text: String| Symbol {
        columns: modules.len(),
        rows: 1,
        modules,
        text,
    };
    let unexpected = |error: barcoders::error::Error| format!("{name} cannot encode it: {error}");

    match symbology {
        SymbologyNif::Code128 => {
            if !data.chars().all(|c| (' '..='~').contains(&c)) {
                return Err(format!("{name} takes printable ASCII characters"));
            }
            if data.len() > MAX_LINEAR_LENGTH {
                return Err(format!(
                    "{name} takes at most {MAX_LINEAR_LENGTH} characters"
                ));
            }
            Code128::new(code128_input(data))
                .map(|code| linear(code.encode(), data.to_string()))
                .map_err(unexpected)
        }
        SymbologyNif::Code39 | SymbologyNif::Code93 => {
            if data.len() > MAX_LINEAR_LENGTH {
                return Err(format!(
                    "{name} takes at most {MAX_LINEAR_LENGTH} characters"
                ));
            }
            if !data.chars().all(|c| {
                c.is_ascii_digit() || c.is_ascii_uppercase() || CODE39_PUNCTUATION.contains(c)
            }) {
                return Err(format!(
                    "{name} takes digits, capital letters, spaces and - . $ / + %"
                ));
            }
            if matches!(symbology, SymbologyNif::Code93) {
                return Ok(linear(code93_modules(data), data.to_string()));
            }
            Code39::new(data)
                .map(|code| linear(code.encode(), data.to_string()))
                .map_err(unexpected)
        }
        SymbologyNif::Ean13 => {
            let digits = gs1_digits(name, data, 12)?;
            EAN13::new(&digits)
                .map(|code| linear(code.encode(), digits))
                .map_err(unexpected)
        }
        SymbologyNif::Ean8 => {
            let digits = gs1_digits(name, data, 7)?;
            EAN8::new(&digits)
                .map(|code| linear(code.encode(), digits))
                .map_err(unexpected)
        }
        // A UPC-A symbol is the EAN-13 symbol of the same number with a leading 0.
        SymbologyNif::UpcA => {
            let digits = gs1_digits(name, data, 11)?;
            EAN13::new(format!("0{digits}"))
                .map(|code| linear(code.encode(), digits))
                .map_err(unexpected)
        }
        SymbologyNif::Itf => {
            if !data.chars().all(|c| c.is_ascii_digit()) {
                return Err(format!("{name} takes digits"));
            }
            if !data.len().is_multiple_of(2) {
                return Err(format!("{name} takes an even number of digits"));
            }
            if data.len() > MAX_LINEAR_LENGTH {
                return Err(format!("{name} takes at most {MAX_LINEAR_LENGTH} digits"));
            }
            TF::interleaved(data)
                .map(|code| linear(code.encode(), data.to_string()))
                .map_err(unexpected)
        }
        SymbologyNif::Codabar => {
            let chars: Vec<char> = data.chars().collect();
            let guarded = chars.len() >= 2
                && CODABAR_GUARDS.contains(chars[0])
                && CODABAR_GUARDS.contains(chars[chars.len() - 1]);
            if !guarded {
                return Err(format!(
                    "{name} begins and ends with a start or stop character A, B, C or D"
                ));
            }
            if !chars[1..chars.len() - 1]
                .iter()
                .all(|&c| c.is_ascii_digit() || CODABAR_DATA.contains(c))
            {
                return Err(format!(
                    "{name} takes digits and - $ : / . + between its start and stop characters"
                ));
            }
            if data.len() > MAX_LINEAR_LENGTH {
                return Err(format!(
                    "{name} takes at most {MAX_LINEAR_LENGTH} characters"
                ));
            }
            Ok(linear(codabar_modules(data), data.to_string()))
        }
        SymbologyNif::Qr => qr_code(data, error_correction),
    }
}

// Index by value so checksum characters 45 and 46 keep distinct patterns.
fn code93_modules(data: &str) -> Vec<u8> {
    let mut values: Vec<usize> = data
        .chars()
        .map(|c| CODE93_CHARS.find(c).expect("checked by the caller"))
        .collect();
    for weights in [20, 15] {
        let check = values
            .iter()
            .rev()
            .enumerate()
            .map(|(i, value)| value * (i % weights + 1))
            .sum::<usize>()
            % CODE93_PATTERNS.len();
        values.push(check);
    }

    let patterns = std::iter::once(CODE93_GUARD)
        .chain(values.iter().map(|&value| CODE93_PATTERNS[value]))
        .chain(std::iter::once(CODE93_GUARD));
    let mut modules: Vec<u8> = patterns
        .flat_map(|pattern| (0..9).rev().map(move |bit| ((pattern >> bit) & 1) as u8))
        .collect();
    // The terminating bar after the stop character.
    modules.push(1);
    modules
}

// Wide elements are two modules, narrow ones one, with a narrow inter-character space.
fn codabar_modules(data: &str) -> Vec<u8> {
    let mut modules = Vec::new();
    for (index, c) in data.chars().enumerate() {
        if index > 0 {
            modules.push(0);
        }
        let widths = CODABAR_WIDTHS[CODABAR_CHARS.find(c).expect("checked by the caller")];
        for element in 0..7 {
            let module = u8::from(element % 2 == 0);
            let wide = (widths >> (6 - element)) & 1 == 1;
            modules.extend(std::iter::repeat_n(module, if wide { 2 } else { 1 }));
        }
    }
    modules
}

// Set C packs two digits per symbol character, so an even run of digits uses it.
fn code128_input(data: &str) -> String {
    if data.len().is_multiple_of(2) && data.chars().all(|c| c.is_ascii_digit()) {
        format!("\u{0106}{data}")
    } else {
        format!("\u{0181}{data}")
    }
}

// Verify a supplied check digit before constructing the caption.
fn gs1_digits(name: &str, data: &str, length: usize) -> Result<String, String> {
    if !data.chars().all(|c| c.is_ascii_digit()) || ![length, length + 1].contains(&data.len()) {
        return Err(format!(
            "{name} takes {length} digits, or {} with the check digit",
            length + 1
        ));
    }
    let digits: Vec<u8> = data.bytes().map(|b| b - b'0').collect();
    let check = check_digit(&digits[..length]);
    match digits.get(length) {
        Some(&given) if given != check => Err(format!("{name}'s check digit should be {check}")),
        _ => Ok(format!("{}{check}", &data[..length])),
    }
}

// The GS1 mod-10 check digit: weights 3 and 1 alternating from the rightmost digit.
fn check_digit(digits: &[u8]) -> u8 {
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, &d)| u32::from(d) * if i % 2 == 0 { 3 } else { 1 })
        .sum();
    ((10 - sum % 10) % 10) as u8
}

fn qr_code(data: &str, error_correction: ErrorCorrectionNif) -> Result<Symbol, String> {
    let level = match error_correction {
        ErrorCorrectionNif::Low => EcLevel::L,
        ErrorCorrectionNif::Medium => EcLevel::M,
        ErrorCorrectionNif::Quartile => EcLevel::Q,
        ErrorCorrectionNif::High => EcLevel::H,
    };
    // Non-ASCII must stay in one UTF-8 byte segment after its ECI.
    let code = if data.is_ascii() {
        QrCode::with_error_correction_level(data, level)
    } else {
        utf8_qr_bits(data, level).and_then(|bits| QrCode::with_bits(bits, level))
    };
    let code = code.map_err(|error| match error {
        QrError::DataTooLong => format!(
            "{} bytes are too many for a QR code at error correction :{}",
            data.len(),
            level_name(error_correction)
        ),
        other => format!("a QR code cannot encode it: {other}"),
    })?;
    let width = code.width();
    let modules = code
        .to_colors()
        .into_iter()
        .map(|color| u8::from(color == qrcode::Color::Dark))
        .collect();

    Ok(Symbol {
        columns: width,
        rows: width,
        modules,
        text: data.to_string(),
    })
}

fn utf8_qr_bits(data: &str, level: EcLevel) -> QrResult<Bits> {
    for version in 1..=40 {
        let mut bits = Bits::new(Version::Normal(version));
        let pushed = bits
            .push_eci_designator(UTF8_ECI)
            .and_then(|()| bits.push_byte_data(data.as_bytes()))
            .and_then(|()| bits.push_terminator(level));
        match pushed {
            Ok(()) => return Ok(bits),
            Err(QrError::DataTooLong) => continue,
            Err(other) => return Err(other),
        }
    }
    Err(QrError::DataTooLong)
}

fn level_name(error_correction: ErrorCorrectionNif) -> &'static str {
    match error_correction {
        ErrorCorrectionNif::Low => "low",
        ErrorCorrectionNif::Medium => "medium",
        ErrorCorrectionNif::Quartile => "quartile",
        ErrorCorrectionNif::High => "high",
    }
}

// Each row's dark modules as maximal horizontal runs: (column, row, length).
pub fn dark_runs(columns: usize, modules: &[u8]) -> Vec<(usize, usize, usize)> {
    let mut runs = Vec::new();
    if columns == 0 {
        return runs;
    }
    for (row, cells) in modules.chunks(columns).enumerate() {
        let mut start = None;
        for (column, &cell) in cells.iter().chain(std::iter::once(&0)).enumerate() {
            match (cell != 0, start) {
                (true, None) => start = Some(column),
                (false, Some(from)) => {
                    runs.push((from, row, column - from));
                    start = None;
                }
                _ => {}
            }
        }
    }
    runs
}

#[cfg(test)]
mod tests {
    use barcoders::sym::{codabar::Codabar, code93::Code93};
    use qrcode::{optimize::Parser, types::Mode};

    use super::*;

    fn modules(symbology: SymbologyNif, data: &str) -> Symbol {
        encode(symbology, data, ErrorCorrectionNif::Medium).unwrap()
    }

    fn refusal(symbology: SymbologyNif, data: &str) -> String {
        encode(symbology, data, ErrorCorrectionNif::Medium).unwrap_err()
    }

    #[test]
    fn check_digits_match_published_numbers() {
        assert_eq!(check_digit(&[5, 9, 0, 1, 2, 3, 4, 1, 2, 3, 4, 5]), 7);
        assert_eq!(check_digit(&[4, 0, 0, 6, 3, 8, 1, 3, 3, 3, 9, 3]), 1);
        assert_eq!(check_digit(&[9, 6, 3, 8, 5, 0, 7]), 4);
        assert_eq!(check_digit(&[0, 3, 6, 0, 0, 0, 2, 9, 1, 4, 5]), 2);
    }

    #[test]
    fn a_left_off_check_digit_is_computed_and_a_given_one_verified() {
        assert_eq!(
            modules(SymbologyNif::Ean13, "590123412345").text,
            "5901234123457"
        );
        assert_eq!(
            modules(SymbologyNif::Ean13, "590123412345"),
            modules(SymbologyNif::Ean13, "5901234123457")
        );
        assert_eq!(
            refusal(SymbologyNif::Ean13, "5901234123450"),
            "EAN-13's check digit should be 7"
        );
        assert_eq!(
            refusal(SymbologyNif::UpcA, "036000291450"),
            "UPC-A's check digit should be 2"
        );
        assert_eq!(
            modules(SymbologyNif::UpcA, "03600029145").text,
            "036000291452"
        );
    }

    #[test]
    fn upc_a_is_the_ean_13_symbol_with_a_leading_zero() {
        assert_eq!(
            modules(SymbologyNif::UpcA, "036000291452").modules,
            modules(SymbologyNif::Ean13, "0036000291452").modules
        );
    }

    #[test]
    fn ean_symbols_have_their_fixed_module_counts() {
        assert_eq!(modules(SymbologyNif::Ean13, "5901234123457").columns, 95);
        assert_eq!(modules(SymbologyNif::Ean8, "96385074").columns, 67);
    }

    #[test]
    fn code_128_picks_set_c_for_an_even_run_of_digits() {
        assert!(code128_input("1234").starts_with('\u{0106}'));
        assert!(code128_input("123").starts_with('\u{0181}'));
        assert!(code128_input("AB12").starts_with('\u{0181}'));
        assert!(
            modules(SymbologyNif::Code128, "123456").columns
                < modules(SymbologyNif::Code128, "12345A").columns
        );
    }

    #[test]
    fn code_128_refuses_the_encoders_set_switching_characters() {
        assert_eq!(
            refusal(SymbologyNif::Code128, "ab\u{00C0}cd"),
            "Code 128 takes printable ASCII characters"
        );
        assert_eq!(modules(SymbologyNif::Code128, "a").text, "a");
    }

    #[test]
    fn code_93_refuses_its_shift_characters() {
        assert!(refusal(SymbologyNif::Code93, "A(B").starts_with("Code 93 takes"));
        assert!(refusal(SymbologyNif::Code39, "abc").starts_with("Code 39 takes"));
        modules(SymbologyNif::Code93, "TEST-93 $/+%");
    }

    fn bits(patterns: &[&str]) -> Vec<u8> {
        patterns.concat().bytes().map(|bit| bit - b'0').collect()
    }

    #[test]
    fn code_93_draws_a_check_character_of_46_as_its_own_pattern() {
        let (guard, v, plus_shift) = ("101011110", "110011010", "100110010");
        // "V" is 31: C = 31, K = (2 × 31 + 31) mod 47 = 46.
        assert_eq!(
            modules(SymbologyNif::Code93, "V").modules,
            bits(&[guard, v, v, plus_shift, guard, "1"])
        );
        // "N0" is 23, 0: C = 2 × 23 = 46.
        let n0 = modules(SymbologyNif::Code93, "N0").modules;
        assert_eq!(&n0[27..36], bits(&[plus_shift]).as_slice());
    }

    fn code93_checks(data: &str) -> [usize; 2] {
        let mut values: Vec<usize> = data
            .chars()
            .map(|c| CODE93_CHARS.find(c).unwrap())
            .collect();
        let mut checks = [0; 2];
        for (slot, weights) in [20, 15].into_iter().enumerate() {
            let check = values
                .iter()
                .rev()
                .enumerate()
                .map(|(i, value)| value * (i % weights + 1))
                .sum::<usize>()
                % 47;
            checks[slot] = check;
            values.push(check);
        }
        checks
    }

    #[test]
    fn code_93_matches_barcoders_wherever_no_check_character_is_46() {
        let mut compared = 0;
        for c in CODE93_CHARS.chars() {
            for data in [c.to_string(), format!("{c}{c}A"), format!("TEST-{c}93")] {
                if code93_checks(&data).contains(&46) {
                    continue;
                }
                assert_eq!(
                    code93_modules(&data),
                    Code93::new(&data).unwrap().encode(),
                    "{data:?}"
                );
                compared += 1;
            }
        }
        assert!(compared > 100);
    }

    #[test]
    fn barcoders_still_encodes_a_code_93_check_character_of_46_as_45() {
        assert_eq!(code93_checks("V"), [31, 46]);
        assert_ne!(Code93::new("V").unwrap().encode(), code93_modules("V"));
    }

    #[test]
    fn code_128_takes_at_most_256_characters() {
        assert_eq!(
            modules(SymbologyNif::Code128, &"~".repeat(256)).text.len(),
            256
        );
        assert_eq!(
            refusal(SymbologyNif::Code128, &"~".repeat(257)),
            "Code 128 takes at most 256 characters"
        );
    }

    #[test]
    fn itf_refuses_an_odd_count_rather_than_appending_a_digit() {
        assert_eq!(
            refusal(SymbologyNif::Itf, "123"),
            "ITF takes an even number of digits"
        );
        assert_eq!(modules(SymbologyNif::Itf, "1234").text, "1234");
    }

    #[test]
    fn codabar_draws_plus_b_and_c_by_their_published_widths() {
        let (a, plus, b, c) = ("1011001001", "1011011011", "1001001011", "1010010011");
        assert_eq!(codabar_modules("+"), bits(&[plus]));
        assert_eq!(codabar_modules("B"), bits(&[b]));
        assert_eq!(codabar_modules("C"), bits(&[c]));

        let (one, two, three, four) = ("101011001", "101001011", "110010101", "101101001");
        assert_eq!(
            modules(SymbologyNif::Codabar, "A12+34B").modules,
            bits(&[a, "0", one, "0", two, "0", plus, "0", three, "0", four, "0", b])
        );
    }

    #[test]
    fn barcoders_still_draws_codabar_plus_b_and_c_wrongly() {
        for c in CODABAR_CHARS.chars() {
            let theirs = Codabar::new(c.to_string()).unwrap().encode();
            assert_eq!(
                codabar_modules(&c.to_string()) == theirs,
                !"+BC".contains(c),
                "{c:?}"
            );
        }
    }

    #[test]
    fn non_ascii_qr_data_is_one_utf8_byte_segment_after_an_eci() {
        // ECI 0111, designator 26, byte mode 0100, count 4, then the bytes.
        let bytes = utf8_qr_bits("АА", EcLevel::M).unwrap().into_bytes();
        assert_eq!(bytes[..7], [0x71, 0xA4, 0x04, 0xD0, 0x90, 0xD0, 0x90]);

        let symbol = modules(SymbologyNif::Qr, &"А".repeat(12));
        assert_eq!(symbol.columns, 25);
    }

    #[test]
    fn qrcode_still_reads_utf8_as_kanji() {
        let data = "А".repeat(12);
        assert!(Parser::new(data.as_bytes()).any(|segment| segment.mode == Mode::Kanji));
        assert!(!Parser::new(b"HELLO 123").any(|segment| segment.mode == Mode::Kanji));
    }

    #[test]
    fn codabar_needs_its_start_and_stop_characters() {
        assert!(refusal(SymbologyNif::Codabar, "1234").contains("start or stop"));
        assert!(refusal(SymbologyNif::Codabar, "A12B34A").contains("between"));
        modules(SymbologyNif::Codabar, "A40156B");
    }

    #[test]
    fn empty_data_is_refused_for_every_symbology() {
        assert_eq!(
            refusal(SymbologyNif::Qr, ""),
            "a QR code cannot encode an empty string"
        );
        assert_eq!(
            refusal(SymbologyNif::Itf, ""),
            "ITF cannot encode an empty string"
        );
    }

    #[test]
    fn a_qr_code_is_square_and_too_long_data_names_the_level() {
        let symbol = modules(SymbologyNif::Qr, "https://example.com");
        assert_eq!(symbol.columns, symbol.rows);
        assert_eq!(symbol.modules.len(), symbol.columns * symbol.rows);

        let long = "x".repeat(3000);
        assert_eq!(
            encode(SymbologyNif::Qr, &long, ErrorCorrectionNif::High).unwrap_err(),
            "3000 bytes are too many for a QR code at error correction :high"
        );
    }

    #[test]
    fn dark_runs_merge_each_rows_neighbours() {
        assert_eq!(
            dark_runs(4, &[1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1]),
            vec![(0, 0, 2), (3, 0, 1), (0, 2, 4)]
        );
        assert_eq!(dark_runs(0, &[]), vec![]);
    }
}
