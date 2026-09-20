defmodule PdfElixide.Warning do
  @moduledoc """
  A condition the PDF reader tolerated and recorded while reading on.

  A warning never changes what a call returns and is never an error: a call
  that fails returns `t:PdfElixide.Error.t/0` instead, and what the reader
  recorded on the way to that failure stays recorded. Two feeds return
  warnings. `PdfElixide.Document.structured_warnings/1` lists the ones recorded
  against one document handle. `PdfElixide.Logging.structured_warnings/0` lists
  the ones the reader records process-wide, with no document to attach them
  to. See `t:category/0` for the category-to-feed mapping.

  ## Fields

    * `:category` — what kind of condition, see `t:category/0`.
    * `:page` — the zero-based page index the condition was tied to, or `nil`
      when it is not tied to one. Only `:no_text_layer` and `:image_suppressed`
      carry an index; every other category records `nil`.
    * `:message` — human-readable, the same text the condition produces as a
      log record when capture is enabled (see `PdfElixide.Logging`).
    * `:spec_section` — the ISO 32000-1 section the condition violates, such
      as `"7.3.8.1"`, or `nil` when none applies.

  Warnings do not cover every condition that produces empty text. See
  "`:on_page_error` and partly extractable documents" under
  `t:PdfElixide.Document.text_opts/0` for coverage and the EOF exception.
  """

  @typedoc """
  The kind of condition a warning records.

  Recorded against the document being read, so listed by
  `PdfElixide.Document.structured_warnings/1`:

    * `:eof_premature` — an object's header or body ran into the end of the
      file. A truncated body may still be parsed; an unreadable header fails.
    * `:no_text_layer` — a page carries no extractable text layer and looks
      like a scan, so it converts and extracts as nothing. OCR is what would
      recover its content.
    * `:image_suppressed` — an image was left out of converted output because
      its encoded size exceeds the reader's inline-image cap.

  Recorded process-wide, so listed by `PdfElixide.Logging.structured_warnings/0`:

    * `:spec_violation` — a `stream` keyword followed by a lone carriage
      return or by no line break, or a stream `/Length` that does not reach
      its `endstream`. The reader recovers by scanning.
    * `:operator_cap_exceeded` — a content stream was cut off at the reader's
      operator limit, so the rest of that page's content is missing.
    * `:type3_font` — a Type 3 font, whose glyphs may not map to text.
    * `:to_unicode_missing` — a Type0 font with no `/ToUnicode` map, so its
      text may extract as wrong or missing characters.
    * `:glyph_dropped` — a font painted nothing for a glyph while still
      advancing the cursor, so the page renders with a gap that reads as
      whitespace. Raised while rendering rather than while extracting, so it
      appears only after `PdfElixide.Document.render/3`,
      `PdfElixide.Document.rasterize/2` or
      `PdfElixide.Document.separations/3`.

  Reserved by the reader and not produced by any current condition:
  `:xref_recovery`, `:encryption`, `:font` and `:layout`.

  Finally, `:unknown` — the reader recorded a category this version of
  `PdfElixide` does not model. The `:message` still carries the condition.
  """
  @type category ::
          :spec_violation
          | :to_unicode_missing
          | :xref_recovery
          | :operator_cap_exceeded
          | :type3_font
          | :eof_premature
          | :encryption
          | :font
          | :layout
          | :glyph_dropped
          | :no_text_layer
          | :image_suppressed
          | :unknown

  @enforce_keys [:category, :page, :message, :spec_section]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          category: category(),
          page: non_neg_integer() | nil,
          message: String.t(),
          spec_section: String.t() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        category: category,
        page: page,
        message: message,
        spec_section: spec_section
      }) do
    %__MODULE__{
      category: category,
      page: page,
      message: message,
      spec_section: spec_section
    }
  end
end
