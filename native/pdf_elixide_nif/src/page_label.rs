use pdf_oxide::extractors::page_labels::{PageLabelExtractor, PageLabelRange, PageLabelStyle};

// Bound label allocation even when a PDF declares a large starting value.
pub const MAX_LETTERED: u64 = 26_000;
pub const MAX_ROMAN_READ: u64 = 1_000_000;

#[derive(Debug, PartialEq)]
pub enum TooLong {
    Letters { page: usize },
    Roman { page: usize },
}

// Letters run A to Z, then AA to ZZ, then AAA (ISO 32000-1 Table 159).
// Ranges must be sorted by `start_page`, as `PageLabelExtractor` returns them.
pub fn label(ranges: &[PageLabelRange], page: usize) -> Result<String, TooLong> {
    let Some(range) = ranges.iter().rev().find(|range| range.start_page <= page) else {
        return Ok(PageLabelExtractor::get_label(ranges, page));
    };
    // Count in u64 so the starting value plus the page offset cannot wrap.
    let number = u64::from(range.start_value) + (page - range.start_page) as u64;
    let prefix = range.prefix.as_deref().unwrap_or("");
    let first = match range.style {
        PageLabelStyle::AlphaUpper => b'A',
        PageLabelStyle::AlphaLower => b'a',
        PageLabelStyle::RomanUpper | PageLabelStyle::RomanLower => {
            if number > MAX_ROMAN_READ {
                return Err(TooLong::Roman { page });
            }
            return Ok(range.format_label(page));
        }
        PageLabelStyle::Decimal => return Ok(format!("{prefix}{number}")),
        PageLabelStyle::None => return Ok(prefix.to_owned()),
    };

    if number > MAX_LETTERED {
        return Err(TooLong::Letters { page });
    }
    let letters = match number.checked_sub(1) {
        Some(index) => {
            let letter = char::from(first + (index % 26) as u8);
            std::iter::repeat_n(letter, (index / 26 + 1) as usize).collect()
        }
        None => String::new(),
    };
    Ok(format!("{prefix}{letters}"))
}

#[cfg(test)]
mod tests {
    use pdf_oxide::extractors::page_labels::{PageLabelRange, PageLabelStyle};

    use super::{label, TooLong, MAX_LETTERED, MAX_ROMAN_READ};

    fn starting_at(style: PageLabelStyle, start: u32) -> Vec<PageLabelRange> {
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
        let upper = starting_at(PageLabelStyle::AlphaUpper, 26);
        let pages: Vec<String> = (0..4).map(|page| label(&upper, page).unwrap()).collect();

        assert_eq!(pages, ["Z", "AA", "BB", "CC"]);
        assert_eq!(
            label(&starting_at(PageLabelStyle::AlphaLower, 53), 0).unwrap(),
            "aaa"
        );
    }

    #[test]
    fn roman_labels_and_pages_before_any_range_are_upstreams() {
        let ranges = vec![PageLabelRange::new(2)
            .with_style(PageLabelStyle::RomanLower)
            .with_prefix("p-")];

        assert_eq!(label(&ranges, 0).unwrap(), "1");
        assert_eq!(label(&ranges, 3).unwrap(), "p-ii");
    }

    #[test]
    fn decimal_labels_count_past_the_u32_range() {
        let ranges = vec![PageLabelRange::new(0)
            .with_style(PageLabelStyle::Decimal)
            .with_start_value(u32::MAX)
            .with_prefix("p-")];

        assert_eq!(label(&ranges, 1).unwrap(), "p-4294967296");
    }

    #[test]
    fn a_range_with_no_style_labels_with_its_prefix_alone() {
        let ranges = vec![PageLabelRange::new(0)
            .with_style(PageLabelStyle::None)
            .with_start_value(u32::MAX)
            .with_prefix("cover")];

        assert_eq!(label(&ranges, 1).unwrap(), "cover");
    }

    #[test]
    fn letters_past_the_limit_are_refused_rather_than_built() {
        let ranges = starting_at(PageLabelStyle::AlphaUpper, MAX_LETTERED as u32);

        assert_eq!(label(&ranges, 0).map(|label| label.len()), Ok(1000));
        assert_eq!(label(&ranges, 1), Err(TooLong::Letters { page: 1 }));
    }

    #[test]
    fn roman_numerals_past_the_limit_are_refused_rather_than_built() {
        let ranges = starting_at(PageLabelStyle::RomanUpper, MAX_ROMAN_READ as u32);

        assert_eq!(label(&ranges, 0).map(|label| label.len()), Ok(1000));
        assert_eq!(label(&ranges, 1), Err(TooLong::Roman { page: 1 }));
    }
}
