defmodule PdfElixide.Document.PageLabelRange do
  @moduledoc """
  One entry of a PDF's `/PageLabels` number tree — the numbering scheme in force
  over a contiguous stretch of pages.

  Obtain the list with `PdfElixide.Document.page_label_ranges/1`. A range starts
  at `:start_page` and runs until the next range's `:start_page`, or to the end
  of the document for the last one.

  `PdfElixide.Document.page_labels/1` is the rendered form of the same data: one
  label string per page, with a decimal fallback for pages no range covers.

  ## Fields

    * `:start_page` — the zero-based page index where this range begins.
    * `:style` — the numbering style, see `t:style/0`.
    * `:prefix` — a string prepended to every label in the range, or `nil` when
      the range declares no `/P`.
    * `:start_value` — the numeric value of the range's **first** page, which is
      not necessarily `1`. Later pages count up from it.
  """

  @typedoc """
  A range's numbering style.

  `:none` means the label has no numeric part: it is `:prefix` alone, or the
  empty string when the range has no prefix.
  """
  @type style ::
          :decimal
          | :roman_upper
          | :roman_lower
          | :alpha_upper
          | :alpha_lower
          | :none

  @enforce_keys [:start_page, :style, :prefix, :start_value]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          start_page: non_neg_integer(),
          style: style(),
          prefix: String.t() | nil,
          start_value: non_neg_integer()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        start_page: start_page,
        style: style,
        prefix: prefix,
        start_value: start_value
      }) do
    %__MODULE__{
      start_page: start_page,
      style: style,
      prefix: prefix,
      start_value: start_value
    }
  end
end
