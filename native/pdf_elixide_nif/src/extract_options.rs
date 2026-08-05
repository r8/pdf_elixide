//! Decoded option maps for the six text-family extractors, and for `search`.
//!
//! Every struct here is the Rust half of an Elixir keyword list that
//! `PdfElixide.Document` has already normalized into a **complete** map — a
//! `NifMap` decode is total, so the builders on the Elixir side must emit every
//! key. Simple defaults therefore live in Elixir; the multi-field *presets*
//! (`TableDetectionConfig`, `SpanMergingConfig`) are resolved here so their
//! numbers stay sourced from upstream and cannot drift, the same reasoning
//! `table.rs` records for `TextPipelineConfig::from_conversion_options`.
//!
//! The `Option<T>` fields of a preset map mean "keep the preset's value";
//! anything else overrides it. Presets are applied by mutating a base config
//! rather than by struct literal, so an upstream release that adds a field
//! keeps compiling and keeps that field at its upstream value.

use pdf_oxide::{
    config::ExtractionProfile,
    converters::ConversionOptions,
    document::ReadingOrder,
    extractors::{AdaptiveThresholdConfig, SpanMergingConfig},
    geometry::Rect,
    layout::RectFilterMode,
    search::SearchOptions,
    structure::spatial_table_detector::{TableDetectionConfig, TableStrategy},
};
use rustler::{NifMap, NifResult, NifTaggedEnum, NifUnitEnum};

use crate::{
    atoms,
    error::tagged_err,
    geometry::{rect_from_nif, RectNif},
};

// Shared value types -----------------------------------------------------------------------------

/// How a region filter decides whether an object is inside the region:
/// `:intersects`, `:fully_contained`, or `{:min_overlap, ratio}`.
#[derive(NifTaggedEnum, Debug)]
pub enum RectFilterModeNif {
    Intersects,
    FullyContained,
    MinOverlap(f32),
}

impl From<RectFilterModeNif> for RectFilterMode {
    fn from(mode: RectFilterModeNif) -> Self {
        match mode {
            RectFilterModeNif::Intersects => RectFilterMode::Intersects,
            RectFilterModeNif::FullyContained => RectFilterMode::FullyContained,
            RectFilterModeNif::MinOverlap(ratio) => RectFilterMode::MinOverlap(ratio),
        }
    }
}

/// Rejects a `{:min_overlap, ratio}` whose ratio falls outside `0.0..=1.0`.
///
/// Upstream evaluates the mode as `overlap_with_rect(rect) >= ratio`, where the
/// overlap is bounded to `[0.0, 1.0]`, so an out-of-range ratio fails *silently*
/// rather than loudly: a negative one matches every object — which through
/// `exclude_regions` empties the page — and one above 1.0 matches none, turning
/// an exclusion into a no-op. There is no upstream check to inherit and no
/// upstream test covering it: `MinOverlap` is unreachable from every binding
/// upstream ships, all of which hardcode `Intersects`.
///
/// The single range test also rejects NaN and both infinities, every IEEE
/// comparison against NaN being false. Erlang floats can be neither, so that
/// is belt-and-braces.
///
/// **Unreachable from Elixir, and kept anyway.**
/// `Document.validate_region_mode!/2` applies the identical bound before
/// building the options map, so a bad ratio raises `ArgumentError` there. This
/// stays as defence in depth for any future caller reaching the NIF by another
/// route, the same posture as `MAX_OUTLINE_DEPTH` in `outline.rs`. Keep the
/// message in step with the Elixir one if either changes.
fn validate_mode(field: &str, mode: &RectFilterModeNif) -> NifResult<()> {
    if let RectFilterModeNif::MinOverlap(ratio) = mode {
        if !(0.0..=1.0).contains(ratio) {
            return Err(tagged_err(
                atoms::other(),
                // `{:?}` rather than `{}` so the value echoes back in the
                // float form the caller passed: `Display` renders -1.0 as -1.
                format!(
                    "Invalid :{field} {{:min_overlap, {ratio:?}}}: \
                     the ratio must be between 0.0 and 1.0"
                ),
            ));
        }
    }
    Ok(())
}

/// What the whole-document text loop does with a page that fails to extract:
/// `:skip` it (the default, and upstream's own policy) or `:halt` the call.
///
/// Read only by `document_extract_all_text`. The per-page NIF decodes it with
/// the rest of the map and ignores it, having a single page whose error it
/// always propagates — the same inert-on-one-path shape `:expand_ligatures`
/// has in the Markdown options.
#[derive(NifUnitEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnPageErrorNif {
    Skip,
    Halt,
}

/// A region filter: the rectangle plus the mode it is applied under. Absent
/// when the caller passed no `:region`.
pub struct RegionFilter {
    pub rect: Rect,
    pub mode: RectFilterMode,
}

