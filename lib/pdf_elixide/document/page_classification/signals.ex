defmodule PdfElixide.Document.PageClassification.Signals do
  @moduledoc """
  The measurements a `PdfElixide.Document.PageClassification` is decided from.

  Ratios run from `0.0` to `1.0`. Areas are fractions of the page's media box,
  not its crop box.

    * `text_glyph_count` — characters drawn as text, not counting content
      marked as an artifact.
    * `text_area_ratio` — the share of the page that text covers.
    * `image_area_ratio` — the share of the page that images cover, summed
      over images and capped at `1.0`.
    * `codec` — how the page's images are compressed: `:ccitt` (fax encoding,
      typical of scanners) when any image uses it, otherwise `:dct` (JPEG) or
      `:other` after the first image, and `:none` when the page has no image.
      `:jbig2` is not currently returned. `:unknown` is an encoding class this
      version does not name.
    * `invisible_text_ratio` — the share of text drawn in invisible render
      mode, as an OCR layer over a scan is.
    * `garbled_ratio` — the share of characters that are replacement, control
      or private-use characters.
    * `fragmented_word_ratio` — the share of words of one or two characters,
      which is high when text is broken into fragments. It is `0.0` for text
      that is mostly Chinese, Japanese or Korean.
    * `repeated_word_ratio` — the share of words that repeat the word before.
    * `vector_path_count` — the number of vector paths on the page, and
      `vector_path_density` their share of all paths, characters and images
      counted together. Text converted to outlines shows as many paths and no
      characters.
    * `reliable_structure?` — whether the document marks its structure tree
      as complete and reliable.
    * `producer` — what the document's producer and creator entries suggest:
      `:scanner`, `:authoring` (a word processor, typesetter or similar), or
      `:unknown`.
    * `empty?` — whether the page has no text, no image area and no paths.

  Float fields follow the "Unbounded values" rule in
  `PdfElixide.Geometry.Rect`.
  """

  @type codec :: :none | :ccitt | :jbig2 | :dct | :other | :unknown
  @type producer :: :scanner | :authoring | :unknown

  @enforce_keys [
    :text_glyph_count,
    :text_area_ratio,
    :image_area_ratio,
    :codec,
    :invisible_text_ratio,
    :garbled_ratio,
    :fragmented_word_ratio,
    :repeated_word_ratio,
    :vector_path_density,
    :vector_path_count,
    :reliable_structure?,
    :producer,
    :empty?
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text_glyph_count: non_neg_integer(),
          text_area_ratio: float(),
          image_area_ratio: float(),
          codec: codec(),
          invisible_text_ratio: float(),
          garbled_ratio: float(),
          fragmented_word_ratio: float(),
          repeated_word_ratio: float(),
          vector_path_density: float(),
          vector_path_count: non_neg_integer(),
          reliable_structure?: boolean(),
          producer: producer(),
          empty?: boolean()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        text_glyph_count: text_glyph_count,
        text_area_ratio: text_area_ratio,
        image_area_ratio: image_area_ratio,
        codec: codec,
        invisible_text_ratio: invisible_text_ratio,
        garbled_ratio: garbled_ratio,
        fragmented_word_ratio: fragmented_word_ratio,
        repeated_word_ratio: repeated_word_ratio,
        vector_path_density: vector_path_density,
        vector_path_count: vector_path_count,
        reliable_structure: reliable_structure?,
        producer: producer,
        empty: empty?
      }) do
    %__MODULE__{
      text_glyph_count: text_glyph_count,
      text_area_ratio: text_area_ratio,
      image_area_ratio: image_area_ratio,
      codec: codec,
      invisible_text_ratio: invisible_text_ratio,
      garbled_ratio: garbled_ratio,
      fragmented_word_ratio: fragmented_word_ratio,
      repeated_word_ratio: repeated_word_ratio,
      vector_path_density: vector_path_density,
      vector_path_count: vector_path_count,
      reliable_structure?: reliable_structure?,
      producer: producer,
      empty?: empty?
    }
  end
end
