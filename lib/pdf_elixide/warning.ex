defmodule PdfElixide.Warning do
  @moduledoc """
  A condition the PDF reader tolerated and recorded while reading on.

  A warning never changes what a call returns and is never an error: a call
  that fails returns `t:PdfElixide.Error.t/0` instead, and what the reader
  recorded on the way to that failure stays recorded.

  ## Which feed a warning reaches

  Which feed a warning reaches depends on the call that raised it, not on its
  category.

  `PdfElixide.Document.structured_warnings/1` lists what one document handle
  recorded: conditions always tied to the document — an object that ran into
  the end of the file, a page with no text layer — and reader-level ones met
  during `PdfElixide.Document.text/2`, `PdfElixide.Document.to_markdown/2` or
  `PdfElixide.Document.to_html/2` at any arity, which attribute what they meet
  to the document being read. `:exclude_layers` and `:exclude_inks` are the
  exception: either sends `PdfElixide.Document.text/3` down a different route,
  which does not.

  `PdfElixide.Logging.structured_warnings/0` lists everything else — the same
  reader-level conditions met during **any other call**,
  `PdfElixide.Document.to_plain_text/2` included, and those raised by a parse
  with no handle behind it at all. So the same `:spec_violation` on the same
  file reaches the document's feed after `PdfElixide.Document.text/2` and the
  process-wide one after `PdfElixide.Document.search/2`. Read both if you need
  every condition a call met.

  ## Fields

    * `:category` — what kind of condition, see `t:category/0`.
    * `:page` — the zero-based page index the condition was tied to, or `nil`
      when it is not tied to one. Only `:layout`, `:no_text_layer` and
      `:image_suppressed` carry an index; every other category records `nil`.
    * `:message` — human-readable. Many conditions also produce a log record
      when capture is enabled (see `PdfElixide.Logging`), but the two are
      worded independently and some conditions produce no log record at all,
      so do not match one against the other.
    * `:spec_section` — the ISO 32000-1 section the condition violates, such
      as `"7.3.8.1"`, or `nil` when none applies.

  Warnings do not cover every condition that produces empty text. See
  "`:on_page_error` and partly extractable documents" under
  `t:PdfElixide.Document.text_opts/0` for coverage and the EOF exception.
  """

  @typedoc """
  The kind of condition a warning records.

  See "Which feed a warning reaches" in `PdfElixide.Warning` for where each
  one is listed; a category alone does not decide that.

  Always tied to the document being read:

    * `:eof_premature` — an object's header or body ran into the end of the
      file. A truncated body may still be parsed; an unreadable header fails.
    * `:encryption` — a read was attempted before the document was
      authenticated. It records that attempt and stays recorded afterwards, so
      a handle opened with its password carries one from the read that
      preceded the password. It is a record of what happened, not evidence
      that the handle is still unauthenticated. See
      `PdfElixide.Document.authenticate/2`.
    * `:layout` — the structure tree names content that no span on the page
      carries, so some text may be missing from a reading-order-aware result.
    * `:no_text_layer` — a page carries no extractable text layer and looks
      like a scan, so it converts and extracts as nothing. OCR is what would
      recover its content.
    * `:image_suppressed` — an image was left out of converted output because
      its encoded size exceeds the reader's inline-image cap.
    * `:type3_font` — a Type 3 font, whose glyphs may not map to text.
    * `:to_unicode_missing` — a Type0 font with no `/ToUnicode` map, so its
      text may extract as wrong or missing characters.

  Reader-level, so listed in whichever feed the call chose:

    * `:spec_violation` — a `stream` keyword followed by a lone carriage
      return or by no line break, or a stream `/Length` that does not reach
      its `endstream`. The reader recovers by scanning.
    * `:operator_cap_exceeded` — a content stream was cut off at the reader's
      operator limit, so the rest of that page's content is missing.
    * `:glyph_dropped` — a font painted nothing for a glyph while still
      advancing the cursor, so the page renders with a gap that reads as
      whitespace. Raised only while rendering, so always process-wide.

  Two categories are defined but not produced by any current condition:
  `:xref_recovery` and `:font`.

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