fn region_filter(region: Option<RectNif>, mode: RectFilterModeNif) -> Option<RegionFilter> {
    region.map(|rect| RegionFilter {
        rect: rect_from_nif(rect),
        mode: mode.into(),
    })
}

/// The span-extraction tuning preset, named after the upstream
/// `ExtractionProfile` consts. Mapped to the consts directly rather than
/// through `ExtractionProfile::by_name`, which has no entry for `TJ_HEAVY`.
#[derive(NifUnitEnum, Debug)]
pub enum ExtractionProfileNif {
    Conservative,
    TjHeavy,
    Aggressive,
    Balanced,
    Academic,
    Policy,
    Form,
    Government,
    ScannedOcr,
    Adaptive,
}

impl From<ExtractionProfileNif> for ExtractionProfile {
    fn from(profile: ExtractionProfileNif) -> Self {
        match profile {
            ExtractionProfileNif::Conservative => ExtractionProfile::CONSERVATIVE,
            ExtractionProfileNif::TjHeavy => ExtractionProfile::TJ_HEAVY,
            ExtractionProfileNif::Aggressive => ExtractionProfile::AGGRESSIVE,
            ExtractionProfileNif::Balanced => ExtractionProfile::BALANCED,
            ExtractionProfileNif::Academic => ExtractionProfile::ACADEMIC,
            ExtractionProfileNif::Policy => ExtractionProfile::POLICY,
            ExtractionProfileNif::Form => ExtractionProfile::FORM,
            ExtractionProfileNif::Government => ExtractionProfile::GOVERNMENT,
            ExtractionProfileNif::ScannedOcr => ExtractionProfile::SCANNED_OCR,
            ExtractionProfileNif::Adaptive => ExtractionProfile::ADAPTIVE,
        }
    }
}

/// The reading-order strategy for span extraction. This is upstream's
/// `document::ReadingOrder`, not the `ReadingOrderMode` the Markdown and HTML
/// converters take — the two enums are unrelated and name their variants
/// differently.
#[derive(NifUnitEnum, Debug)]
pub enum SpanReadingOrderNif {
    TopToBottom,
    ColumnAware,
    Structure,
}

impl From<SpanReadingOrderNif> for ReadingOrder {
    fn from(order: SpanReadingOrderNif) -> Self {
        match order {
            SpanReadingOrderNif::TopToBottom => ReadingOrder::TopToBottom,
            SpanReadingOrderNif::ColumnAware => ReadingOrder::ColumnAware,
            SpanReadingOrderNif::Structure => ReadingOrder::Structure,
        }
    }
}

// Table detection --------------------------------------------------------------------------------

/// Which boundary evidence the spatial detector uses on one axis.
#[derive(NifUnitEnum, Debug)]
pub enum TableStrategyNif {
    Lines,
    Text,
    Both,
}

impl From<TableStrategyNif> for TableStrategy {
    fn from(strategy: TableStrategyNif) -> Self {
        match strategy {
            TableStrategyNif::Lines => TableStrategy::Lines,
            TableStrategyNif::Text => TableStrategy::Text,
            TableStrategyNif::Both => TableStrategy::Both,
        }
    }
}

/// The base `TableDetectionConfig` an override map starts from.
#[derive(NifUnitEnum, Debug)]
pub enum TablePresetNif {
    Default,
    Strict,
    Relaxed,
}

impl From<TablePresetNif> for TableDetectionConfig {
    fn from(preset: TablePresetNif) -> Self {
        match preset {
            TablePresetNif::Default => TableDetectionConfig::default(),
            TablePresetNif::Strict => TableDetectionConfig::strict(),
            TablePresetNif::Relaxed => TableDetectionConfig::relaxed(),
        }
    }
}

/// Every field of upstream's `TableDetectionConfig`, each `nil` unless the
/// caller overrode it. Python's `table_settings` dict reaches only five of
/// these.
#[derive(NifMap, Debug)]
pub struct TableDetectionNif {
    pub preset: TablePresetNif,
    pub enabled: Option<bool>,
    pub horizontal_strategy: Option<TableStrategyNif>,
    pub vertical_strategy: Option<TableStrategyNif>,
    pub column_tolerance: Option<f32>,
    pub row_tolerance: Option<f32>,
    pub min_table_cells: Option<usize>,
    pub min_table_columns: Option<usize>,
    pub regular_row_ratio: Option<f32>,
    pub max_table_columns: Option<usize>,
    pub column_merge_threshold: Option<f32>,
    pub v_split_gap: Option<f32>,
    pub text_fallback: Option<bool>,
}

