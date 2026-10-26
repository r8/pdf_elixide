use pdf_oxide::extractors::page_labels::{PageLabelExtractor, PageLabelRange, PageLabelStyle};

// A label in letters repeats one letter for every 26 pages, so past this a
// large start would build an enormous string: 1000 letters.
pub const MAX_LETTERED: u64 = 26_000;

// The page whose label in letters would pass `MAX_LETTERED`.
#[derive(Debug, PartialEq)]
pub struct TooLong {
    pub page: usize,
}

// Letters run A to Z, then AA to ZZ, then AAA (ISO 32000-1 Table 159).
// Ranges must be sorted by `start_page`, as `PageLabelExtractor` returns them.
pub fn label(ranges: &[PageLabelRange], page: usize) -> Result<String, TooLong> {
    let Some(range) = ranges.iter().rev().find(|range| range.start_page <= page) else {
        return Ok(PageLabelExtractor::get_label(ranges, page));
    };
    let first = match range.style {
        PageLabelStyle::AlphaUpper => b'A',
        PageLabelStyle::AlphaLower => b'a',
        _ => return Ok(range.format_label(page)),
    };

    let number = u64::from(range.start_value) + (page - range.start_page) as u64;
    if number > MAX_LETTERED {
        return Err(TooLong { page });
    }
    let letters = match number.checked_sub(1) {
        Some(index) => {
            let letter = char::from(first + (index % 26) as u8);
            std::iter::repeat_n(letter, (index / 26 + 1) as usize).collect()
        }
        None => String::new(),
    };
    Ok(format!(
        "{}{letters}",
        range.prefix.as_deref().unwrap_or("")
    ))
}

#[cfg(test)]
mod tests {
    use pdf_oxide::extractors::page_labels::{PageLabelRange, PageLabelStyle};

    use super::{label, TooLong, MAX_LETTERED};

    fn letters(style: PageLabelStyle, start: u32) -> Vec<PageLabelRange> {
        vec![PageLabelRange::new(0)
            .with_style(style)
            .with_start_value(start)]
    }

    #[test]
    fn upstream_still_letters_labels_like_spreadsheet_columns() {
        let range = PageLabelRange::new(0)
            .with_style(PageLabelStyle::AlphaUpper)
            .with_start_value(28);

        assert_eq!(range.format_label(0), "AB");
    }

    #[test]
    fn letters_repeat_after_z() {
        let upper = letters(PageLabelStyle::AlphaUpper, 26);
        let pages: Vec<String> = (0..4).map(|page| label(&upper, page).unwrap()).collect();

        assert_eq!(pages, ["Z", "AA", "BB", "CC"]);
        assert_eq!(
            label(&letters(PageLabelStyle::AlphaLower, 53), 0).unwrap(),
            "aaa"
        );
    }

    #[test]
    fn other_styles_and_pages_before_any_range_are_upstreams() {
        let ranges = vec![PageLabelRange::new(2)
            .with_style(PageLabelStyle::RomanLower)
            .with_prefix("p-")];

        assert_eq!(label(&ranges, 0).unwrap(), "1");
        assert_eq!(label(&ranges, 3).unwrap(), "p-ii");
    }

    #[test]
    fn letters_past_the_limit_are_refused_rather_than_built() {
        let ranges = letters(PageLabelStyle::AlphaUpper, MAX_LETTERED as u32);

        assert_eq!(label(&ranges, 0).map(|label| label.len()), Ok(1000));
        assert_eq!(label(&ranges, 1), Err(TooLong { page: 1 }));
    }
}
