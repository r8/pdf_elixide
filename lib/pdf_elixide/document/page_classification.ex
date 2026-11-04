defmodule PdfElixide.Document.PageClassification do
  @moduledoc """
  How a page's text should be obtained, returned by
  `PdfElixide.Document.classify/2` and `PdfElixide.Document.Page.classify/1`.

  `kind` is the verdict, `confidence` how strongly the measurements support it
  (`0.0` to `1.0`), `reason` why, and `signals` the measurements themselves.
  `needs_ocr?` is `true` for the kinds whose text, or part of it, is only in
  images: `:scanned`, `:image_text` and `:mixed`; the [Text
  extraction](guides/text-extraction.md) guide has an example.

  ## What `:empty` means

  `:empty` means there is nothing to extract and nothing to OCR in the page's
  own content. It is decided from the text drawn on the page, so text the page
  carries only as form-field values or as content marked as an artifact (a
  running header, for example) does not count: such a page is `:empty` while
  `PdfElixide.Document.text/2` still returns that text.
  """
  alias PdfElixide.Document.PageClassification.Signals

  @typedoc """
  The verdict on a page.

    * `:text_layer` — the page has usable text; extract it.
    * `:scanned` — the page is an image of text, or its text is unusable;
      OCR the page.
    * `:image_text` — the page has usable text and images that may carry text
      of their own; extract the text and OCR the images.
    * `:mixed` — a page combining text with image tables or figures. This
      library does not currently return it.
    * `:empty` — there is nothing to extract or OCR. See "What `:empty`
      means" above.
    * `:unknown` — a kind this version does not name.
  """
  @type kind :: :text_layer | :scanned | :image_text | :mixed | :empty | :unknown

  @typedoc """
  Why the page received its `t:kind/0`.

    * `:native_text_high_confidence` — the page has enough cleanly mapped text.
    * `:ok` — usable text alongside images (an `:image_text` page).
    * `:no_text_layer_present` — there is no usable text: an image covers the
      page, or text was drawn as outlines rather than characters.
    * `:text_layer_below_threshold` — there is text, but it covers too little
      of an image-dominated page, or reads as scrambled or fragmented.
    * `:glyph_mapping_missing` — there is text, but its characters do not map
      to readable Unicode.
    * `:empty` — an `:empty` page.
    * `:unknown` — a reason this version does not name.
  """
  @type reason ::
          :native_text_high_confidence
          | :ok
          | :no_text_layer_present
          | :text_layer_below_threshold
          | :glyph_mapping_missing
          | :empty
          | :unknown

  @enforce_keys [:page, :kind, :confidence, :reason, :needs_ocr?, :signals]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          kind: kind(),
          confidence: float(),
          reason: reason(),
          needs_ocr?: boolean(),
          signals: Signals.t()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        kind: kind,
        confidence: confidence,
        reason: reason,
        needs_ocr: needs_ocr?,
        signals: signals
      }) do
    %__MODULE__{
      page: page,
      kind: kind,
      confidence: confidence,
      reason: reason,
      needs_ocr?: needs_ocr?,
      signals: Signals.from_nif(signals)
    }
  end
end