impl From<TableDetectionNif> for TableDetectionConfig {
    fn from(o: TableDetectionNif) -> Self {
        let mut config: TableDetectionConfig = o.preset.into();
        if let Some(v) = o.enabled {
            config.enabled = v;
        }
        if let Some(v) = o.horizontal_strategy {
            config.horizontal_strategy = v.into();
        }
        if let Some(v) = o.vertical_strategy {
            config.vertical_strategy = v.into();
        }
        if let Some(v) = o.column_tolerance {
            config.column_tolerance = v;
        }
        if let Some(v) = o.row_tolerance {
            config.row_tolerance = v;
        }
        if let Some(v) = o.min_table_cells {
            config.min_table_cells = v;
        }
        if let Some(v) = o.min_table_columns {
            config.min_table_columns = v;
        }
        if let Some(v) = o.regular_row_ratio {
            config.regular_row_ratio = v;
        }
        if let Some(v) = o.max_table_columns {
            config.max_table_columns = v;
        }
        if let Some(v) = o.column_merge_threshold {
            config.column_merge_threshold = v;
        }
        if let Some(v) = o.v_split_gap {
            config.v_split_gap = v;
        }
        if let Some(v) = o.text_fallback {
            config.text_fallback = v;
        }
        config
    }
}

// Span merging -----------------------------------------------------------------------------------

/// The base `SpanMergingConfig` an override map starts from.
#[derive(NifUnitEnum, Debug)]
pub enum SpanPresetNif {
    Default,
    Aggressive,
    Conservative,
    Adaptive,
    Legacy,
}

impl From<SpanPresetNif> for SpanMergingConfig {
    fn from(preset: SpanPresetNif) -> Self {
        match preset {
            SpanPresetNif::Default => SpanMergingConfig::new(),
            SpanPresetNif::Aggressive => SpanMergingConfig::aggressive(),
            SpanPresetNif::Conservative => SpanMergingConfig::conservative(),
            SpanPresetNif::Adaptive => SpanMergingConfig::adaptive(),
            SpanPresetNif::Legacy => SpanMergingConfig::legacy(),
        }
    }
}

/// Overrides for the adaptive gap-statistics sub-config. Only consulted when
/// the resolved config has `use_adaptive_threshold` set.
#[derive(NifMap, Debug)]
pub struct AdaptiveThresholdNif {
    pub median_multiplier: Option<f32>,
    pub min_threshold_pt: Option<f32>,
    pub max_threshold_pt: Option<f32>,
    pub use_iqr: Option<bool>,
    pub min_samples: Option<usize>,
}

impl AdaptiveThresholdNif {
    /// Applies the overrides on top of the preset's own adaptive config, or on
    /// top of the upstream default when the preset carries none.
    fn apply(self, base: Option<AdaptiveThresholdConfig>) -> AdaptiveThresholdConfig {
        let mut config = base.unwrap_or_default();
        if let Some(v) = self.median_multiplier {
            config.median_multiplier = v;
        }
        if let Some(v) = self.min_threshold_pt {
            config.min_threshold_pt = v;
        }
        if let Some(v) = self.max_threshold_pt {
            config.max_threshold_pt = v;
        }
        if let Some(v) = self.use_iqr {
            config.use_iqr = v;
        }
        if let Some(v) = self.min_samples {
            config.min_samples = v;
        }
        config
    }
}

/// Every field of upstream's `SpanMergingConfig`. The Python bindings expose
/// none of this.
#[derive(NifMap, Debug)]
pub struct SpanMergingNif {
    pub preset: SpanPresetNif,
    pub space_threshold_em_ratio: Option<f32>,
    pub conservative_threshold_pt: Option<f32>,
    pub column_boundary_threshold_pt: Option<f32>,
    pub severe_overlap_threshold_pt: Option<f32>,
    pub use_adaptive_threshold: Option<bool>,
    pub adaptive: Option<AdaptiveThresholdNif>,
    pub detect_email_patterns: Option<bool>,
    pub email_threshold_multiplier: Option<f32>,
    pub detect_citation_markers: Option<bool>,
    pub citation_font_size_ratio: Option<f32>,
    pub merge_tm_tj_runs: Option<bool>,
}

