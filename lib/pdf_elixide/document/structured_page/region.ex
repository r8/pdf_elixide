defmodule PdfElixide.Document.StructuredPage.Region do
  @moduledoc """
  A group of spans sharing one role on a structured page, with their joined
  text and union bounding box. See `t:kind/0` for the roles.

  Spans are grouped by role, column and section. Body text and marginal labels
  can have columns: `0` for left and `1` for right, each read top to bottom.

  Gaps, blank lines and indents do not split regions, so consecutive body
  paragraphs can merge. Labels in the same column can also merge across
  intervening body text. To read paragraphs, use
  `PdfElixide.Document.to_plain_text/2`, or split `spans` at wider gaps between
  their boxes.

  Regions follow their first spans in top-to-bottom, then left-to-right order.
  A right column starting higher appears before the left column; group or sort
  by `column` when you need left-column-then-right reading order.

  `bbox` is the union of the spans' boxes in the page's raw, unrotated user
  space, like `PdfElixide.Document.spans/2` — see the "Rotated pages and
  extracted geometry" section of `PdfElixide.Document`. `section` is set only on
  a tagged page, from the nearest `/Sect`, `/Art` or `/Part` structure element,
  and is stable across pages so a chapter continuing onto the next page keeps
  one value.
  """
  alias PdfElixide.Document.Span
  alias PdfElixide.Geometry.Rect

  @typedoc """
  The role of a region.

    * `:body` — ordinary text, including any margin text the document does not
      mark as an artifact.
    * `:marginal_label` — a short standalone numeral such as a verse or section
      number: either text of at most four digits or lowercase roman letters, or
      content a tagged PDF marks `/Lbl`.
    * `:header`, `:footer`, `:page_number`, `:artifact` — content the document
      marks as an `/Artifact` with `/Type /Pagination` and a `/Subtype` of
      `/Header`, `/Footer` or `/PageNumber`; any other artifact is
      `:artifact`. These roles come from that marking alone: a running header
      that merely sits at the top of the page is `:body`.
    * `{:heading, level}` — a tagged `/H1` to `/H6` heading, levels 1 to 6.
      This library does not currently produce it: such a heading arrives as
      `:body`.
  """
  @type kind ::
          :body
          | :marginal_label
          | :header
          | :footer
          | :page_number
          | :artifact
          | {:heading, 1..6}

  @enforce_keys [:page, :kind, :text, :bbox, :spans, :column, :section]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          kind: kind(),
          text: String.t(),
          bbox: Rect.t(),
          spans: [Span.t()],
          column: non_neg_integer() | nil,
          section: non_neg_integer() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        kind: kind,
        text: text,
        bbox: bbox,
        spans: spans,
        column: column,
        section: section
      }) do
    %__MODULE__{
      page: page,
      kind: kind,
      text: text,
      bbox: bbox,
      spans: Enum.map(spans, &Span.from_nif/1),
      column: column,
      section: section
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.StructuredPage.Region{} = region, _opts) do
      concat([
        "#PdfElixide.Document.StructuredPage.Region<",
        Kernel.inspect(region.kind),
        if(region.column, do: "/" <> to_string(region.column), else: ""),
        " ",
        Kernel.inspect(region.text),
        " @ p",
        to_string(region.page),
        ">"
      ])
    end
  end
end
