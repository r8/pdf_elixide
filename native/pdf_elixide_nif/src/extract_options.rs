//! Decoded option maps for the six text-family extractors.
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
/// overlap is `intersection_area / object_area` and so is bounded to
/// `[0.0, 1.0]`. An out-of-range ratio therefore fails silently rather than
/// loudly: a negative one matches *every* object — including objects nowhere
/// near the region, which through `exclude_regions` drops the whole page — and
/// one above 1.0 matches nothing, turning an exclusion into a no-op. Upstream
/// validates the ratio in no binding, and `MinOverlap` is unreachable from
/// every other binding it ships (all of them hardcode `Intersects`), so there
/// is no upstream check to inherit and no upstream test covering it.
///
/// The single range test also rejects NaN and both infinities, every IEEE
/// comparison against NaN being false. Erlang floats can be neither, so that
/// is belt-and-braces.
///
/// **Unreachable from Elixir, and kept anyway.** `Document.validate_region_mode!/2`
/// now applies the identical bound before building the options map, so a bad
/// ratio raises `ArgumentError` there rather than arriving here — the binding
/// reports every caller mistake as an exception, and a `tagged_err` cannot be
/// told apart from a genuine `:other` PDF failure by the time it reaches
/// `Native.Wrap.call/1`. This stays as defence in depth for any future caller
/// that reaches the NIF by another route, the same posture as
/// `MAX_OUTLINE_DEPTH` in `outline.rs`. Keep the message in step with the
/// Elixir one if either changes.
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