impl From<SpanMergingNif> for SpanMergingConfig {
    fn from(o: SpanMergingNif) -> Self {
        let mut config: SpanMergingConfig = o.preset.into();
        if let Some(v) = o.space_threshold_em_ratio {
            config.space_threshold_em_ratio = v;
        }
        if let Some(v) = o.conservative_threshold_pt {
            config.conservative_threshold_pt = v;
        }
        if let Some(v) = o.column_boundary_threshold_pt {
            config.column_boundary_threshold_pt = v;
        }
        if let Some(v) = o.severe_overlap_threshold_pt {
            config.severe_overlap_threshold_pt = v;
        }
        if let Some(v) = o.use_adaptive_threshold {
            config.use_adaptive_threshold = v;
        }
        if let Some(v) = o.adaptive {
            config.adaptive_config = Some(v.apply(config.adaptive_config.take()));
        }
        if let Some(v) = o.detect_email_patterns {
            config.detect_email_patterns = v;
        }
        if let Some(v) = o.email_threshold_multiplier {
            config.email_threshold_multiplier = v;
        }
        if let Some(v) = o.detect_citation_markers {
            config.detect_citation_markers = v;
        }
        if let Some(v) = o.citation_font_size_ratio {
            config.citation_font_size_ratio = v;
        }
        if let Some(v) = o.merge_tm_tj_runs {
            config.merge_tm_tj_runs = v;
        }
        config
    }
}

// Per-extractor option maps ----------------------------------------------------------------------

/// Options for `PdfElixide.Document.text/2,3`.
#[derive(NifMap, Debug)]
pub struct TextOptionsNif {
    pub extract_tables: bool,
    pub expand_ligatures: bool,
    pub table_detection: Option<TableDetectionNif>,
    pub region: Option<RectNif>,
    pub region_mode: RectFilterModeNif,
    pub exclude_regions: Vec<RectNif>,
    pub exclude_regions_mode: RectFilterModeNif,
    pub exclude_layers: Vec<String>,
    pub exclude_inks: Vec<String>,
    pub on_page_error: OnPageErrorNif,
}

impl TextOptionsNif {
    /// The only option map with two filter modes to check.
    pub fn validate(&self) -> NifResult<()> {
        validate_mode("region_mode", &self.region_mode)?;
        validate_mode("exclude_regions_mode", &self.exclude_regions_mode)
    }
}

/// A decoded `TextOptionsNif`, split into the two shapes the upstream text
/// surface accepts. Layer/ink filtering forces `extract_text_filtered*`, which
/// hardcodes its own `ConversionOptions` — see `document.rs` for the routing.
pub struct TextOptions {
    pub conversion: ConversionOptions,
    pub region: Option<RegionFilter>,
    pub exclude_layers: Vec<String>,
    pub exclude_inks: Vec<String>,
    /// Ours, not upstream's — deliberately kept out of `conversion`, which is
    /// the options type `pdf_oxide` receives.
    pub on_page_error: OnPageErrorNif,
}

impl TextOptions {
    /// True when the caller asked for layer or ink filtering, which upstream
    /// can only serve through the filtered entry points.
    pub fn filtered(&self) -> bool {
        !self.exclude_layers.is_empty() || !self.exclude_inks.is_empty()
    }
}

impl From<TextOptionsNif> for TextOptions {
    fn from(o: TextOptionsNif) -> Self {
        let region = region_filter(o.region, o.region_mode);
        let exclude_mode: RectFilterMode = o.exclude_regions_mode.into();
        TextOptions {
            conversion: ConversionOptions {
                extract_tables: o.extract_tables,
                expand_ligatures: o.expand_ligatures,
                table_detection_config: o.table_detection.map(Into::into),
                include_region: region.as_ref().map(|filter| (filter.rect, filter.mode)),
                exclude_regions: o.exclude_regions.into_iter().map(rect_from_nif).collect(),
                exclude_regions_mode: exclude_mode,
                ..Default::default()
            },
            region,
            exclude_layers: o.exclude_layers,
            exclude_inks: o.exclude_inks,
            on_page_error: o.on_page_error,
        }
    }
}

/// Options for `PdfElixide.Document.chars/2,3`.
#[derive(NifMap, Debug)]
pub struct CharsOptionsNif {
    pub region: Option<RectNif>,
    pub region_mode: RectFilterModeNif,
    pub exclude_layers: Vec<String>,
    pub exclude_inks: Vec<String>,
}

impl CharsOptionsNif {
    pub fn validate(&self) -> NifResult<()> {
        validate_mode("region_mode", &self.region_mode)
    }
}

pub struct CharsOptions {
    pub region: Option<RegionFilter>,
    pub exclude_layers: Vec<String>,
    pub exclude_inks: Vec<String>,
}

impl From<CharsOptionsNif> for CharsOptions {
    fn from(o: CharsOptionsNif) -> Self {
        CharsOptions {
            region: region_filter(o.region, o.region_mode),
            exclude_layers: o.exclude_layers,
            exclude_inks: o.exclude_inks,
        }
    }
}

/// Options for `PdfElixide.Document.words/2,3`.
#[derive(NifMap, Debug)]
pub struct WordsOptionsNif {
    pub include_artifacts: bool,
    pub word_gap_threshold: Option<f32>,
    pub profile: Option<ExtractionProfileNif>,
    pub region: Option<RectNif>,
    pub region_mode: RectFilterModeNif,
}

impl WordsOptionsNif {
    pub fn validate(&self) -> NifResult<()> {
        validate_mode("region_mode", &self.region_mode)
    }
}

pub struct WordsOptions {
    pub include_artifacts: bool,
    pub word_gap_threshold: Option<f32>,
    pub profile: Option<ExtractionProfile>,
    pub region: Option<RegionFilter>,
}

impl From<WordsOptionsNif> for WordsOptions {
    fn from(o: WordsOptionsNif) -> Self {
        WordsOptions {
            include_artifacts: o.include_artifacts,
            word_gap_threshold: o.word_gap_threshold,
            profile: o.profile.map(Into::into),
            region: region_filter(o.region, o.region_mode),
        }
    }
}

/// Options for `PdfElixide.Document.text_lines/2,3`.
#[derive(NifMap, Debug)]
pub struct LinesOptionsNif {
    pub include_artifacts: bool,
    pub word_gap_threshold: Option<f32>,
    pub line_gap_threshold: Option<f32>,
    pub profile: Option<ExtractionProfileNif>,
    pub region: Option<RectNif>,
    pub region_mode: RectFilterModeNif,
}

impl LinesOptionsNif {
    pub fn validate(&self) -> NifResult<()> {
        validate_mode("region_mode", &self.region_mode)
    }
}

pub struct LinesOptions {
    pub include_artifacts: bool,
    pub word_gap_threshold: Option<f32>,
    pub line_gap_threshold: Option<f32>,
    pub profile: Option<ExtractionProfile>,
    pub region: Option<RegionFilter>,
}

impl From<LinesOptionsNif> for LinesOptions {
    fn from(o: LinesOptionsNif) -> Self {
        LinesOptions {
            include_artifacts: o.include_artifacts,
            word_gap_threshold: o.word_gap_threshold,
            line_gap_threshold: o.line_gap_threshold,
            profile: o.profile.map(Into::into),
            region: region_filter(o.region, o.region_mode),
        }
    }
}

/// Options for `PdfElixide.Document.spans/2,3`.
#[derive(NifMap, Debug)]
pub struct SpansOptionsNif {
    pub reading_order: SpanReadingOrderNif,
    pub span_merging: Option<SpanMergingNif>,
    pub region: Option<RectNif>,
    pub region_mode: RectFilterModeNif,
    pub exclude_layers: Vec<String>,
    pub exclude_inks: Vec<String>,
}

impl SpansOptionsNif {
    pub fn validate(&self) -> NifResult<()> {
        validate_mode("region_mode", &self.region_mode)
    }
}

pub struct SpansOptions {
    pub reading_order: ReadingOrder,
    pub span_merging: Option<SpanMergingConfig>,
    pub region: Option<RegionFilter>,
    pub exclude_layers: Vec<String>,
    pub exclude_inks: Vec<String>,
}

impl From<SpansOptionsNif> for SpansOptions {
    fn from(o: SpansOptionsNif) -> Self {
        SpansOptions {
            reading_order: o.reading_order.into(),
            span_merging: o.span_merging.map(Into::into),
            region: region_filter(o.region, o.region_mode),
            exclude_layers: o.exclude_layers,
            exclude_inks: o.exclude_inks,
        }
    }
}

/// Options for `PdfElixide.Document.tables/2,3`. There is no `region_mode`:
/// upstream's `extract_tables_in_rect_with_config` filters by bbox
/// intersection only.
#[derive(NifMap, Debug)]
pub struct TablesOptionsNif {
    pub detection: TableDetectionNif,
    pub region: Option<RectNif>,
}

pub struct TablesOptions {
    pub detection: TableDetectionConfig,
    pub region: Option<Rect>,
}

impl From<TablesOptionsNif> for TablesOptions {
    fn from(o: TablesOptionsNif) -> Self {
        TablesOptions {
            detection: o.detection.into(),
            region: o.region.map(rect_from_nif),
        }
    }
}

/// Options for `PdfElixide.Document.search/3,4`.
#[derive(NifMap, Debug)]
pub struct SearchOptionsNif {
    pub case_insensitive: bool,
    pub literal: bool,
    pub whole_word: bool,
    pub max_results: usize,
}

impl From<SearchOptionsNif> for SearchOptions {
    fn from(o: SearchOptionsNif) -> Self {
        SearchOptions::new()
            .with_case_insensitive(o.case_insensitive)
            .with_literal(o.literal)
            .with_whole_word(o.whole_word)
            .with_max_results(o.max_results)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An override map that overrides nothing. Spelled out rather than derived
    /// from `Default`, so adding a field to `TableDetectionNif` without deciding
    /// what it does here is a compile error.
    fn no_table_overrides(preset: TablePresetNif) -> TableDetectionNif {
        TableDetectionNif {
            preset,
            enabled: None,
            horizontal_strategy: None,
            vertical_strategy: None,
            column_tolerance: None,
            row_tolerance: None,
            min_table_cells: None,
            min_table_columns: None,
            regular_row_ratio: None,
            max_table_columns: None,
            column_merge_threshold: None,
            v_split_gap: None,
            text_fallback: None,
        }
    }

    /// As above, for span merging.
    fn no_span_overrides(preset: SpanPresetNif) -> SpanMergingNif {
        SpanMergingNif {
            preset,
            space_threshold_em_ratio: None,
            conservative_threshold_pt: None,
            column_boundary_threshold_pt: None,
            severe_overlap_threshold_pt: None,
            use_adaptive_threshold: None,
            adaptive: None,
            detect_email_patterns: None,
            email_threshold_multiplier: None,
            detect_citation_markers: None,
            citation_font_size_ratio: None,
            merge_tm_tj_runs: None,
        }
    }

    fn no_adaptive_overrides() -> AdaptiveThresholdNif {
        AdaptiveThresholdNif {
            median_multiplier: None,
            min_threshold_pt: None,
            max_threshold_pt: None,
            use_iqr: None,
            min_samples: None,
        }
    }

    fn table_preset(preset: TablePresetNif) -> TableDetectionConfig {
        preset.into()
    }

    fn span_preset(preset: SpanPresetNif) -> SpanMergingConfig {
        preset.into()
    }

    /// Sets one override on the `:default` preset and asserts the resolved
    /// config equals that preset with **only** the named field changed.
    ///
    /// The comparison is against a whole struct, not the one field, which is
    /// what makes this catch misrouting: writing `config.column_tolerance = v`
    /// in the `row_tolerance` arm compiles, and no fixture separates two float
    /// thresholds. The two-value form is for the fields whose NIF and upstream
    /// spellings differ (the strategies).
    macro_rules! assert_table_override {
        ($field:ident, $nif_value:expr, $config_value:expr) => {{
            let mut overrides = no_table_overrides(TablePresetNif::Default);
            overrides.$field = Some($nif_value);

            let mut expected = table_preset(TablePresetNif::Default);
            expected.$field = $config_value;

            assert_eq!(
                TableDetectionConfig::from(overrides),
                expected,
                stringify!($field)
            );
        }};
        ($field:ident, $value:expr) => {
            assert_table_override!($field, $value, $value)
        };
    }

    /// The span-merging counterpart of [`assert_table_override`]. Single-valued,
    /// because every `SpanMergingNif` field is a scalar named exactly as
    /// upstream names it.
    macro_rules! assert_span_override {
        ($field:ident, $value:expr) => {{
            let mut overrides = no_span_overrides(SpanPresetNif::Default);
            overrides.$field = Some($value);

            let mut expected = span_preset(SpanPresetNif::Default);
            expected.$field = $value;

            assert_eq!(
                SpanMergingConfig::from(overrides),
                expected,
                stringify!($field)
            );
        }};
    }

    /// The "resolve presets in Rust, apply overrides by mutating a base" rule,
    /// stated as one assertion: an override map that overrides nothing must
    /// leave the preset exactly as upstream built it.
    ///
    /// This is what stops a `From` impl being rewritten as a struct literal.
    /// A literal compiles, passes every Elixir test — `option_defaults_test.exs`
    /// compares the *keyword defaults*, not the resolved config, and roughly
    /// half of these keys are observable on no fixture at all — and silently
    /// resets every field the caller did not name back to `Default`. It is also
    /// why an upstream release that *adds* a field keeps working rather than
    /// quietly zeroing it.
    /// Compared against upstream's *own* constructor rather than against
    /// `table_preset`, so this pins the preset mapping at the same time: a
    /// `:strict` that quietly resolved to `relaxed()` would fail here.
    #[test]
    fn an_override_map_that_overrides_nothing_is_exactly_the_preset() {
        for (preset, expected) in [
            (TablePresetNif::Default, TableDetectionConfig::default()),
            (TablePresetNif::Strict, TableDetectionConfig::strict()),
            (TablePresetNif::Relaxed, TableDetectionConfig::relaxed()),
        ] {
            assert_eq!(
                TableDetectionConfig::from(no_table_overrides(preset)),
                expected
            );
        }

        for (preset, expected) in [
            (SpanPresetNif::Default, SpanMergingConfig::new()),
            (SpanPresetNif::Aggressive, SpanMergingConfig::aggressive()),
            (
                SpanPresetNif::Conservative,
                SpanMergingConfig::conservative(),
            ),
            (SpanPresetNif::Adaptive, SpanMergingConfig::adaptive()),
            (SpanPresetNif::Legacy, SpanMergingConfig::legacy()),
        ] {
            assert_eq!(SpanMergingConfig::from(no_span_overrides(preset)), expected);
        }
    }

    /// Every table override lands on its own field and disturbs no other. The
    /// values are chosen to differ from the `:default` preset, so an arm that
    /// silently dropped the override would fail rather than coincide.
    #[test]
    fn each_table_override_lands_on_its_own_field() {
        assert_table_override!(enabled, false);
        assert_table_override!(
            horizontal_strategy,
            TableStrategyNif::Lines,
            TableStrategy::Lines
        );
        assert_table_override!(
            vertical_strategy,
            TableStrategyNif::Text,
            TableStrategy::Text
        );
        assert_table_override!(column_tolerance, 1.5);
        assert_table_override!(row_tolerance, 9.5);
        assert_table_override!(min_table_cells, 7);
        assert_table_override!(min_table_columns, 5);
        assert_table_override!(regular_row_ratio, 0.9);
        assert_table_override!(max_table_columns, 21);
        assert_table_override!(column_merge_threshold, 3.5);
        assert_table_override!(v_split_gap, 11.5);
        assert_table_override!(text_fallback, false);
    }

    /// The span-merging counterpart. `adaptive` is absent here — it is the one
    /// override that is not a scalar, and it has tests of its own below.
    #[test]
    fn each_span_override_lands_on_its_own_field() {
        assert_span_override!(space_threshold_em_ratio, 0.42);
        assert_span_override!(conservative_threshold_pt, 0.75);
        assert_span_override!(column_boundary_threshold_pt, 12.5);
        assert_span_override!(severe_overlap_threshold_pt, -1.5);
        assert_span_override!(use_adaptive_threshold, false);
        assert_span_override!(detect_email_patterns, true);
        assert_span_override!(email_threshold_multiplier, 3.5);
        assert_span_override!(detect_citation_markers, true);
        assert_span_override!(citation_font_size_ratio, 0.5);
        assert_span_override!(merge_tm_tj_runs, false);
    }

    /// `AdaptiveThresholdNif::apply` layers onto the base it is handed, keeping
    /// every field the caller did not name.
    ///
    /// Called directly rather than through a preset, and that is the point: every
    /// upstream preset today carries either `None` or
    /// `Some(AdaptiveThresholdConfig::default())`, so routing through one would
    /// pass whether `apply` respected the base or ignored it. Handing it a base
    /// that is *not* the default is the only way to tell those apart, and it
    /// pins the contract for the upstream release where a preset starts carrying
    /// a tuned config.
    #[test]
    fn adaptive_overrides_layer_onto_the_supplied_base() {
        let base = AdaptiveThresholdConfig {
            median_multiplier: 2.5,
            min_threshold_pt: 0.11,
            max_threshold_pt: 1.9,
            use_iqr: true,
            min_samples: 42,
        };

        // Precondition: the base really is distinguishable from the default, or
        // the assertions below would hold either way.
        assert_ne!(base, AdaptiveThresholdConfig::default());

        let mut overrides = no_adaptive_overrides();
        overrides.median_multiplier = Some(0.75);

        let mut expected = base.clone();
        expected.median_multiplier = 0.75;

        assert_eq!(overrides.apply(Some(base.clone())), expected);
        // And with nothing overridden at all, the base survives untouched.
        assert_eq!(no_adaptive_overrides().apply(Some(base.clone())), base);
    }

    /// With no base, the overrides layer onto upstream's default rather than
    /// onto zeroes — `base.unwrap_or_default()`.
    #[test]
    fn adaptive_overrides_fall_back_to_the_upstream_default() {
        let mut overrides = no_adaptive_overrides();
        overrides.use_iqr = Some(true);
        overrides.min_samples = Some(9);

        let expected = AdaptiveThresholdConfig {
            use_iqr: true,
            min_samples: 9,
            ..AdaptiveThresholdConfig::default()
        };

        assert_eq!(overrides.apply(None), expected);
        assert_eq!(
            no_adaptive_overrides().apply(None),
            AdaptiveThresholdConfig::default()
        );
    }

    /// The nested case, end to end: an `adaptive` map inside a `SpanMergingNif`
    /// must reach the resolved config's `adaptive_config`, and must layer onto
    /// whatever the *preset* carried rather than replacing it — the
    /// `config.adaptive_config.take()` in `From<SpanMergingNif>`.
    #[test]
    fn a_nested_adaptive_map_reaches_the_resolved_config() {
        let mut overrides = no_span_overrides(SpanPresetNif::Adaptive);
        let mut adaptive = no_adaptive_overrides();
        adaptive.max_threshold_pt = Some(1.75);
        overrides.adaptive = Some(adaptive);

        let mut expected = span_preset(SpanPresetNif::Adaptive);
        let mut expected_adaptive = expected.adaptive_config.take().unwrap_or_default();
        expected_adaptive.max_threshold_pt = 1.75;
        expected.adaptive_config = Some(expected_adaptive);

        assert_eq!(SpanMergingConfig::from(overrides), expected);

        // Precondition: the `:adaptive` preset really does carry a config, so
        // the `take()` above had something to take.
        assert!(span_preset(SpanPresetNif::Adaptive)
            .adaptive_config
            .is_some());
    }

    /// A preset with no adaptive config of its own still accepts an `adaptive`
    /// map, layered onto upstream's default.
    #[test]
    fn a_nested_adaptive_map_applies_to_a_preset_that_carries_none() {
        assert!(span_preset(SpanPresetNif::Default)
            .adaptive_config
            .is_none());

        let mut overrides = no_span_overrides(SpanPresetNif::Default);
        overrides.adaptive = Some(no_adaptive_overrides());

        assert_eq!(
            SpanMergingConfig::from(overrides).adaptive_config,
            Some(AdaptiveThresholdConfig::default())
        );
    }

    /// Upstream canary, and the reason the presets are resolved in Rust at all:
    /// their numbers are supposed to stay *upstream's*. If a release collapses
    /// two of them, every caller picking between them is silently choosing the
    /// same thing, and no fixture in `mix test` is fine-grained enough to
    /// notice — `upstream_drift_test.exs` says as much, and can only check that
    /// each name still resolves to a real constructor.
    #[test]
    fn the_presets_are_still_distinct_from_one_another() {
        let tables = [
            table_preset(TablePresetNif::Default),
            table_preset(TablePresetNif::Strict),
            table_preset(TablePresetNif::Relaxed),
        ];
        for (i, a) in tables.iter().enumerate() {
            for b in &tables[i + 1..] {
                assert_ne!(a, b);
            }
        }

        let spans = [
            span_preset(SpanPresetNif::Default),
            span_preset(SpanPresetNif::Aggressive),
            span_preset(SpanPresetNif::Conservative),
            span_preset(SpanPresetNif::Adaptive),
            span_preset(SpanPresetNif::Legacy),
        ];
        for (i, a) in spans.iter().enumerate() {
            for b in &spans[i + 1..] {
                assert_ne!(a, b);
            }
        }
    }

    /// Stronger than distinctness: each preset still *means* what its typedoc in
    /// `PdfElixide.Document` tells callers it means. A release that keeps the
    /// presets distinct but reverses their character would leave the docs lying,
    /// and nothing else would catch it.
    ///
    /// Only the precise claims are asserted. `t:table_detection_opts/0` also
    /// calls `:relaxed` "tolerant", which is a summary rather than a field-wise
    /// claim — it *is* looser on `row_tolerance` and `max_table_columns`, but
    /// `column_tolerance` runs the other way (10.0 against the default's 15.0).
    /// Don't promote that word to an assertion; it would pin an upstream quirk
    /// as if the binding intended it.
    #[test]
    fn the_presets_still_mean_what_the_typedocs_say() {
        // ":strict (demands ruling lines and regular rows)"
        let strict = table_preset(TablePresetNif::Strict);
        assert_eq!(strict.horizontal_strategy, TableStrategy::Lines);
        assert_eq!(strict.vertical_strategy, TableStrategy::Lines);
        assert!(strict.regular_row_ratio > table_preset(TablePresetNif::Default).regular_row_ratio);

        // ":relaxed (… text-driven)"
        let relaxed = table_preset(TablePresetNif::Relaxed);
        assert_eq!(relaxed.horizontal_strategy, TableStrategy::Text);
        assert_eq!(relaxed.vertical_strategy, TableStrategy::Text);

        // ":aggressive (splits more readily)" / ":conservative (merges across
        // wider gaps)" — the gap that becomes a space, as a fraction of font
        // size, so *lower* means more splitting.
        let default_ratio = span_preset(SpanPresetNif::Default).space_threshold_em_ratio;
        assert!(span_preset(SpanPresetNif::Aggressive).space_threshold_em_ratio < default_ratio);
        assert!(span_preset(SpanPresetNif::Conservative).space_threshold_em_ratio > default_ratio);

        // ":adaptive (derives thresholds from page gap statistics)"
        let adaptive = span_preset(SpanPresetNif::Adaptive);
        assert!(adaptive.use_adaptive_threshold);
        assert!(adaptive.adaptive_config.is_some());
    }
}
