defmodule PdfElixide.Builder do
  @moduledoc """
  Describes a new PDF as a pipeline of content, then lays it out in one call.

  Content operations return the builder for piping. Layout runs with
  `to_binary/2`, `save/3` or
  `PdfElixide.Editor.from_builder/1`:

      PdfElixide.Builder.new(title: "Report")
      |> PdfElixide.Builder.paragraph("Revenue rose on the year.")
      |> PdfElixide.Builder.page()
      |> PdfElixide.Builder.paragraph("Appendix")
      |> PdfElixide.Builder.save!("report.pdf")

  The [Building documents](guides/building-documents.md) guide walks through
  layout, fonts and what is refused, with examples.

  ## Layout

  Paragraphs, headings, lists and tables wrap within the margins and start new
  pages as needed. `text_at/4` and `text_in_rect/4` place text outside that
  flow. See [Flowing text](guides/building-documents.md#flowing-text) for line
  spacing, page breaks and heading placement, and
  [Tables](guides/building-documents.md#tables) for columns, spans and header
  rows.

  ## Drawing

  Draw shapes and paths outside the text flow. See
  [Drawing shapes](guides/building-documents.md#drawing-shapes) for positioning,
  paint options and redrawing an extracted path.

  ## Images

  `image/3` adds a JPEG or PNG image to the flow and `image_in_rect/4` places
  one outside it. See [Images](guides/building-documents.md#images).

  ## Barcodes

  `barcode/4` and `qr_code/3` add a linear barcode or a QR code to the flow,
  and `barcode_in_rect/5` and `qr_code_in_rect/4` place one outside it. See
  [Barcodes](guides/building-documents.md#barcodes).

  ## Links and watermarks

  A run's `:link` option makes its text clickable, `link_in_rect/3` makes an
  area clickable, and `anchor/2` names a place to link to. `watermark/3` marks
  a page, or every page. See [Links](guides/building-documents.md#links) and
  [Watermarks](guides/building-documents.md#watermarks).

  ## Form fields

  `text_field/4`, `check_box/4`, `combo_box/5`, `list_box/5`,
  `push_button/5` and `signature_field/4` add fillable fields to a page. See
  [Form fields](guides/building-documents.md#form-fields) for what each kind
  holds and how viewers draw them.

  ## Fonts

  Use a built-in family, bundled DejaVu Sans or a
  `PdfElixide.Builder.FontFamily`. The default is `:auto`. See
  [Fonts](guides/building-documents.md#fonts) for character coverage, style
  requirements and automatic font selection.

  ## Errors

  Invalid arguments raise at the call that receives them. Unsupported content
  returns `{:error, %PdfElixide.Error{reason: :unsupported}}` at build time;
  bang variants raise. See [Errors](guides/building-documents.md#errors) and
  [What the builder will not draw](guides/building-documents.md#what-the-builder-will-not-draw).
  """

  alias PdfElixide.Builder.FontFamily
  alias PdfElixide.Color.RGB
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.LayoutOptions
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [
    :title,
    :author,
    :subject,
    :creator,
    :page_size,
    :margin_top,
    :margin_bottom,
    :margin_left,
    :margin_right,
    :font,
    :font_size,
    :line_height,
    :current_page_size,
    :anchors,
    :field_names,
    :ops
  ]
  defstruct @enforce_keys

  @typedoc """
  A document description.

  Its fields are internal: build one with `new/1` and the functions in this
  module rather than constructing or reading the struct directly.
  """
  @type t :: %__MODULE__{
          title: String.t() | nil,
          author: String.t() | nil,
          subject: String.t() | nil,
          creator: String.t() | nil,
          page_size: {float(), float()},
          margin_top: float(),
          margin_bottom: float(),
          margin_left: float(),
          margin_right: float(),
          font: font(),
          font_size: float(),
          line_height: float(),
          current_page_size: {float(), float()},
          anchors: MapSet.t(String.t()),
          field_names: MapSet.t(String.t()),
          ops: [tuple()]
        }

  @typedoc """
  A font family: a built-in one, the bundled `:dejavu_sans`, a
  `PdfElixide.Builder.FontFamily`, or `:auto`. See [Fonts](#module-fonts).
  """
  @type font :: :auto | :helvetica | :times | :courier | :dejavu_sans | FontFamily.t()

  @fonts [:auto, :helvetica, :times, :courier, :dejavu_sans]

  defguardp is_point(point)
            when is_tuple(point) and tuple_size(point) == 2 and is_number(elem(point, 0)) and
                   is_number(elem(point, 1))

  @typedoc """
  Text for content operations: a string, or a list of runs, each a string or a
  `{string, opts}` tuple styling that run.

    * `:bold`, `:italic` — set the run in the family's bold, italic or bold
      italic face. Each defaults to `false`.
    * `:color` — a `PdfElixide.Color.RGB` with components from `0.0` to `1.0`.
      Defaults to `nil`, which is black.
    * `:link` — a `t:link/0` the run's text points to. Defaults to `nil`, no
      link. A linked run must contain text other than whitespace.

  Runs are joined as they are written, so a space between two runs belongs
  in one of them.
  """
  @type text :: String.t() | [String.t() | {String.t(), run_opts()}]

  @typedoc """
  Where a link points: a URI string, `{:page, index}` for a zero-based page of
  this document, or `{:anchor, name}` for a place named by `anchor/2`.

  A URI is written as given, so it must be printable ASCII with no spaces:
  encode other characters first, for example with `URI.encode/1`. A
  `javascript:` or `vbscript:` URI raises `ArgumentError`. A page past the
  document's last page, or an anchor no `anchor/2` call names, is refused when
  the document is built. See [Links](guides/building-documents.md#links).
  """
  @type link :: String.t() | {:page, non_neg_integer()} | {:anchor, String.t()}

  @typedoc """
  A position `{x, y}` in points from the page's bottom-left corner.
  """
  @type point :: {number(), number()}

  @typedoc """
  An operation of `path/3`: a `t:PdfElixide.Document.Path.operation/0`, with
  any number as a coordinate.
  """
  @type path_operation ::
          {:move_to, number(), number()}
          | {:line_to, number(), number()}
          | {:curve_to, number(), number(), number(), number(), number(), number()}
          | {:rectangle, number(), number(), number(), number()}
          | :close_path

  @typedoc "Options styling one run of `t:text/0`."
  @type run_opts :: [
          bold: boolean(),
          italic: boolean(),
          color: RGB.t() | nil,
          link: link() | nil
        ]

  @run_opts_keys [:bold, :italic, :color, :link]

  @typedoc """
  Options accepted by `new/1`.

    * `:title`, `:author`, `:subject`, `:creator` — written to the document
      information dictionary. Each defaults to `nil`, which leaves the entry
      out.
    * `:page_size` — a `t:PdfElixide.Editor.page_size/0` for every page that
      does not name its own. Defaults to `:letter`.
    * `:margin_top`, `:margin_bottom`, `:margin_left`, `:margin_right` —
      margins in points. Each defaults to `72`.
    * `:font` — the `t:font/0` for content that does not set its own.
      Defaults to `:auto`.
    * `:font_size` — text size in points for content that does not set its
      own. Defaults to `12`.
    * `:line_height` — line box height as a multiple of the text size.
      Defaults to `1.5`.

  Sizes must be positive, with each page side at most 1.0e18 points, and
  margins non-negative, leaving room on the page. A `:title`, `:author`,
  `:subject` or `:creator` may not start with `"þÿ"`, `"ÿþ"` or `"ï»¿"`,
  which read back as a byte-order mark.
  See [Errors](#module-errors) for validation failures.
  """
  @type new_opts :: [
          title: String.t() | nil,
          author: String.t() | nil,
          subject: String.t() | nil,
          creator: String.t() | nil,
          page_size: Editor.page_size(),
          margin_top: number(),
          margin_bottom: number(),
          margin_left: number(),
          margin_right: number(),
          font: font(),
          font_size: number(),
          line_height: number()
        ]

  @new_opts_keys [
    :title,
    :author,
    :subject,
    :creator,
    :page_size,
    :margin_top,
    :margin_bottom,
    :margin_left,
    :margin_right,
    :font,
    :font_size,
    :line_height
  ]

  @typedoc """
  Options accepted by `paragraph/3`.

    * `:font` — the paragraph's `t:font/0`. Defaults to `nil`, which uses the
      document's `:font`.
    * `:font_size` — text size in points. Defaults to `nil`, which uses the
      document's `:font_size`.

  A size whose line box is taller than the page's content area raises
  `ArgumentError`. See [Errors](#module-errors) for other failures.
  """
  @type paragraph_opts :: [font: font() | nil, font_size: number() | nil]

  @paragraph_opts_keys [:font, :font_size]

  @typedoc """
  Options accepted by `heading/4`.

    * `:font` — the heading's `t:font/0`. Defaults to `nil`, which uses the
      document's `:font`. The heading is set in that family's bold face.
    * `:font_size` — text size in points. Defaults to `nil`, which scales the
      document's `:font_size` by the level: 2, 1.5, 1.25 and 1.1 times for
      levels 1 to 4.

  Size validation is as for `t:paragraph_opts/0`.
  """
  @type heading_opts :: [font: font() | nil, font_size: number() | nil]

  @heading_opts_keys [:font, :font_size]

  @heading_scales %{1 => 2.0, 2 => 1.5, 3 => 1.25, 4 => 1.1}

  @typedoc """
  Options accepted by `bullet_list/3`: `:font` and `:font_size`, as for
  `paragraph/3`.
  """
  @type bullet_list_opts :: [font: font() | nil, font_size: number() | nil]

  @bullet_list_opts_keys [:font, :font_size]

  @typedoc """
  Options accepted by `numbered_list/3`.

    * `:font`, `:font_size` — as for `paragraph/3`.
    * `:style` — `:decimal` (1. 2. 3.), `:lower_roman` (i. ii. iii.) or
      `:lower_alpha` (a. b. c., then aa. ab. …). Defaults to `:decimal`.
    * `:start` — the number of the first item, a positive integer. Defaults
      to `1`. Numbers stop at 2147483647, and lower Roman numerals at 3999.
  """
  @type numbered_list_opts :: [
          font: font() | nil,
          font_size: number() | nil,
          style: :decimal | :lower_roman | :lower_alpha,
          start: pos_integer()
        ]

  @numbered_list_opts_keys [:font, :font_size, :style, :start]

  @list_styles [:decimal, :lower_roman, :lower_alpha]

  # The largest number a counter holds on every supported target, 32-bit
  # included.
  @max_list_number 2_147_483_647

  # Positions are written as 32-bit floats; past this many steps across a page
  # their rounding could merge neighboring lines or runs.
  @precision_steps 131_072

  # A line box computed from a fractional size can exceed a box it fits
  # exactly by a rounding step; the layout allows this much.
  @fit_tolerance 1.0e-6

  @typedoc """
  Options accepted by `text_at/4`: `:font` and `:font_size`, as for
  `paragraph/3`.
  """
  @type text_at_opts :: [font: font() | nil, font_size: number() | nil]

  @text_at_opts_keys [:font, :font_size]

  @typedoc """
  Options accepted by `text_in_rect/4`.

    * `:font`, `:font_size` — as for `paragraph/3`.
    * `:align` — `:left`, `:center` or `:right`: where each line sits between
      the box's left and right edges. Defaults to `:left`.

  A size whose line box is taller than the box raises `ArgumentError`.
  """
  @type text_in_rect_opts :: [
          font: font() | nil,
          font_size: number() | nil,
          align: :left | :center | :right
        ]

  @text_in_rect_opts_keys [:font, :font_size, :align]

  @aligns [:left, :center, :right]

  @typedoc """
  Options accepted by `image/3`.

    * `:width`, `:height` — the image's size in points. Defaults to `nil`.
      With neither, the image is drawn one point per pixel, scaled down to fit
      the content area if it is larger. With one, the other follows from the
      image's proportions. With both, see `:fit`.
    * `:fit` — with both `:width` and `:height`, `:contain` scales the image
      to fit within them keeping its proportions, and `:fill` stretches it to
      them. Defaults to `:contain`.
    * `:align` — `:left`, `:center` or `:right`: where the image sits between
      the margins. Defaults to `:left`.

  A `:width` or `:height` larger than the page's content area raises
  `ArgumentError`, and so does a `:fit` other than the default without both.
  """
  @type image_opts :: [
          width: number() | nil,
          height: number() | nil,
          fit: :contain | :fill,
          align: :left | :center | :right
        ]

  @image_opts_keys [:width, :height, :fit, :align]

  @typedoc """
  Options accepted by `image_in_rect/4`.

    * `:fit` — `:contain` scales the image to fit within the rect keeping its
      proportions, centered, and `:fill` stretches it to the rect. Defaults to
      `:contain`.
  """
  @type image_in_rect_opts :: [fit: :contain | :fill]

  @image_in_rect_opts_keys [:fit]

  @fits [:contain, :fill]

  @typedoc """
  A linear barcode symbology, for `barcode/4` and `barcode_in_rect/5`.

    * `:code128` — printable ASCII characters.
    * `:code39`, `:code93` — digits, capital letters, spaces and `- . $ / + %`.
    * `:ean13`, `:ean8`, `:upc_a` — 12, 7 or 11 digits, with or without the
      check digit after them. A check digit left off is computed, and one
      given must be correct.
    * `:itf` — Interleaved 2 of 5: an even number of digits.
    * `:codabar` — digits and `- $ : / . +`, between a start and a stop
      character, each one of `A`, `B`, `C` or `D`.

  Variable-length symbologies take at most 256 characters.
  """
  @type symbology :: :code128 | :code39 | :code93 | :ean13 | :ean8 | :upc_a | :itf | :codabar

  @symbologies [:code128, :code39, :code93, :ean13, :ean8, :upc_a, :itf, :codabar]

  @typedoc """
  Options accepted by `barcode_in_rect/5`.

    * `:color` — a `PdfElixide.Color.RGB` for the bars and the caption.
      Defaults to black.
    * `:background` — a `PdfElixide.Color.RGB` painted behind the whole
      symbol. Defaults to `nil`, none, so the page shows through.
    * `:quiet_zone` — the blank margin on each side of the bars, in module
      widths. It is part of the symbol's width. Defaults to `10`.
    * `:text` — whether to print the encoded data, with any computed check
      digit, as one centered line under the bars. Defaults to `false`.
    * `:font`, `:font_size` — the caption's font and size, as for
      `paragraph/3`.

  With `:text`, the caption's line box comes out of the symbol's height, and
  a height that leaves no room for bars above it raises `ArgumentError`.
  """
  @type barcode_in_rect_opts :: [
          color: RGB.t(),
          background: RGB.t() | nil,
          quiet_zone: number(),
          text: boolean(),
          font: font() | nil,
          font_size: number() | nil
        ]

  @barcode_in_rect_opts_keys [:color, :background, :quiet_zone, :text, :font, :font_size]

  @typedoc """
  Options accepted by `barcode/4`.

    * `:color`, `:background`, `:quiet_zone`, `:text`, `:font`,
      `:font_size` — as for `barcode_in_rect/5`.
    * `:width` — the symbol's width in points, quiet zones included.
      Defaults to `nil`, one point per module.
    * `:height` — the symbol's height in points, caption included. Defaults
      to `nil`: 36 points of bars, plus the caption's line box with `:text`.
    * `:align` — `:left`, `:center` or `:right`: where the symbol sits
      between the margins. Defaults to `:left`.

  A `:width` or `:height` larger than the page's content area raises
  `ArgumentError`.
  """
  @type barcode_opts :: [
          color: RGB.t(),
          background: RGB.t() | nil,
          quiet_zone: number(),
          text: boolean(),
          font: font() | nil,
          font_size: number() | nil,
          width: number() | nil,
          height: number() | nil,
          align: :left | :center | :right
        ]

  @barcode_opts_keys @barcode_in_rect_opts_keys ++ [:width, :height, :align]

  @typedoc """
  Options accepted by `qr_code_in_rect/4`.

    * `:color` — a `PdfElixide.Color.RGB` for the dark modules. Defaults to
      black.
    * `:background` — a `PdfElixide.Color.RGB` painted behind the whole
      symbol. Defaults to `nil`, none, so the page shows through.
    * `:quiet_zone` — the blank margin on each side, in modules. It is part of
      the symbol's size. Defaults to `4`.
    * `:error_correction` — `:low`, `:medium`, `:quartile` or `:high`: how
      much of the symbol can be damaged and still read, roughly 7%, 15%, 25%
      and 30%. Higher levels hold less data. Defaults to `:medium`.
  """
  @type qr_code_in_rect_opts :: [
          color: RGB.t(),
          background: RGB.t() | nil,
          quiet_zone: number(),
          error_correction: :low | :medium | :quartile | :high
        ]

  @qr_code_in_rect_opts_keys [:color, :background, :quiet_zone, :error_correction]

  @typedoc """
  Options accepted by `qr_code/3`.

    * `:color`, `:background`, `:quiet_zone`, `:error_correction` — as for
      `qr_code_in_rect/4`.
    * `:size` — the side of the square symbol in points, quiet zone
      included. Defaults to `nil`, two points per module.
    * `:align` — `:left`, `:center` or `:right`: where the symbol sits
      between the margins. Defaults to `:left`.

  A `:size` larger than the page's content area raises `ArgumentError`.
  """
  @type qr_code_opts :: [
          color: RGB.t(),
          background: RGB.t() | nil,
          quiet_zone: number(),
          error_correction: :low | :medium | :quartile | :high,
          size: number() | nil,
          align: :left | :center | :right
        ]

  @qr_code_opts_keys @qr_code_in_rect_opts_keys ++ [:size, :align]

  @error_corrections [:low, :medium, :quartile, :high]

  @linear_module 1.0
  @linear_bars 36.0
  @qr_module 2.0

  @typedoc """
  Options accepted by `watermark/3`.

    * `:pages` — `:current` marks the page the watermark lands on, and `:all`
      marks every page of the document, wherever the call sits in the
      pipeline. Defaults to `:current`.
    * `:center` — the `t:point/0` the text is centered on, each coordinate at
      most 1.0e18 points. Defaults to `nil`, the center of each page it marks.
    * `:rotation` — the text's angle in degrees, counterclockwise from
      horizontal. Defaults to `45`.
    * `:font` — `:helvetica`, `:times` or `:courier`. Defaults to
      `:helvetica`.
    * `:bold` — whether to use the font's bold face. Defaults to `false`.
    * `:font_size` — text size in points. Defaults to `72`. A size at which
      the watermark could reach more than 1.0e18 points from its center
      raises.
    * `:color` — a `PdfElixide.Color.RGB`. Defaults to 50% gray.
    * `:opacity` — from above `0` to `1`, where `1` is opaque. Defaults to
      `0.3`.
  """
  @type watermark_opts :: [
          pages: :current | :all,
          center: point() | nil,
          rotation: number(),
          font: :helvetica | :times | :courier,
          bold: boolean(),
          font_size: number(),
          color: RGB.t(),
          opacity: number()
        ]

  @watermark_opts_keys [
    :pages,
    :center,
    :rotation,
    :font,
    :bold,
    :font_size,
    :color,
    :opacity
  ]

  @typedoc """
  Options accepted by `text_field/4`.

    * `:value` — the text the field holds. Defaults to `nil`, empty.
    * `:default_value` — the text the field holds after a viewer resets the
      form. Defaults to `nil`, empty.
    * `:required` — whether the form needs a value here before it is
      submitted. Defaults to `false`.
    * `:read_only` — whether the viewer stops the user from changing the
      field. Defaults to `false`.
    * `:tooltip` — text a viewer shows when the pointer rests on the field.
      Defaults to `nil`, none.

  A value is one line of printable Windows-1252 characters, the ones the
  field's font can draw; any other character raises `ArgumentError`. A
  tooltip may hold other text too. No text a field writes, its name included,
  may hold the characters
  [Text a field cannot hold](guides/forms.md#text-a-field-cannot-hold)
  lists.
  """
  @type text_field_opts :: [
          value: String.t() | nil,
          default_value: String.t() | nil,
          required: boolean(),
          read_only: boolean(),
          tooltip: String.t() | nil
        ]

  @text_field_opts_keys [:value, :default_value, :required, :read_only, :tooltip]

  @typedoc """
  Options accepted by `check_box/4`.

    * `:checked` — whether the box starts checked. Defaults to `false`.
    * `:required`, `:read_only`, `:tooltip` — as for `text_field/4`.
  """
  @type check_box_opts :: [
          checked: boolean(),
          required: boolean(),
          read_only: boolean(),
          tooltip: String.t() | nil
        ]

  @check_box_opts_keys [:checked, :required, :read_only, :tooltip]

  @typedoc """
  Options accepted by `combo_box/5`.

    * `:selected` — the option the field starts with. Defaults to `nil`,
      none.
    * `:required`, `:read_only`, `:tooltip` — as for `text_field/4`.
  """
  @type combo_box_opts :: [
          selected: String.t() | nil,
          required: boolean(),
          read_only: boolean(),
          tooltip: String.t() | nil
        ]

  @combo_box_opts_keys [:selected, :required, :read_only, :tooltip]

  @typedoc """
  Options accepted by `list_box/5`.

    * `:multi_select` — whether the user may select several options at once.
      Defaults to `false`.
    * `:selected` — the option the field starts with, or with
      `multi_select: true` a list of them. Defaults to `nil`, none.
    * `:required`, `:read_only`, `:tooltip` — as for `text_field/4`.
  """
  @type list_box_opts :: [
          multi_select: boolean(),
          selected: String.t() | [String.t()] | nil,
          required: boolean(),
          read_only: boolean(),
          tooltip: String.t() | nil
        ]

  @list_box_opts_keys [:multi_select, :selected, :required, :read_only, :tooltip]

  @typedoc """
  Options accepted by `push_button/5`: `:read_only` and `:tooltip`, as for
  `text_field/4`.
  """
  @type push_button_opts :: [read_only: boolean(), tooltip: String.t() | nil]

  @push_button_opts_keys [:read_only, :tooltip]

  @typedoc """
  Options accepted by `signature_field/4`: `:read_only` and `:tooltip`, as for
  `text_field/4`.
  """
  @type signature_field_opts :: [read_only: boolean(), tooltip: String.t() | nil]

  @signature_field_opts_keys [:read_only, :tooltip]

  @watermark_fonts [:helvetica, :times, :courier]

  @watermark_pages [:current, :all]

  @script_schemes ["javascript:", "vbscript:"]

  @typedoc """
  A cell of `table/3`: a `t:text/0`, or a cell with its own options made by
  `cell/2`.
  """
  @type cell :: text() | cell_spec()

  @typedoc """
  A cell with options. Make it with `cell/2` rather than constructing it.
  """
  @type cell_spec :: {:cell, [map()], map()}

  @typedoc """
  Options accepted by `cell/2`.

    * `:colspan` — the number of columns the cell covers, a positive integer.
      Defaults to `1`.
    * `:rowspan` — the number of rows the cell covers, a positive integer.
      Defaults to `1`.
    * `:align` — `:left`, `:center` or `:right`, overriding the column's
      alignment. Defaults to `nil`, which uses the column's.
    * `:fill_color` — the cell's background `PdfElixide.Color.RGB`. Defaults
      to `nil`, no background.
  """
  @type cell_opts :: [
          colspan: pos_integer(),
          rowspan: pos_integer(),
          align: :left | :center | :right | nil,
          fill_color: RGB.t() | nil
        ]

  @cell_opts_keys [:colspan, :rowspan, :align, :fill_color]

  @typedoc """
  The width of a column of `table/3`: a number of points, `{:weight, n}` for
  a share of the room the other columns leave, or `:auto` for the width of the
  column's widest line.
  """
  @type column_width :: number() | {:weight, number()} | :auto

  @typedoc """
  Options accepted by `table/3`.

    * `:font`, `:font_size` — as for `paragraph/3`.
    * `:column_widths` — one `t:column_width/0` for each column. Defaults to
      `nil`, which gives every column an equal share of the content width.
    * `:align` — `:left`, `:center` or `:right` for every column, or a list
      with one for each column. Defaults to `:left`.
    * `:header_rows` — how many of the first rows are header rows, set bold
      and repeated at the top of every page the table continues onto. Defaults
      to `0`.
    * `:header_fill` — the header rows' background `PdfElixide.Color.RGB`.
      Defaults to `nil`, no background.
    * `:padding` — space in points between each cell's edges and its text,
      at least `0`. Defaults to `4`.
    * `:stroke_color` — the grid's `PdfElixide.Color.RGB`, or `nil` for no
      grid. Defaults to black.
    * `:stroke_width` — the grid's line width in points, at least `0`.
      Defaults to `0.5`.

  `:stroke_width` raises `ArgumentError` with `stroke_color: nil` unless left
  at its default. See [Tables](guides/building-documents.md#tables) for how
  widths are shared out and what is refused.
  """
  @type table_opts :: [
          font: font() | nil,
          font_size: number() | nil,
          column_widths: [column_width()] | nil,
          align: :left | :center | :right | [:left | :center | :right],
          header_rows: non_neg_integer(),
          header_fill: RGB.t() | nil,
          padding: number(),
          stroke_color: RGB.t() | nil,
          stroke_width: number()
        ]

  @grid_width 0.5

  @table_opts_keys [
    :font,
    :font_size,
    :column_widths,
    :align,
    :header_rows,
    :header_fill,
    :padding,
    :stroke_color,
    :stroke_width
  ]

  @typedoc """
  Options accepted by `rect/3`, `circle/4`, `ellipse/4`, `polygon/3` and
  `path/3`. Each is named and typed as the `PdfElixide.Document.Path` field it
  matches, so an extracted path's values for these four can be passed back.

    * `:stroke_color` — the outline's `PdfElixide.Color.RGB`, or `nil` for no
      outline. Defaults to black.
    * `:fill_color` — the inside's `PdfElixide.Color.RGB`, or `nil` to leave it
      unpainted. Defaults to `nil`.
    * `:stroke_width` — the outline's width in points, at least `0`. A width
      of `0` draws the thinnest line the display or printer can show.
      Defaults to `1`.
    * `:dash_pattern` — `{lengths, phase}`: a non-empty list of positive
      lengths in points, alternately drawn and skipped, and how far into that
      pattern the outline starts. Defaults to `nil`, a solid outline.

  A shape must be painted, so `stroke_color: nil` needs a `:fill_color`, and
  `:stroke_width` and `:dash_pattern` describe the outline, so they raise
  `ArgumentError` with `stroke_color: nil` unless left at their defaults.
  """
  @type shape_opts :: [
          stroke_color: RGB.t() | nil,
          fill_color: RGB.t() | nil,
          stroke_width: number(),
          dash_pattern: {[number(), ...], number()} | nil
        ]

  @shape_opts_keys [:stroke_color, :fill_color, :stroke_width, :dash_pattern]

  @typedoc """
  Options accepted by `line/4`, `arc/6` and `bezier/6`: the keys of
  `t:shape_opts/0` except `:fill_color`, since these draw an open line. The
  line must be drawn, so `:stroke_color` cannot be `nil`.
  """
  @type line_opts :: [
          stroke_color: RGB.t(),
          stroke_width: number(),
          dash_pattern: {[number(), ...], number()} | nil
        ]

  @line_opts_keys [:stroke_color, :stroke_width, :dash_pattern]

  # The control-point distance that makes a cubic curve approximate a quarter
  # circle: 4 × (√2 − 1) / 3.
  @kappa 0.5522847498307936

  @typedoc """
  Options accepted by `to_binary/2` and `save/3`: the keys of
  `t:PdfElixide.Editor.save_opts/0` except `:incremental`, since a new
  document has no earlier revision to append to.
  """
  @type output_opts :: [
          compress: boolean(),
          garbage_collect: boolean(),
          encryption: Editor.encryption_opts() | nil
        ]

  @output_opts_keys [:compress, :garbage_collect, :encryption]

  @doc """
  Starts a document description.

  See `t:new_opts/0` for the options.
  """
  @spec new(new_opts()) :: t()
  def new(opts \\ []) when is_list(opts) do
    options = build_new_options(opts)
    validate_page_fits!(options.page_size, options)

    struct!(
      __MODULE__,
      Map.merge(options, %{
        current_page_size: options.page_size,
        anchors: MapSet.new(),
        field_names: MapSet.new(),
        ops: []
      })
    )
  end

  @doc """
  Starts a new page, of `page_size` if given and otherwise the size of the
  page before it.

  `page_size` is a `t:PdfElixide.Editor.page_size/0` with each side at most
  1.0e18 points. The document's margins apply to every page, so they must
  leave room on this one.
  """
  @spec page(t(), Editor.page_size() | nil) :: t()
  def page(%__MODULE__{} = builder, page_size \\ nil) do
    size =
      case page_size do
        nil -> builder.current_page_size
        size -> page_size!(size)
      end

    validate_page_fits!(size, builder)

    %{builder | current_page_size: size, ops: [{:page, size} | builder.ops]}
  end

  @doc """
  Adds a paragraph of text, wrapped at the right margin.

  `text` is a string or a list of styled runs; see `t:text/0`.

      PdfElixide.Builder.paragraph(builder, ["Revenue rose ", {"12%", bold: true}])

  See [Layout](#module-layout) for how lines break and pages turn, and
  `t:paragraph_opts/0` for the options.
  """
  @spec paragraph(t(), text(), paragraph_opts()) :: t()
  def paragraph(%__MODULE__{} = builder, text, opts \\ [])
      when (is_binary(text) or is_list(text)) and is_list(opts) do
    runs = runs!(text)
    %{font: font, font_size: font_size} = build_paragraph_options(opts)
    font_size = font_size || builder.font_size
    validate_line_fits!(builder, font_size)

    op = {:paragraph, %{runs: runs, font: font || builder.font, font_size: font_size}}
    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Adds a heading of `level` 1 to 4, set in the bold face of its font family.

  `text` is a `t:text/0`; every run is bold. A heading is kept on the page of
  the line after it; see [Layout](#module-layout). See `t:heading_opts/0` for
  the options.

      PdfElixide.Builder.heading(builder, 1, "Quarterly report")
  """
  @spec heading(t(), 1..4, text(), heading_opts()) :: t()
  def heading(%__MODULE__{} = builder, level, text, opts \\ [])
      when level in 1..4 and (is_binary(text) or is_list(text)) and is_list(opts) do
    runs = text |> runs!() |> Enum.map(&%{&1 | bold: true})
    %{font: font, font_size: font_size} = build_heading_options(opts)
    font_size = font_size || builder.font_size * Map.fetch!(@heading_scales, level)
    validate_line_fits!(builder, font_size)

    op = {:heading, %{runs: runs, font: font || builder.font, font_size: font_size}}
    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Adds a list whose items are marked with a bullet.

  `items` is a list of `t:text/0`, one per item. An item longer than a line
  wraps under its own text, not under the bullet. See
  `t:bullet_list_opts/0` for the options.

      PdfElixide.Builder.bullet_list(builder, ["Revenue", ["Costs ", {"down", bold: true}]])
  """
  @spec bullet_list(t(), [text()], bullet_list_opts()) :: t()
  def bullet_list(%__MODULE__{} = builder, items, opts \\ [])
      when is_list(items) and is_list(opts) do
    opts = Keyword.validate!(opts, @bullet_list_opts_keys)
    list(builder, items, :bullet, 1, opts)
  end

  @doc """
  Adds a list whose items are numbered.

  As `bullet_list/3`, with the numbers right-aligned so the items' text
  lines up. See `t:numbered_list_opts/0` for the options.

      PdfElixide.Builder.numbered_list(builder, ["First", "Second"], style: :lower_roman)
  """
  @spec numbered_list(t(), [text()], numbered_list_opts()) :: t()
  def numbered_list(%__MODULE__{} = builder, items, opts \\ [])
      when is_list(items) and is_list(opts) do
    %{style: style, start: start} = build_numbered_list_options(opts)

    last = start + length(items) - 1

    if style == :lower_roman and last > 3999 do
      raise ArgumentError,
            "invalid :start, lower Roman numerals stop at 3999, and these items " <>
              "would reach #{last}"
    end

    if last > @max_list_number do
      raise ArgumentError,
            "invalid :start, list numbers stop at #{@max_list_number}, and these " <>
              "items would reach #{last}"
    end

    list(builder, items, style, start, Keyword.take(opts, [:font, :font_size]))
  end

  defp list(builder, items, marker, start, opts) do
    items = Enum.map(items, &item!/1)
    %{font: font, font_size: font_size} = build_paragraph_options(opts)
    font_size = font_size || builder.font_size
    validate_line_fits!(builder, font_size)

    op =
      {:list,
       %{
         items: items,
         font: font || builder.font,
         font_size: font_size,
         marker: marker,
         start: start
       }}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Adds `points` of space before the next block.

  The space adds to a paragraph's own space after it. It is dropped when a
  page break comes first, so it never pushes a page's first line down.
  """
  @spec space(t(), number()) :: t()
  def space(%__MODULE__{} = builder, points) when is_number(points) do
    %{builder | ops: [{:space, non_negative!(:points, points)} | builder.ops]}
  end

  @doc """
  Adds a thin gray line across the page between the margins.

  The line sits in the middle of a box as tall as the document's
  `:font_size`.
  """
  @spec rule(t()) :: t()
  def rule(%__MODULE__{} = builder) do
    {_width, height} = builder.current_page_size
    room = height - builder.margin_top - builder.margin_bottom

    if builder.font_size > room do
      raise ArgumentError,
            "invalid layout, a rule takes #{builder.font_size} points (the document's " <>
              ":font_size), more than the #{room}-point content height"
    end

    %{builder | ops: [{:rule, builder.font_size} | builder.ops]}
  end

  @doc """
  Draws one line of text on the current page, its baseline starting at
  `point`.

  `point` is a `t:point/0`. The text is placed outside the flow: it does not
  wrap, it may sit in the margins, and paragraphs, headings and lists around it
  neither move it nor make room for it. If no page has started yet, the first
  one starts here.

  `text` is a `t:text/0` without `\\n`; a run of whitespace is laid out as one
  space. Text extending beyond the page edge is refused when the document
  is built. See `t:text_at_opts/0` for the options.

      PdfElixide.Builder.text_at(builder, {72, 36}, "Confidential", font_size: 9)
  """
  @spec text_at(t(), point(), text(), text_at_opts()) :: t()
  def text_at(%__MODULE__{} = builder, point, text, opts \\ [])
      when is_point(point) and (is_binary(text) or is_list(text)) and is_list(opts) do
    runs = runs!(text)
    validate_one_line!(runs)
    opts = Keyword.validate!(opts, @text_at_opts_keys)
    %{font: font, font_size: font_size} = build_paragraph_options(opts)
    font_size = font_size || builder.font_size
    {x, y} = LayoutOptions.point!("point", point)
    validate_precise!(builder, font_size)

    op =
      {:text_at, %{runs: runs, font: font || builder.font, font_size: font_size, x: x, y: y}}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Draws text wrapped within `rect` on the current page.

  `rect` is a `PdfElixide.Geometry.Rect` in points from the page's
  bottom-left corner, as for `rect/3`; reversed corners are normalized.
  `text` is a `t:text/0`, placed from the box's top edge outside the flow.
  If no page has started yet, the first one starts here.

  See [Text in a box](guides/building-documents.md#text-in-a-box) for layout
  and overflow behavior, and `t:text_in_rect_opts/0` for the options.

      alias PdfElixide.Geometry.Rect

      PdfElixide.Builder.text_in_rect(
        builder,
        %Rect{x: 340.0, y: 600.0, width: 200.0, height: 60.0},
        ["Total ", {"12%", bold: true}],
        align: :right
      )
  """
  @spec text_in_rect(t(), Rect.t(), text(), text_in_rect_opts()) :: t()
  def text_in_rect(%__MODULE__{} = builder, %Rect{} = rect, text, opts \\ [])
      when (is_binary(text) or is_list(text)) and is_list(opts) do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()
    width = LayoutOptions.positive!("rect", width)
    height = LayoutOptions.positive!("rect", height)
    runs = runs!(text)
    %{font: font, font_size: font_size, align: align} = build_text_in_rect_options(opts)
    font_size = font_size || builder.font_size
    validate_line_fits_box!(builder, font_size, height)

    op =
      {:text_in_rect,
       %{
         runs: runs,
         font: font || builder.font,
         font_size: font_size,
         x: x,
         y: y,
         width: width,
         height: height,
         align: align
       }}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Makes a table cell with its own options, for `table/3`.

  `text` is a `t:text/0`. See `t:cell_opts/0` for the options.

      PdfElixide.Builder.cell("Total", colspan: 2, align: :right)
  """
  @spec cell(text(), cell_opts()) :: cell_spec()
  def cell(text, opts \\ []) when (is_binary(text) or is_list(text)) and is_list(opts) do
    {:cell, runs!(text), build_cell_options(opts)}
  end

  @doc """
  Adds a table, wrapping each cell's text within its column.

  `rows` is a list of rows, each a list of `t:cell/0`.

      PdfElixide.Builder.table(
        builder,
        [
          ["Item", "Amount"],
          ["Coffee", "4.50"]
        ],
        header_rows: 1
      )

  See [Tables](guides/building-documents.md#tables) for layout and
  pagination, and `t:table_opts/0` for the options.
  """
  @spec table(t(), [[cell()]], table_opts()) :: t()
  def table(%__MODULE__{} = builder, rows, opts \\ []) when is_list(rows) and is_list(opts) do
    options = build_table_options(opts)
    font_size = options.font_size || builder.font_size
    validate_line_fits!(builder, font_size)

    rows = Enum.map(rows, &table_row!/1)

    if options.header_rows > length(rows) do
      raise ArgumentError,
            "invalid :header_rows, the table has #{length(rows)} rows: #{options.header_rows}"
    end

    {rows, columns} = tile!(rows, options.header_rows)
    widths = table_widths!(builder, options, columns)
    aligns = table_aligns!(options.align, columns)

    rows =
      for {cells, row} <- Enum.with_index(rows) do
        Enum.map(cells, &resolve_cell(&1, row < options.header_rows, aligns))
      end

    op =
      {:table,
       options
       |> Map.drop([:align])
       |> Map.merge(%{
         rows: rows,
         font: options.font || builder.font,
         font_size: font_size,
         column_widths: widths
       })}

    %{builder | ops: [op | builder.ops]}
  end

  defp resolve_cell(cell, header?, aligns) do
    runs = if header?, do: Enum.map(cell.runs, &%{&1 | bold: true}), else: cell.runs
    %{cell | runs: runs, align: cell.align || Enum.at(aligns, cell.column)}
  end

  defp table_row!(cells) when is_list(cells), do: Enum.map(cells, &table_cell!/1)

  defp table_row!(other) do
    raise ArgumentError, "invalid row, expected a list of cells: #{inspect(other)}"
  end

  defp table_cell!({:cell, runs, %{colspan: _} = options}) when is_list(runs), do: {runs, options}

  defp table_cell!(text) when is_binary(text) or is_list(text),
    do: {runs!(text), build_cell_options([])}

  defp table_cell!(other) do
    raise ArgumentError,
          "invalid cell, expected a string, a list of runs or a cell from cell/2: " <>
            inspect(other)
  end

  # Keep occupancy by row and discard completed rows so validation never
  # rescans earlier rows.
  defp tile!(rows, header_rows) do
    count = length(rows)

    {rows, {_taken, columns}} =
      rows
      |> Enum.with_index()
      |> Enum.map_reduce({%{}, nil}, fn {cells, row}, {taken, columns} ->
        {own, taken} = Map.pop(taken, row, MapSet.new())

        {cells, {own, taken, _next}} =
          Enum.map_reduce(cells, {own, taken, 0}, fn {runs, options}, {own, taken, column} ->
            column = free_column(own, column)
            {own, taken} = span!(own, taken, row, column, options, count, header_rows)
            cell = Map.merge(options, %{runs: runs, column: column})
            {cell, {own, taken, column + options.colspan}}
          end)

        {cells, {taken, row_columns!(own, row, columns)}}
      end)

    {rows, columns || 0}
  end

  defp free_column(own, column) do
    if MapSet.member?(own, column), do: free_column(own, column + 1), else: column
  end

  defp span!(own, taken, row, column, options, count, header_rows) do
    %{colspan: colspan, rowspan: rowspan} = options
    at = "the cell at row #{row}, column #{column}"

    if row + rowspan > count do
      raise ArgumentError,
            "invalid rows, #{at} spans #{rowspan} rows, past the table's last row"
    end

    if row < header_rows and row + rowspan > header_rows do
      raise ArgumentError, "invalid rows, #{at} spans from the header rows into the body"
    end

    span = MapSet.new(column..(column + colspan - 1))
    below = if rowspan > 1, do: (row + 1)..(row + rowspan - 1), else: []

    overlaps =
      not MapSet.disjoint?(own, span) or
        Enum.any?(below, &(not MapSet.disjoint?(Map.get(taken, &1, MapSet.new()), span)))

    if overlaps do
      raise ArgumentError, "invalid rows, #{at} overlaps a cell spanning from an earlier row"
    end

    taken =
      Enum.reduce(below, taken, fn later, taken ->
        Map.update(taken, later, span, &MapSet.union(&1, span))
      end)

    {MapSet.union(own, span), taken}
  end

  defp row_columns!(own, row, columns) do
    width = MapSet.size(own)

    cond do
      width == 0 ->
        raise ArgumentError, "invalid rows, row #{row} covers no columns"

      Enum.max(own) != width - 1 ->
        empty = Enum.find(0..width, &(not MapSet.member?(own, &1)))
        raise ArgumentError, "invalid rows, row #{row} leaves column #{empty} empty"

      columns != nil and width != columns ->
        raise ArgumentError,
              "invalid rows, row #{row} covers #{width} columns and row 0 covers #{columns}"

      true ->
        width
    end
  end

  defp table_widths!(_builder, %{column_widths: nil}, columns),
    do: List.duplicate({:weight, 1.0}, columns)

  defp table_widths!(builder, %{column_widths: widths, padding: padding}, columns) do
    if columns > 0 and length(widths) != columns do
      raise ArgumentError,
            "invalid :column_widths, expected one for each of the table's #{columns} " <>
              "columns: #{inspect(widths)}"
    end

    fixed = for {:points, points} <- widths, do: points

    case Enum.find(fixed, &(&1 <= 2 * padding)) do
      nil ->
        :ok

      narrow ->
        raise ArgumentError,
              "invalid :column_widths, a #{narrow}-point column leaves no room for text " <>
                "inside #{padding} points of padding on each side"
    end

    {width, _height} = builder.current_page_size
    room = width - builder.margin_left - builder.margin_right

    if Enum.sum(fixed) > room + @fit_tolerance do
      raise ArgumentError,
            "invalid :column_widths, fixed columns of #{Enum.sum(fixed)} points exceed the " <>
              "#{room}-point content width"
    end

    widths
  end

  defp table_aligns!(align, columns) when is_atom(align), do: List.duplicate(align, columns)

  defp table_aligns!(aligns, columns) do
    if columns > 0 and length(aligns) != columns do
      raise ArgumentError,
            "invalid :align, expected one for each of the table's #{columns} columns: " <>
              inspect(aligns)
    end

    aligns
  end

  @doc """
  Adds a JPEG or PNG image to the flow, between the margins.

  `image` is the image file's bytes. See `t:image_opts/0` for sizing and
  alignment, and [Images](guides/building-documents.md#images) for page breaks
  and spacing.

      logo = File.read!("logo.png")
      PdfElixide.Builder.image(builder, logo, width: 120, align: :center)
  """
  @spec image(t(), binary(), image_opts()) :: t()
  def image(%__MODULE__{} = builder, image, opts \\ [])
      when is_binary(image) and is_list(opts) do
    %{width: width, height: height, fit: fit, align: align} = build_image_options(opts)
    {page_width, page_height} = builder.current_page_size
    validate_image_fits!(:width, width, page_width - builder.margin_left - builder.margin_right)

    validate_image_fits!(
      :height,
      height,
      page_height - builder.margin_top - builder.margin_bottom
    )

    op =
      {:image,
       %{
         image: image,
         width: width,
         height: height,
         fit: fit,
         align: align,
         font_size: builder.font_size
       }}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Draws a JPEG or PNG image within `rect` on the current page.

  `rect` is a `PdfElixide.Geometry.Rect` in points from the page's
  bottom-left corner, as for `rect/3`; reversed corners are normalized.
  `image` is the image file's bytes. The image is placed outside the flow and
  may extend past the page's edges. If no page has started yet, the first one
  starts here. See [Images](guides/building-documents.md#images) and
  `t:image_in_rect_opts/0` for the options.
  """
  @spec image_in_rect(t(), Rect.t(), binary(), image_in_rect_opts()) :: t()
  def image_in_rect(%__MODULE__{} = builder, %Rect{} = rect, image, opts \\ [])
      when is_binary(image) and is_list(opts) do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()
    width = LayoutOptions.positive!("rect", width)
    height = LayoutOptions.positive!("rect", height)
    %{fit: fit} = build_image_in_rect_options(opts)

    op =
      {:image_in_rect, %{image: image, x: x, y: y, width: width, height: height, fit: fit}}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Adds a linear barcode to the flow, between the margins.

  See `t:symbology/0` for accepted data, `t:barcode_opts/0` for options and
  [Barcodes](guides/building-documents.md#barcodes) for layout and errors.

      PdfElixide.Builder.barcode(builder, :ean13, "590123412345", text: true)
  """
  @spec barcode(t(), symbology(), String.t(), barcode_opts()) :: t()
  def barcode(%__MODULE__{} = builder, symbology, data, opts \\ [])
      when is_binary(data) and is_list(opts) do
    opts = Keyword.validate!(opts, @barcode_opts_keys)
    %{width: width, height: height, align: align} = build_barcode_options(opts)
    linear_opts = Keyword.take(opts, @barcode_in_rect_opts_keys)
    {symbol, caption_line} = linear_symbol!(builder, symbology, data, linear_opts)
    width = width || (symbol.columns + 2 * symbol.quiet_zone) * @linear_module
    height = height || @linear_bars + caption_line
    validate_bars_fit!(height, caption_line)
    validate_block_fits!(builder, width, height, "barcode")

    op =
      {:barcode,
       %{
         barcode: symbol,
         width: width,
         height: height,
         align: align,
         font_size: builder.font_size
       }}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Draws a linear barcode within `rect` on the current page, outside the flow.

  The symbol fills the rect, quiet zones included. See `t:symbology/0` for
  accepted data, `t:barcode_in_rect_opts/0` for options and
  [Barcodes](guides/building-documents.md#barcodes) for coordinates and errors.

      alias PdfElixide.Geometry.Rect

      rect = %Rect{x: 72.0, y: 640.0, width: 200.0, height: 60.0}
      PdfElixide.Builder.barcode_in_rect(builder, rect, :code128, "PO-2026-0412", text: true)
  """
  @spec barcode_in_rect(t(), Rect.t(), symbology(), String.t(), barcode_in_rect_opts()) :: t()
  def barcode_in_rect(%__MODULE__{} = builder, %Rect{} = rect, symbology, data, opts \\ [])
      when is_binary(data) and is_list(opts) do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()
    width = LayoutOptions.positive!("rect", width)
    height = LayoutOptions.positive!("rect", height)
    opts = Keyword.validate!(opts, @barcode_in_rect_opts_keys)
    {symbol, caption_line} = linear_symbol!(builder, symbology, data, opts)
    validate_bars_fit!(height, caption_line)

    op =
      {:barcode_in_rect, %{barcode: symbol, x: x, y: y, width: width, height: height}}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Adds a QR code to the flow, between the margins.

  See `t:qr_code_opts/0` for options and
  [Barcodes](guides/building-documents.md#barcodes) for layout and errors.

      PdfElixide.Builder.qr_code(builder, "https://example.com", size: 96)
  """
  @spec qr_code(t(), String.t(), qr_code_opts()) :: t()
  def qr_code(%__MODULE__{} = builder, data, opts \\ [])
      when is_binary(data) and is_list(opts) do
    opts = Keyword.validate!(opts, @qr_code_opts_keys)
    %{size: size, align: align} = build_qr_code_options(opts)
    symbol = qr_symbol!(data, Keyword.take(opts, @qr_code_in_rect_opts_keys))
    size = size || (symbol.columns + 2 * symbol.quiet_zone) * @qr_module
    validate_block_fits!(builder, size, size, "QR code")

    op =
      {:barcode,
       %{barcode: symbol, width: size, height: size, align: align, font_size: builder.font_size}}

    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Draws a QR code within `rect` on the current page, outside the flow.

  The symbol is the largest centered square that fits, quiet zone included.
  See `t:qr_code_in_rect_opts/0` for options and
  [Barcodes](guides/building-documents.md#barcodes) for coordinates and errors.

      alias PdfElixide.Geometry.Rect

      rect = %Rect{x: 468.0, y: 648.0, width: 72.0, height: 72.0}
      PdfElixide.Builder.qr_code_in_rect(builder, rect, "https://example.com", error_correction: :high)
  """
  @spec qr_code_in_rect(t(), Rect.t(), String.t(), qr_code_in_rect_opts()) :: t()
  def qr_code_in_rect(%__MODULE__{} = builder, %Rect{} = rect, data, opts \\ [])
      when is_binary(data) and is_list(opts) do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()
    width = LayoutOptions.positive!("rect", width)
    height = LayoutOptions.positive!("rect", height)
    symbol = qr_symbol!(data, opts)
    side = min(width, height)

    op =
      {:barcode_in_rect,
       %{
         barcode: symbol,
         x: x + (width - side) / 2,
         y: y + (height - side) / 2,
         width: side,
         height: side
       }}

    %{builder | ops: [op | builder.ops]}
  end

  defp linear_symbol!(builder, symbology, data, opts) do
    if symbology not in @symbologies do
      raise ArgumentError,
            "invalid symbology, expected one of #{inspect(@symbologies)}: #{inspect(symbology)}"
    end

    options = build_barcode_in_rect_options(opts)
    encoded = encode_barcode!(symbology, data, :medium)

    {caption, caption_line} =
      if options.text do
        font_size = options.font_size || builder.font_size
        validate_line_precise!(builder, font_size)
        run = run!({encoded.text, color: options.color})

        {%{runs: [run], font: options.font || builder.font, font_size: font_size},
         font_size * builder.line_height}
      else
        {nil, 0.0}
      end

    {symbol(encoded, options, caption), caption_line}
  end

  defp qr_symbol!(data, opts) do
    options = build_qr_code_in_rect_options(opts)
    encoded = encode_barcode!(:qr, data, options.error_correction)
    symbol(encoded, options, nil)
  end

  defp symbol(encoded, options, caption) do
    %{columns: columns, rows: rows, modules: modules} = encoded

    %{
      columns: columns,
      rows: rows,
      modules: modules,
      quiet_zone: options.quiet_zone,
      color: options.color,
      background: options.background,
      caption: caption
    }
  end

  defp encode_barcode!(symbology, data, error_correction) do
    data = LayoutOptions.utf8!("data", data)

    case Wrap.call(fn -> Native.builder_encode_barcode(symbology, data, error_correction) end) do
      {:ok, {:invalid, message}} ->
        raise ArgumentError,
              "invalid data, #{message}: #{inspect(data, printable_limit: 100)}"

      {:ok, %{columns: _, rows: _, modules: _, text: _} = encoded} ->
        encoded

      {:error, error} ->
        raise error
    end
  end

  defp validate_bars_fit!(height, caption_line) do
    if caption_line > 0 and height <= caption_line + @fit_tolerance do
      raise ArgumentError,
            "invalid height, a #{height}-point barcode leaves no room for bars above its " <>
              "#{caption_line}-point caption; enlarge it, or reduce the font size or the " <>
              "line height"
    end
  end

  @doc """
  Makes `rect` on the current page a link to `link`.

  `rect` is a `PdfElixide.Geometry.Rect` in points from the page's
  bottom-left corner, as for `rect/3`; reversed corners are normalized. It
  must overlap the page, and any part outside the page is dropped. `link` is a
  `t:link/0`. Use it to make an image or a drawn shape clickable; to link
  text, give its run a `:link` instead. If no page has started yet, the first
  one starts here.

      PdfElixide.Builder.link_in_rect(builder, rect, "https://example.com")
  """
  @spec link_in_rect(t(), Rect.t(), link()) :: t()
  def link_in_rect(%__MODULE__{} = builder, %Rect{} = rect, link) when link != nil do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()
    width = LayoutOptions.positive!("rect", width)
    height = LayoutOptions.positive!("rect", height)
    {page_width, page_height} = builder.current_page_size

    if x >= page_width or y >= page_height or x + width <= 0 or y + height <= 0 do
      raise ArgumentError,
            "invalid rect, it lies outside the #{page_width} × #{page_height} page, so " <>
              "nothing could be clicked"
    end

    op = {:link_in_rect, %{x: x, y: y, width: width, height: height, link: link!(link)}}
    %{builder | ops: [op | builder.ops]}
  end

  @doc """
  Names the place where the next flowing content starts, for a
  `{:anchor, name}` link.

  The anchor points to the top of the next paragraph, heading, list, table,
  image or rule, on whatever page that content lands. With no flowing content
  after it, it points to where the flow ends. Each anchor needs its own
  non-empty `name`.

      PdfElixide.Builder.anchor(builder, "appendix")

  See [Links](guides/building-documents.md#links) for a complete example.
  """
  @spec anchor(t(), String.t()) :: t()
  def anchor(%__MODULE__{} = builder, name) when is_binary(name) do
    name = anchor_name!("name", name)

    if MapSet.member?(builder.anchors, name) do
      raise ArgumentError,
            "invalid name, an anchor named #{inspect(name)} already exists; give each " <>
              "anchor its own name"
    end

    %{builder | anchors: MapSet.put(builder.anchors, name), ops: [{:anchor, name} | builder.ops]}
  end

  @doc """
  Draws `text` as a translucent watermark on the current page, or on every
  page.

  `text` is one line of printable ASCII characters. The watermark is drawn
  over the page's content as an annotation. See
  [Watermarks](guides/building-documents.md#watermarks) for what that means
  for extraction, editing and printing, and `t:watermark_opts/0` for the
  options.

      PdfElixide.Builder.watermark(builder, "CONFIDENTIAL", pages: :all)
  """
  @spec watermark(t(), String.t(), watermark_opts()) :: t()
  def watermark(%__MODULE__{} = builder, text, opts \\ [])
      when is_binary(text) and is_list(opts) do
    if not (text =~ ~r/\A[\x20-\x7E]*\z/ and String.trim(text) != "") do
      raise ArgumentError,
            "invalid text, expected one line of printable ASCII characters that are not " <>
              "all spaces: #{inspect(text)}"
    end

    options = build_watermark_options(opts)

    # Bound the rotated watermark's reach, including its positioning offset.
    if not LayoutOptions.writable?(options.font_size * (byte_size(text) + 2) * 2) do
      raise ArgumentError,
            "invalid :font_size, #{inspect(text)} at #{options.font_size} points is too " <>
              "wide to place: #{inspect(options.font_size)}"
    end

    %{builder | ops: [{:watermark, Map.put(options, :text, text)} | builder.ops]}
  end

  @doc """
  Adds a text field to the current page.

  `name` is the field's name, as `PdfElixide.Form.fields/1` reports it. `rect`
  is a `PdfElixide.Geometry.Rect` in points from the page's bottom-left
  corner, as for `rect/3`; reversed corners are normalized, and it must lie on
  the page. See `t:text_field_opts/0` for the options and
  [Form fields](guides/building-documents.md#form-fields) for how a viewer
  draws the field.

      alias PdfElixide.Geometry.Rect

      PdfElixide.Builder.text_field(
        builder,
        "full_name",
        %Rect{x: 72.0, y: 650.0, width: 200.0, height: 20.0},
        tooltip: "Your full name"
      )
  """
  @spec text_field(t(), String.t(), Rect.t(), text_field_opts()) :: t()
  def text_field(%__MODULE__{} = builder, name, %Rect{} = rect, opts \\ [])
      when is_binary(name) and is_list(opts) do
    options = build_text_field_options(opts)
    kind = {:text, Map.take(options, [:value, :default_value])}

    field(builder, name, rect, Map.drop(options, [:value, :default_value]), kind)
  end

  @doc """
  Adds a check box to the current page.

  `name` and `rect` are as for `text_field/4`. A checked box has the on state
  `"Yes"`, the one `PdfElixide.Form.put_value/3` writes for `true`. See
  `t:check_box_opts/0` for the options.
  """
  @spec check_box(t(), String.t(), Rect.t(), check_box_opts()) :: t()
  def check_box(%__MODULE__{} = builder, name, %Rect{} = rect, opts \\ [])
      when is_binary(name) and is_list(opts) do
    {checked, options} = opts |> build_check_box_options() |> Map.pop!(:checked)

    field(builder, name, rect, options, {:check_box, checked})
  end

  @doc """
  Adds a combo box, a drop-down list of `options`, to the current page.

  `name` and `rect` are as for `text_field/4`. `options` is a non-empty list
  of distinct strings, each both shown and stored as the field's value when
  chosen. See `t:combo_box_opts/0` for the options.
  """
  @spec combo_box(t(), String.t(), Rect.t(), [String.t(), ...], combo_box_opts()) :: t()
  def combo_box(%__MODULE__{} = builder, name, %Rect{} = rect, options, opts \\ [])
      when is_binary(name) and is_list(options) and is_list(opts) do
    choices = choices!(options)
    {selected, field_options} = opts |> build_combo_box_options() |> Map.pop!(:selected)
    selected!(selected, choices)

    field(
      builder,
      name,
      rect,
      field_options,
      {:combo_box, %{options: choices, selected: selected}}
    )
  end

  @doc """
  Adds a list box, a scrolling list of `options`, to the current page.

  `name` and `rect` are as for `text_field/4`, and `options` as for
  `combo_box/5`. See `t:list_box_opts/0` for the options, including choosing
  several at once.
  """
  @spec list_box(t(), String.t(), Rect.t(), [String.t(), ...], list_box_opts()) :: t()
  def list_box(%__MODULE__{} = builder, name, %Rect{} = rect, options, opts \\ [])
      when is_binary(name) and is_list(options) and is_list(opts) do
    choices = choices!(options)

    {%{selected: selected, multi_select: multi_select}, field_options} =
      opts |> build_list_box_options() |> Map.split([:selected, :multi_select])

    selected = list_selection!(selected, multi_select, choices)

    kind = {:list_box, %{options: choices, selected: selected, multi_select: multi_select}}
    field(builder, name, rect, field_options, kind)
  end

  @doc """
  Adds a push button labeled `caption` to the current page.

  `name` and `rect` are as for `text_field/4`. The button runs no action when
  pressed. See `t:push_button_opts/0` for the options.
  """
  @spec push_button(t(), String.t(), Rect.t(), String.t(), push_button_opts()) :: t()
  def push_button(%__MODULE__{} = builder, name, %Rect{} = rect, caption, opts \\ [])
      when is_binary(name) and is_binary(caption) and is_list(opts) do
    caption = LayoutOptions.win_ansi!("caption", caption)
    options = build_push_button_options(opts)

    field(builder, name, rect, Map.put(options, :required, false), {:push_button, caption})
  end

  @doc """
  Adds an empty signature field to the current page.

  `name` and `rect` are as for `text_field/4`. The field holds no signature,
  and `PdfElixide.Signature.unsigned_fields/1` reports it. This library cannot
  sign it; see [Form fields](guides/building-documents.md#form-fields). See
  `t:signature_field_opts/0` for the options.
  """
  @spec signature_field(t(), String.t(), Rect.t(), signature_field_opts()) :: t()
  def signature_field(%__MODULE__{} = builder, name, %Rect{} = rect, opts \\ [])
      when is_binary(name) and is_list(opts) do
    options = build_signature_field_options(opts)

    field(builder, name, rect, Map.put(options, :required, false), :signature)
  end

  defp field(builder, name, rect, options, kind) do
    name = field_name!(builder, name)
    %Rect{x: x, y: y, width: width, height: height} = field_rect!(builder, rect)

    op =
      {:field,
       Map.merge(options, %{
         name: name,
         x: x,
         y: y,
         width: width,
         height: height,
         kind: kind
       })}

    %{builder | field_names: MapSet.put(builder.field_names, name), ops: [op | builder.ops]}
  end

  defp field_name!(builder, name) do
    name = LayoutOptions.field_text!("name", name)

    cond do
      name == "" ->
        raise ArgumentError, "invalid name, a form field's name cannot be empty"

      String.contains?(name, ".") ->
        raise ArgumentError,
              "invalid name, a \".\" separates the parts of a nested field's name, which " <>
                "the builder does not create: #{inspect(name)}"

      MapSet.member?(builder.field_names, name) ->
        raise ArgumentError,
              "invalid name, a form field named #{inspect(name)} already exists; give " <>
                "each field its own name"

      true ->
        name
    end
  end

  defp field_rect!(builder, rect) do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()
    width = LayoutOptions.positive!("rect", width)
    height = LayoutOptions.positive!("rect", height)
    {page_width, page_height} = builder.current_page_size

    if x < 0 or y < 0 or x + width > page_width or y + height > page_height do
      raise ArgumentError,
            "invalid rect, a form field must lie on the #{page_width} × #{page_height} " <>
              "page: #{inspect(rect)}"
    end

    if collapses?(x, width) or collapses?(y, height) do
      raise ArgumentError,
            "invalid rect, its width or height is under 0.00001 points once written at " <>
              "this position; move the field nearer the page's origin or enlarge it: " <>
              inspect(rect)
    end

    %Rect{x: x, y: y, width: width, height: height}
  end

  defp list_selection!(nil, _multi_select, _choices), do: []

  defp list_selection!(values, true, choices) when is_list(values) do
    if not Enum.all?(values, &is_binary/1) do
      raise ArgumentError,
            "invalid :selected, expected a list of option strings: #{inspect(values)}"
    end

    Enum.each(values, &selected!(&1, choices))

    if Enum.uniq(values) != values do
      raise ArgumentError,
            "invalid :selected, each option can be selected once: #{inspect(values)}"
    end

    values
  end

  defp list_selection!(values, false, _choices) when is_list(values) do
    raise ArgumentError,
          "invalid :selected, a list selects several options, which needs " <>
            "multi_select: true: #{inspect(values)}"
  end

  defp list_selection!(value, false, choices), do: [selected!(value, choices)]

  defp list_selection!(value, true, _choices) do
    raise ArgumentError,
          "invalid :selected, expected a list of options with multi_select: true: " <>
            inspect(value)
  end

  # The writer adds each size to its corner in 32-bit floats and writes five
  # decimal places, so a smaller extent rounds to nothing.
  defp collapses?(origin, size) do
    start = LayoutOptions.to_f32(origin)
    LayoutOptions.to_f32(start + LayoutOptions.to_f32(size)) - start < 1.0e-5
  end

  defp choices!([_ | _] = options) do
    options = Enum.map(options, &choice!/1)

    if Enum.uniq(options) != options do
      raise ArgumentError, "invalid options, each option must be distinct: #{inspect(options)}"
    end

    options
  end

  defp choices!([]),
    do: raise(ArgumentError, "invalid options, a choice field needs at least one")

  defp choice!(option) when is_binary(option), do: LayoutOptions.win_ansi!("options", option)

  defp choice!(option) do
    raise ArgumentError, "invalid options, expected a list of strings: #{inspect(option)}"
  end

  defp selected!(nil, _choices), do: nil

  defp selected!(value, choices) when is_binary(value) do
    if value not in choices do
      raise ArgumentError,
            "invalid :selected, expected one of the field's options #{inspect(choices)}: " <>
              inspect(value)
    end

    value
  end

  defp selected!(value, _choices) do
    raise ArgumentError, "invalid :selected, expected an option string: #{inspect(value)}"
  end

  @doc """
  Draws a rectangle on the current page.

  `rect` is a `PdfElixide.Geometry.Rect` in points from the page's
  bottom-left corner, such as the `bbox` of an extracted word, span or path;
  reversed corners are normalized. See
  [Drawing shapes](guides/building-documents.md#drawing-shapes) for where an
  extracted box lands, and `t:shape_opts/0` for the options.

      alias PdfElixide.{Color.RGB, Geometry.Rect}

      PdfElixide.Builder.rect(
        builder,
        %Rect{x: 72.0, y: 600.0, width: 468.0, height: 100.0},
        fill_color: %RGB{r: 0.9, g: 0.9, b: 0.9},
        stroke_color: nil
      )
  """
  @spec rect(t(), Rect.t(), shape_opts()) :: t()
  def rect(%__MODULE__{} = builder, %Rect{} = rect, opts \\ []) when is_list(opts) do
    %Rect{x: x, y: y, width: width, height: height} = rect |> rect!() |> normalize_rect()

    shape(builder, [{:rectangle, x, y, width, height}], build_shape_options(opts))
  end

  @doc """
  Draws a straight line from one `t:point/0` to another on the current page.

  See [Drawing shapes](guides/building-documents.md#drawing-shapes) and
  `t:line_opts/0` for the options.

      PdfElixide.Builder.line(builder, {72, 580}, {540, 580}, dash_pattern: {[3, 2], 0})
  """
  @spec line(t(), point(), point(), line_opts()) :: t()
  def line(%__MODULE__{} = builder, from, to, opts \\ [])
      when is_point(from) and is_point(to) and is_list(opts) do
    from = LayoutOptions.point!("from", from)
    to = LayoutOptions.point!("to", to)

    shape(builder, [move_to(from), line_to(to)], build_line_options(opts))
  end

  @doc """
  Draws a circle of `radius` points around `center` on the current page.

  See [Drawing shapes](guides/building-documents.md#drawing-shapes) and
  `t:shape_opts/0` for the options.

      PdfElixide.Builder.circle(builder, {306, 396}, 50, stroke_width: 2)
  """
  @spec circle(t(), point(), number(), shape_opts()) :: t()
  def circle(%__MODULE__{} = builder, center, radius, opts \\ [])
      when is_point(center) and is_number(radius) and is_list(opts) do
    center = LayoutOptions.point!("center", center)
    radius = LayoutOptions.positive!("radius", radius)
    operations = ellipse_operations(center, radius, radius)

    reach!(operations, "radius", radius, center)
    shape(builder, operations, build_shape_options(opts))
  end

  @doc """
  Draws an ellipse around `center` on the current page, `{rx, ry}` being its
  horizontal and vertical radii in points.

  See [Drawing shapes](guides/building-documents.md#drawing-shapes) and
  `t:shape_opts/0` for the options.

      PdfElixide.Builder.ellipse(builder, {306, 396}, {80, 40})
  """
  @spec ellipse(t(), point(), {number(), number()}, shape_opts()) :: t()
  def ellipse(%__MODULE__{} = builder, center, {rx, ry}, opts \\ [])
      when is_point(center) and is_number(rx) and is_number(ry) and is_list(opts) do
    center = LayoutOptions.point!("center", center)
    radii = {LayoutOptions.positive!("radii", rx), LayoutOptions.positive!("radii", ry)}
    operations = ellipse_operations(center, elem(radii, 0), elem(radii, 1))

    reach!(operations, "radii", radii, center)
    shape(builder, operations, build_shape_options(opts))
  end

  @doc """
  Draws a closed polygon through `points`, at least three `t:point/0`s, on the
  current page.

  See [Drawing shapes](guides/building-documents.md#drawing-shapes) for filling
  behavior and `t:shape_opts/0` for the options.

      PdfElixide.Builder.polygon(builder, [{100, 100}, {200, 100}, {150, 180}])
  """
  @spec polygon(t(), [point()], shape_opts()) :: t()
  def polygon(%__MODULE__{} = builder, points, opts \\ [])
      when is_list(points) and is_list(opts) do
    if not match?([_, _, _ | _], points) do
      raise ArgumentError, "invalid points, expected at least three points: #{inspect(points)}"
    end

    [first | rest] = Enum.map(points, &polygon_point!/1)
    operations = [move_to(first) | Enum.map(rest, &line_to/1)] ++ [:close_path]

    shape(builder, operations, build_shape_options(opts))
  end

  defp polygon_point!(point) when is_point(point), do: LayoutOptions.point!("points", point)

  defp polygon_point!(point) do
    raise ArgumentError, "invalid point, expected {x, y} with two numbers: #{inspect(point)}"
  end

  @doc """
  Draws an arc of a circle of `radius` points around `center` on the current
  page, from angle `from` to angle `to`.

  Angles are in degrees, counter-clockwise from the positive x-axis, so `0` is
  the circle's rightmost point and `90` its top. A `to` below `from` draws
  clockwise. The arc may go round at most once: `from` and `to` must differ,
  by no more than 360. See
  [Drawing shapes](guides/building-documents.md#drawing-shapes) and
  `t:line_opts/0` for the options.

      PdfElixide.Builder.arc(builder, {306, 396}, 50, 0, 90)
  """
  @spec arc(t(), point(), number(), number(), number(), line_opts()) :: t()
  def arc(%__MODULE__{} = builder, center, radius, from, to, opts \\ [])
      when is_point(center) and is_number(radius) and is_number(from) and is_number(to) and
             is_list(opts) do
    center = LayoutOptions.point!("center", center)
    radius = LayoutOptions.positive!("radius", radius)
    sweep = to - from

    if sweep == 0 or abs(sweep) > 360 do
      raise ArgumentError,
            "invalid angles, an arc sweeps more than 0 and at most 360 degrees: " <>
              "from #{inspect(from)} to #{inspect(to)}"
    end

    operations = arc_operations(center, radius, from, sweep)

    reach!(operations, "radius", radius, center)
    shape(builder, operations, build_line_options(opts))
  end

  @doc """
  Draws a cubic Bézier curve from `from` to `to`, shaped by the control points
  `c1` and `c2`, on the current page.

  All four are `t:point/0`s. See
  [Drawing shapes](guides/building-documents.md#drawing-shapes) and
  `t:line_opts/0` for the options.

      PdfElixide.Builder.bezier(builder, {72, 300}, {150, 400}, {250, 200}, {340, 300})
  """
  @spec bezier(t(), point(), point(), point(), point(), line_opts()) :: t()
  def bezier(%__MODULE__{} = builder, from, c1, c2, to, opts \\ [])
      when is_point(from) and is_point(c1) and is_point(c2) and is_point(to) and is_list(opts) do
    from = LayoutOptions.point!("from", from)
    {c1x, c1y} = LayoutOptions.point!("c1", c1)
    {c2x, c2y} = LayoutOptions.point!("c2", c2)
    {x, y} = LayoutOptions.point!("to", to)

    shape(
      builder,
      [move_to(from), {:curve_to, c1x, c1y, c2x, c2y, x, y}],
      build_line_options(opts)
    )
  end

  @doc """
  Draws a path made of `operations` on the current page.

  `operations` are `t:path_operation/0` tuples, the form
  `PdfElixide.Document.paths/1` returns, so an extracted path can be drawn
  again. The first must be `{:move_to, x, y}` or `{:rectangle, x, y, width,
  height}`, which give the operations after it a point to start from.
  Coordinates are in points from the page's bottom-left corner. See
  [Drawing shapes](guides/building-documents.md#drawing-shapes) for filling
  behavior and `t:shape_opts/0` for the options.

      PdfElixide.Builder.path(builder, [
        {:move_to, 100, 100},
        {:line_to, 200, 100},
        {:curve_to, 250, 100, 250, 200, 200, 200},
        :close_path
      ])
  """
  @spec path(t(), [path_operation()], shape_opts()) :: t()
  def path(%__MODULE__{} = builder, operations, opts \\ [])
      when is_list(operations) and is_list(opts) do
    Enum.each(operations, &operation!/1)
    Enum.each(operations, &operation_in_range!/1)

    case operations do
      [{:move_to, _, _} | _] ->
        :ok

      [{:rectangle, _, _, _, _} | _] ->
        :ok

      _ ->
        raise ArgumentError,
              "invalid operations, a path must start with :move_to or :rectangle: " <>
                inspect(operations)
    end

    shape(builder, operations, build_shape_options(opts))
  end

  defp shape(builder, operations, options) do
    operations = Enum.map(operations, &floats/1)
    op = {:path, Map.put(options, :operations, operations)}
    %{builder | ops: [op | builder.ops]}
  end

  # The native side reads an integer only within 64 bits, short of the 32-bit
  # float range the coordinates were checked against.
  defp floats(:close_path), do: :close_path

  defp floats(operation) do
    [tag | values] = Tuple.to_list(operation)
    List.to_tuple([tag | Enum.map(values, &(&1 * 1.0))])
  end

  defp move_to({x, y}), do: {:move_to, x, y}
  defp line_to({x, y}), do: {:line_to, x, y}

  defp ellipse_operations({cx, cy}, rx, ry) do
    {kx, ky} = {rx * @kappa, ry * @kappa}

    [
      {:move_to, cx, cy + ry},
      {:curve_to, cx + kx, cy + ry, cx + rx, cy + ky, cx + rx, cy},
      {:curve_to, cx + rx, cy - ky, cx + kx, cy - ry, cx, cy - ry},
      {:curve_to, cx - kx, cy - ry, cx - rx, cy - ky, cx - rx, cy},
      {:curve_to, cx - rx, cy + ky, cx - kx, cy + ry, cx, cy + ry},
      :close_path
    ]
  end

  # Reduce the start to one turn so a large angle cannot absorb the sweep.
  defp arc_operations({cx, cy}, radius, from, sweep) do
    segments = trunc(Float.ceil(abs(sweep) / 90))
    step = sweep / segments * :math.pi() / 180
    start = one_turn(from) * :math.pi() / 180
    k = 4 / 3 * :math.tan(step / 4) * radius
    at = fn angle -> {cx + radius * :math.cos(angle), cy + radius * :math.sin(angle)} end

    curves =
      for i <- 0..(segments - 1) do
        a = start + i * step
        b = a + step
        {ax, ay} = at.(a)
        {bx, by} = at.(b)

        {:curve_to, ax - k * :math.sin(a), ay + k * :math.cos(a), bx + k * :math.sin(b),
         by - k * :math.cos(b), bx, by}
      end

    [move_to(at.(start)) | curves]
  end

  defp one_turn(degrees) when is_integer(degrees), do: rem(degrees, 360)
  defp one_turn(degrees), do: :math.fmod(degrees, 360.0)

  defp operation!({:move_to, x, y}) when is_number(x) and is_number(y), do: :ok
  defp operation!({:line_to, x, y}) when is_number(x) and is_number(y), do: :ok

  defp operation!({:curve_to, c1x, c1y, c2x, c2y, x, y})
       when is_number(c1x) and is_number(c1y) and is_number(c2x) and is_number(c2y) and
              is_number(x) and is_number(y),
       do: :ok

  defp operation!({:rectangle, x, y, width, height})
       when is_number(x) and is_number(y) and is_number(width) and is_number(height),
       do: :ok

  defp operation!(:close_path), do: :ok

  defp operation!(other) do
    raise ArgumentError,
          "invalid operation, expected a PdfElixide.Document.Path operation: " <>
            inspect(other)
  end

  # A rectangle's size is written too, and two corners that fit can be further
  # apart than a width can hold.
  defp operation_in_range!(op) do
    values =
      case op do
        {:rectangle, x, y, width, height} -> [x, y, width, height, x + width, y + height]
        :close_path -> []
        _ -> op |> Tuple.to_list() |> tl()
      end

    if not Enum.all?(values, &LayoutOptions.fits_f32?/1) do
      raise ArgumentError,
            "invalid operation, expected coordinates that fit a 32-bit float: #{inspect(op)}"
    end
  end

  # Arguments that fit can still reach past the range once the curve is laid
  # around them.
  defp reach!(operations, label, value, center) do
    values = for op <- operations, op != :close_path, value <- tl(Tuple.to_list(op)), do: value

    if not Enum.all?(values, &LayoutOptions.fits_f32?/1) do
      raise ArgumentError,
            "invalid #{label}, the shape around center #{inspect(center)} reaches past " <>
              "the 32-bit float range: #{inspect(value)}"
    end
  end

  defp rect!(%Rect{x: x, y: y, width: width, height: height} = rect)
       when is_number(x) and is_number(y) and is_number(width) and is_number(height) do
    LayoutOptions.rect!("rect", rect)
  end

  defp rect!(rect) do
    raise ArgumentError, "invalid rect, expected numbers in every field: #{inspect(rect)}"
  end

  defp normalize_rect(%Rect{x: x, y: y, width: width, height: height} = rect) do
    {x, width} = if width < 0, do: {x + width, -width}, else: {x, width}
    {y, height} = if height < 0, do: {y + height, -height}, else: {y, height}
    %{rect | x: x, y: y, width: width, height: height}
  end

  @doc """
  Lays out the description and returns the PDF as a binary.

  See `t:output_opts/0` for the options and
  [Errors](#module-errors) for what is refused.
  """
  @spec to_binary(t(), output_opts()) :: {:ok, binary()} | {:error, Error.t()}
  def to_binary(%__MODULE__{} = builder, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, @output_opts_keys)

    with_editor(builder, &Editor.to_binary(&1, opts))
  end

  @doc """
  Lays out the description and returns the PDF as a binary, raising an error
  if it fails.
  """
  @spec to_binary!(t(), output_opts()) :: binary()
  def to_binary!(%__MODULE__{} = builder, opts \\ []) when is_list(opts) do
    to_binary(builder, opts) |> Wrap.unwrap!()
  end

  @doc """
  Lays out the description and writes the PDF to `path`.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`. See `t:output_opts/0` for the options and
  [Errors](#module-errors) for what is refused.
  """
  @spec save(t(), Path.t(), output_opts()) :: :ok | {:error, Error.t()}
  def save(%__MODULE__{} = builder, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    opts = Keyword.validate!(opts, @output_opts_keys)

    case with_editor(builder, &Editor.save(&1, path, opts)) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Lays out the description and writes the PDF to `path`, raising an error if
  it fails.
  """
  @spec save!(t(), Path.t(), output_opts()) :: :ok
  def save!(%__MODULE__{} = builder, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    case save(builder, path, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  defp with_editor(builder, fun) do
    with {:ok, editor} <- Editor.from_builder(builder) do
      try do
        fun.(editor)
      after
        Editor.close(editor)
      end
    end
  end

  # Each family's bytes cross to the native side once, however many paragraphs
  # use it, and so does each distinct image; an op names either by its position
  # in `:families` or `:images`.
  @doc false
  @spec __native__(t()) :: map()
  def __native__(%__MODULE__{} = builder) do
    {ops, %{families: {families, _}, images: {images, _}}} =
      builder.ops
      |> Enum.reverse()
      |> Enum.map_reduce(%{families: {[], %{}}, images: {[], %{}}}, &native_op/2)

    faces = fn family -> Map.take(family, [:regular, :bold, :italic, :bold_italic]) end

    builder
    |> Map.take([
      :title,
      :author,
      :subject,
      :creator,
      :page_size,
      :margin_top,
      :margin_bottom,
      :margin_left,
      :margin_right,
      :line_height
    ])
    |> Map.merge(%{
      ops: ops,
      families: families |> Enum.reverse() |> Enum.map(faces),
      images: Enum.reverse(images)
    })
  end

  defp native_op({tag, %{font: %FontFamily{id: id} = family} = block}, acc) do
    {position, families} = position(acc.families, id, family)

    {{tag, %{block | font: {:family, position}}}, %{acc | families: families}}
  end

  defp native_op(
         {tag,
          %{barcode: %{caption: %{font: %FontFamily{id: id} = family} = caption} = symbol} = block},
         acc
       ) do
    {position, families} = position(acc.families, id, family)
    symbol = %{symbol | caption: %{caption | font: {:family, position}}}

    {{tag, %{block | barcode: symbol}}, %{acc | families: families}}
  end

  defp native_op({tag, %{image: image} = block}, acc) when tag in [:image, :image_in_rect] do
    {position, images} = position(acc.images, image, image)

    {{tag, %{block | image: position}}, %{acc | images: images}}
  end

  defp native_op(op, acc), do: {op, acc}

  defp position({values, index} = seen, key, value) do
    case Map.fetch(index, key) do
      {:ok, position} -> {position, seen}
      :error -> {map_size(index), {[value | values], Map.put(index, key, map_size(index))}}
    end
  end

  @doc false
  @spec __option_defaults__(
          :new
          | :paragraph
          | :heading
          | :shape
          | :line
          | :numbered_list
          | :run
          | :text_in_rect
          | :table
          | :cell
          | :image
          | :image_in_rect
          | :barcode
          | :barcode_in_rect
          | :qr_code
          | :qr_code_in_rect
          | :watermark
          | :text_field
          | :check_box
          | :combo_box
          | :list_box
          | :push_button
          | :signature_field
        ) :: map()
  def __option_defaults__(:new), do: build_new_options([])
  def __option_defaults__(:paragraph), do: build_paragraph_options([])
  def __option_defaults__(:heading), do: build_heading_options([])
  def __option_defaults__(:shape), do: build_shape_options([])
  def __option_defaults__(:line), do: build_line_options([])
  def __option_defaults__(:numbered_list), do: build_numbered_list_options([])
  def __option_defaults__(:run), do: build_run_options([])
  def __option_defaults__(:text_in_rect), do: build_text_in_rect_options([])
  def __option_defaults__(:table), do: build_table_options([])
  def __option_defaults__(:cell), do: build_cell_options([])
  def __option_defaults__(:image), do: build_image_options([])
  def __option_defaults__(:image_in_rect), do: build_image_in_rect_options([])
  def __option_defaults__(:barcode), do: build_barcode_options([])
  def __option_defaults__(:barcode_in_rect), do: build_barcode_in_rect_options([])
  def __option_defaults__(:qr_code), do: build_qr_code_options([])
  def __option_defaults__(:qr_code_in_rect), do: build_qr_code_in_rect_options([])
  def __option_defaults__(:watermark), do: build_watermark_options([])
  def __option_defaults__(:text_field), do: build_text_field_options([])
  def __option_defaults__(:check_box), do: build_check_box_options([])
  def __option_defaults__(:combo_box), do: build_combo_box_options([])
  def __option_defaults__(:list_box), do: build_list_box_options([])
  def __option_defaults__(:push_button), do: build_push_button_options([])
  def __option_defaults__(:signature_field), do: build_signature_field_options([])

  defp build_new_options(opts) do
    opts = Keyword.validate!(opts, @new_opts_keys)

    margins =
      Map.new([:margin_top, :margin_bottom, :margin_left, :margin_right], fn key ->
        {key, non_negative!(key, Keyword.get(opts, key, 72))}
      end)

    Map.merge(margins, %{
      title: text!(:title, Keyword.get(opts, :title)),
      author: text!(:author, Keyword.get(opts, :author)),
      subject: text!(:subject, Keyword.get(opts, :subject)),
      creator: text!(:creator, Keyword.get(opts, :creator)),
      page_size: page_size!(Keyword.get(opts, :page_size, :letter)),
      font: font!(Keyword.get(opts, :font, :auto)),
      font_size: positive!(:font_size, Keyword.get(opts, :font_size, 12)),
      line_height: positive!(:line_height, Keyword.get(opts, :line_height, 1.5))
    })
  end

  defp build_numbered_list_options(opts) do
    opts = Keyword.validate!(opts, @numbered_list_opts_keys)

    opts
    |> Keyword.take([:font, :font_size])
    |> build_paragraph_options()
    |> Map.merge(%{
      style: list_style!(Keyword.get(opts, :style, :decimal)),
      start: start!(Keyword.get(opts, :start, 1))
    })
  end

  defp build_text_in_rect_options(opts) do
    opts = Keyword.validate!(opts, @text_in_rect_opts_keys)

    opts
    |> Keyword.take([:font, :font_size])
    |> build_paragraph_options()
    |> Map.put(:align, align!(Keyword.get(opts, :align, :left)))
  end

  defp build_table_options(opts) do
    opts = Keyword.validate!(opts, @table_opts_keys)

    stroke_color =
      color!(:stroke_color, Keyword.get(opts, :stroke_color, %RGB{r: 0.0, g: 0.0, b: 0.0}))

    stroke_width =
      non_negative!(:stroke_width, Keyword.get(opts, :stroke_width, @grid_width))

    # The grid's width would be dropped with the grid.
    if stroke_color == nil and stroke_width != @grid_width do
      raise ArgumentError,
            ":stroke_width has no effect with stroke_color: nil; give one or the other"
    end

    opts
    |> Keyword.take([:font, :font_size])
    |> build_paragraph_options()
    |> Map.merge(%{
      stroke_color: stroke_color,
      stroke_width: stroke_width,
      column_widths: column_widths!(Keyword.get(opts, :column_widths)),
      align: table_align!(Keyword.get(opts, :align, :left)),
      header_rows: header_rows!(Keyword.get(opts, :header_rows, 0)),
      header_fill: color!(:header_fill, Keyword.get(opts, :header_fill)),
      padding: non_negative!(:padding, Keyword.get(opts, :padding, 4))
    })
  end

  defp build_cell_options(opts) do
    opts = Keyword.validate!(opts, @cell_opts_keys)

    align =
      case Keyword.get(opts, :align) do
        nil -> nil
        align -> align!(align)
      end

    %{
      colspan: span_count!(:colspan, Keyword.get(opts, :colspan, 1)),
      rowspan: span_count!(:rowspan, Keyword.get(opts, :rowspan, 1)),
      align: align,
      fill_color: color!(:fill_color, Keyword.get(opts, :fill_color))
    }
  end

  defp build_image_options(opts) do
    opts = Keyword.validate!(opts, @image_opts_keys)
    width = optional_positive!(:width, Keyword.get(opts, :width))
    height = optional_positive!(:height, Keyword.get(opts, :height))
    fit = fit!(Keyword.get(opts, :fit, :contain))

    if fit != :contain and (width == nil or height == nil) do
      raise ArgumentError,
            "invalid :fit, it has no effect unless both :width and :height are given"
    end

    %{width: width, height: height, fit: fit, align: align!(Keyword.get(opts, :align, :left))}
  end

  defp build_barcode_in_rect_options(opts) do
    opts = Keyword.validate!(opts, @barcode_in_rect_opts_keys)

    opts
    |> Keyword.take([:font, :font_size])
    |> build_paragraph_options()
    |> Map.merge(symbol_options(opts, 10))
    |> Map.put(:text, boolean!(:text, Keyword.get(opts, :text, false)))
  end

  defp build_barcode_options(opts) do
    opts = Keyword.validate!(opts, @barcode_opts_keys)

    opts
    |> Keyword.take(@barcode_in_rect_opts_keys)
    |> build_barcode_in_rect_options()
    |> Map.merge(%{
      width: optional_positive!(:width, Keyword.get(opts, :width)),
      height: optional_positive!(:height, Keyword.get(opts, :height)),
      align: align!(Keyword.get(opts, :align, :left))
    })
  end

  defp build_qr_code_in_rect_options(opts) do
    opts = Keyword.validate!(opts, @qr_code_in_rect_opts_keys)

    opts
    |> symbol_options(4)
    |> Map.put(
      :error_correction,
      error_correction!(Keyword.get(opts, :error_correction, :medium))
    )
  end

  defp build_qr_code_options(opts) do
    opts = Keyword.validate!(opts, @qr_code_opts_keys)

    opts
    |> Keyword.take(@qr_code_in_rect_opts_keys)
    |> build_qr_code_in_rect_options()
    |> Map.merge(%{
      size: optional_positive!(:size, Keyword.get(opts, :size)),
      align: align!(Keyword.get(opts, :align, :left))
    })
  end

  defp symbol_options(opts, quiet_zone) do
    color =
      case color!(:color, Keyword.get(opts, :color, %RGB{r: 0.0, g: 0.0, b: 0.0})) do
        nil -> raise ArgumentError, "invalid :color, a barcode needs one, so it cannot be nil"
        color -> color
      end

    %{
      color: color,
      background: color!(:background, Keyword.get(opts, :background)),
      quiet_zone: non_negative!(:quiet_zone, Keyword.get(opts, :quiet_zone, quiet_zone))
    }
  end

  defp error_correction!(level) when level in @error_corrections, do: level

  defp error_correction!(level) do
    raise ArgumentError,
          "invalid :error_correction, expected one of #{inspect(@error_corrections)}: " <>
            inspect(level)
  end

  defp build_image_in_rect_options(opts) do
    opts = Keyword.validate!(opts, @image_in_rect_opts_keys)

    %{fit: fit!(Keyword.get(opts, :fit, :contain))}
  end

  defp build_run_options(opts) do
    opts = Keyword.validate!(opts, @run_opts_keys)

    %{
      bold: boolean!(:bold, Keyword.get(opts, :bold, false)),
      italic: boolean!(:italic, Keyword.get(opts, :italic, false)),
      color: color!(:color, Keyword.get(opts, :color)),
      link:
        case Keyword.get(opts, :link) do
          nil -> nil
          link -> link!(link)
        end
    }
  end

  defp build_watermark_options(opts) do
    opts = Keyword.validate!(opts, @watermark_opts_keys)

    center =
      case Keyword.get(opts, :center) do
        nil ->
          nil

        {x, y} = center when is_number(x) and is_number(y) ->
          if not (LayoutOptions.writable?(x) and LayoutOptions.writable?(y)) do
            raise ArgumentError,
                  "invalid :center, expected coordinates of at most " <>
                    "#{LayoutOptions.max_written()} points: #{inspect(center)}"
          end

          {x * 1.0, y * 1.0}

        other ->
          raise ArgumentError, "invalid :center, expected {x, y} or nil: #{inspect(other)}"
      end

    color =
      case color!(:color, Keyword.get(opts, :color, %RGB{r: 0.5, g: 0.5, b: 0.5})) do
        nil -> raise ArgumentError, "invalid :color, a watermark needs one, so it cannot be nil"
        color -> color
      end

    %{
      pages: watermark_pages!(Keyword.get(opts, :pages, :current)),
      center: center,
      rotation: rotation!(Keyword.get(opts, :rotation, 45)),
      font: watermark_font!(Keyword.get(opts, :font, :helvetica)),
      bold: boolean!(:bold, Keyword.get(opts, :bold, false)),
      font_size: positive!(:font_size, Keyword.get(opts, :font_size, 72)),
      color: color,
      opacity: opacity!(Keyword.get(opts, :opacity, 0.3))
    }
  end

  defp build_text_field_options(opts) do
    opts = Keyword.validate!(opts, @text_field_opts_keys)

    opts
    |> field_options()
    |> Map.merge(%{
      value: field_text!(:value, Keyword.get(opts, :value)),
      default_value: field_text!(:default_value, Keyword.get(opts, :default_value))
    })
  end

  defp build_check_box_options(opts) do
    opts = Keyword.validate!(opts, @check_box_opts_keys)

    opts
    |> field_options()
    |> Map.put(:checked, boolean!(:checked, Keyword.get(opts, :checked, false)))
  end

  defp build_combo_box_options(opts) do
    opts = Keyword.validate!(opts, @combo_box_opts_keys)

    opts |> field_options() |> Map.put(:selected, Keyword.get(opts, :selected))
  end

  defp build_list_box_options(opts) do
    opts = Keyword.validate!(opts, @list_box_opts_keys)

    opts
    |> field_options()
    |> Map.merge(%{
      multi_select: boolean!(:multi_select, Keyword.get(opts, :multi_select, false)),
      selected: Keyword.get(opts, :selected)
    })
  end

  defp build_push_button_options(opts) do
    opts |> Keyword.validate!(@push_button_opts_keys) |> field_options() |> Map.delete(:required)
  end

  defp build_signature_field_options(opts) do
    opts
    |> Keyword.validate!(@signature_field_opts_keys)
    |> field_options()
    |> Map.delete(:required)
  end

  defp field_options(opts) do
    %{
      required: boolean!(:required, Keyword.get(opts, :required, false)),
      read_only: boolean!(:read_only, Keyword.get(opts, :read_only, false)),
      tooltip: tooltip!(Keyword.get(opts, :tooltip))
    }
  end

  defp tooltip!(nil), do: nil
  defp tooltip!(tooltip) when is_binary(tooltip), do: LayoutOptions.field_text!(:tooltip, tooltip)

  defp tooltip!(tooltip) do
    raise ArgumentError, "invalid :tooltip, expected a string or nil: #{inspect(tooltip)}"
  end

  defp field_text!(_key, nil), do: nil
  defp field_text!(key, value) when is_binary(value), do: LayoutOptions.win_ansi!(key, value)

  defp field_text!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a string or nil: #{inspect(value)}"
  end

  defp watermark_pages!(pages) when pages in @watermark_pages, do: pages

  defp watermark_pages!(pages) do
    raise ArgumentError,
          "invalid :pages, expected one of #{inspect(@watermark_pages)}: #{inspect(pages)}"
  end

  defp watermark_font!(font) when font in @watermark_fonts, do: font

  defp watermark_font!(font) do
    raise ArgumentError,
          "invalid :font, expected one of #{inspect(@watermark_fonts)}: #{inspect(font)}"
  end

  defp rotation!(degrees) when is_number(degrees) do
    if not LayoutOptions.fits_f32?(degrees) do
      raise ArgumentError,
            "invalid :rotation, expected a number that fits a 32-bit float: #{inspect(degrees)}"
    end

    one_turn(degrees) * 1.0
  end

  defp rotation!(other) do
    raise ArgumentError, "invalid :rotation, expected a number of degrees: #{inspect(other)}"
  end

  defp opacity!(opacity) when is_number(opacity) and opacity > 0 and opacity <= 1,
    do: opacity * 1.0

  defp opacity!(other) do
    raise ArgumentError,
          "invalid :opacity, expected a number greater than 0 and at most 1: #{inspect(other)}"
  end

  defp link!(uri) when is_binary(uri) do
    if not (uri =~ ~r/\A[\x21-\x7E]+\z/) do
      raise ArgumentError,
            "invalid :link, expected a URI of printable ASCII characters with no spaces; " <>
              "encode any other character first, for example with URI.encode/1: " <>
              inspect(uri)
    end

    if String.starts_with?(String.downcase(uri), @script_schemes) do
      raise ArgumentError,
            "invalid :link, a #{uri |> String.split(":") |> hd()}: URI runs a script, " <>
              "which the builder does not write: #{inspect(uri)}"
    end

    {:uri, uri}
  end

  defp link!({:page, page}) when is_integer(page) and page >= 0 and page <= @max_list_number,
    do: {:page, page}

  defp link!({:anchor, name}) when is_binary(name), do: {:anchor, anchor_name!(":link", name)}

  defp link!(other) do
    raise ArgumentError,
          "invalid :link, expected a URI string, {:page, index} with an index from 0 to " <>
            "#{@max_list_number}, or {:anchor, name}: #{inspect(other)}"
  end

  defp anchor_name!(label, name) do
    name = LayoutOptions.utf8!(label, name)

    if name == "" do
      raise ArgumentError, "invalid #{label}, an anchor name cannot be empty"
    end

    name
  end

  defp build_heading_options(opts) do
    opts |> Keyword.validate!(@heading_opts_keys) |> build_paragraph_options()
  end

  defp build_paragraph_options(opts) do
    opts = Keyword.validate!(opts, @paragraph_opts_keys)

    font =
      case Keyword.get(opts, :font) do
        nil -> nil
        font -> font!(font)
      end

    %{font: font, font_size: optional_positive!(:font_size, Keyword.get(opts, :font_size))}
  end

  defp build_shape_options(opts) do
    opts = Keyword.validate!(opts, @shape_opts_keys)
    options = paint_options(opts, fill_color: color!(:fill_color, Keyword.get(opts, :fill_color)))

    if options.stroke_color == nil and options.fill_color == nil do
      raise ArgumentError,
            "invalid :stroke_color, a shape with no :fill_color needs an outline, " <>
              "so it cannot be nil"
    end

    options
  end

  defp build_line_options(opts) do
    opts = Keyword.validate!(opts, @line_opts_keys)
    options = paint_options(opts, fill_color: nil)

    if options.stroke_color == nil do
      raise ArgumentError, "invalid :stroke_color, a line needs one, so it cannot be nil"
    end

    options
  end

  defp paint_options(opts, extra) do
    options =
      Map.new(extra)
      |> Map.merge(%{
        stroke_color:
          color!(:stroke_color, Keyword.get(opts, :stroke_color, %RGB{r: 0.0, g: 0.0, b: 0.0})),
        stroke_width: non_negative!(:stroke_width, Keyword.get(opts, :stroke_width, 1)),
        dash_pattern: dash_pattern!(Keyword.get(opts, :dash_pattern))
      })

    # The outline's settings would be dropped with the outline.
    if options.stroke_color == nil do
      defaults = paint_options([], [])

      for key <- [:stroke_width, :dash_pattern], options[key] != defaults[key] do
        raise ArgumentError,
              "#{inspect(key)} has no effect with stroke_color: nil; give one or the other"
      end
    end

    options
  end

  defp dash_pattern!(nil), do: nil

  defp dash_pattern!({[_ | _] = lengths, phase}) do
    {Enum.map(lengths, &positive!(:dash_pattern, &1)), non_negative!(:dash_pattern, phase)}
  end

  defp dash_pattern!(other) do
    raise ArgumentError,
          "invalid :dash_pattern, expected {lengths, phase} with a non-empty list of " <>
            "lengths: #{inspect(other)}"
  end

  defp font!(%FontFamily{} = family), do: family
  defp font!(font) when font in @fonts, do: font

  defp font!(font) do
    raise ArgumentError,
          "invalid :font, expected one of #{inspect(@fonts)} or a " <>
            "PdfElixide.Builder.FontFamily: #{inspect(font)}"
  end

  defp item!(text) when is_binary(text) or is_list(text), do: runs!(text)

  defp item!(other) do
    raise ArgumentError, "invalid item, expected a string or a list of runs: #{inspect(other)}"
  end

  defp list_style!(style) when style in @list_styles, do: style

  defp list_style!(style) do
    raise ArgumentError,
          "invalid :style, expected one of #{inspect(@list_styles)}: #{inspect(style)}"
  end

  defp align!(align) when align in @aligns, do: align

  defp align!(align) do
    raise ArgumentError, "invalid :align, expected one of #{inspect(@aligns)}: #{inspect(align)}"
  end

  defp fit!(fit) when fit in @fits, do: fit

  defp fit!(fit) do
    raise ArgumentError, "invalid :fit, expected one of #{inspect(@fits)}: #{inspect(fit)}"
  end

  defp start!(start) when is_integer(start) and start >= 1, do: start

  defp start!(start) do
    raise ArgumentError, "invalid :start, expected a positive integer: #{inspect(start)}"
  end

  defp span_count!(_key, count) when is_integer(count) and count >= 1, do: count

  defp span_count!(key, count) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a positive integer: #{inspect(count)}"
  end

  defp header_rows!(count) when is_integer(count) and count >= 0, do: count

  defp header_rows!(count) do
    raise ArgumentError,
          "invalid :header_rows, expected a non-negative integer: #{inspect(count)}"
  end

  defp table_align!(aligns) when is_list(aligns), do: Enum.map(aligns, &align!/1)
  defp table_align!(align), do: align!(align)

  defp column_widths!(nil), do: nil
  defp column_widths!(widths) when is_list(widths), do: Enum.map(widths, &column_width!/1)

  defp column_widths!(other) do
    raise ArgumentError,
          "invalid :column_widths, expected a list of column widths or nil: #{inspect(other)}"
  end

  defp column_width!(:auto), do: :auto

  defp column_width!(points) when is_number(points),
    do: {:points, positive!(:column_widths, points)}

  defp column_width!({:weight, weight}) when is_number(weight),
    do: {:weight, positive!(:column_widths, weight)}

  defp column_width!(other) do
    raise ArgumentError,
          "invalid :column_widths, expected a number, {:weight, number} or :auto: " <>
            inspect(other)
  end

  defp runs!(text) when is_binary(text), do: [run!(text)]
  defp runs!(runs), do: Enum.map(runs, &run!/1)

  defp run!(text) when is_binary(text), do: run!({text, []})

  defp run!({text, opts}) when is_binary(text) and is_list(opts) do
    run = opts |> build_run_options() |> Map.put(:text, LayoutOptions.utf8!("text", text))

    if run.link != nil and String.trim(run.text) == "" do
      raise ArgumentError,
            "invalid run, a linked run needs text other than whitespace: #{inspect(text)}"
    end

    run
  end

  defp run!(other) do
    raise ArgumentError,
          "invalid run, expected a string or a {string, opts} tuple: #{inspect(other)}"
  end

  defp boolean!(_key, value) when is_boolean(value), do: value

  defp boolean!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a boolean: #{inspect(value)}"
  end

  defp color!(_key, nil), do: nil

  defp color!(key, %RGB{} = color), do: LayoutOptions.rgb!(key, color)

  defp color!(key, other) do
    raise ArgumentError,
          "invalid #{inspect(key)}, expected a PdfElixide.Color.RGB or nil: #{inspect(other)}"
  end

  defp text!(_key, nil), do: nil
  defp text!(key, value) when is_binary(value), do: LayoutOptions.text_string!(key, value)

  defp text!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a string or nil: #{inspect(value)}"
  end

  defp optional_positive!(_key, nil), do: nil
  defp optional_positive!(key, value), do: positive!(key, value)

  defp positive!(key, value) when is_number(value), do: LayoutOptions.positive!(key, value)

  defp positive!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a positive number: #{inspect(value)}"
  end

  defp non_negative!(key, value) when is_number(value),
    do: LayoutOptions.non_negative!(key, value)

  defp non_negative!(key, value) do
    raise ArgumentError,
          "invalid #{inspect(key)}, expected a non-negative number: #{inspect(value)}"
  end

  defp page_size!(size) when is_atom(size) do
    case Map.fetch(LayoutOptions.paper_sizes(), size) do
      {:ok, {width, height}} ->
        {width * 1.0, height * 1.0}

      :error ->
        raise ArgumentError,
              "invalid :page_size, expected one of " <>
                "#{inspect(Map.keys(LayoutOptions.paper_sizes()) |> Enum.sort())} " <>
                "or {width, height}: #{inspect(size)}"
    end
  end

  defp page_size!({width, height}) do
    size = {positive!(:page_size, width), positive!(:page_size, height)}

    if not Enum.all?(Tuple.to_list(size), &(not is_number(&1) or LayoutOptions.writable?(&1))) do
      raise ArgumentError,
            "invalid :page_size, expected sides of at most " <>
              "#{LayoutOptions.max_written()} points: #{inspect({width, height})}"
    end

    size
  end

  defp page_size!(size) do
    raise ArgumentError,
          "invalid :page_size, expected a paper size atom or {width, height}: #{inspect(size)}"
  end

  defp validate_page_fits!({width, height}, margins) do
    %{margin_top: top, margin_bottom: bottom, margin_left: left, margin_right: right} = margins

    if left + right >= width or top + bottom >= height do
      raise ArgumentError,
            "invalid layout, margins top #{top}, bottom #{bottom}, left #{left} and " <>
              "right #{right} leave no room on a #{width} × #{height} page"
    end

    :ok
  end

  defp validate_one_line!(runs) do
    if Enum.any?(runs, &String.contains?(&1.text, "\n")) do
      raise ArgumentError,
            "invalid text, text_at/4 draws one line, so it cannot contain \"\\n\"; " <>
              "use paragraph/3 or text_in_rect/4 for text that breaks"
    end
  end

  # Keep these fit and precision checks consistent with the native layout.
  defp validate_image_fits!(key, size, room), do: validate_fits!(key, size, room, "image")

  defp validate_block_fits!(builder, width, height, noun) do
    {page_width, page_height} = builder.current_page_size
    validate_fits!(:width, width, page_width - builder.margin_left - builder.margin_right, noun)

    validate_fits!(
      :height,
      height,
      page_height - builder.margin_top - builder.margin_bottom,
      noun
    )
  end

  defp validate_fits!(_key, nil, _room, _noun), do: :ok

  defp validate_fits!(key, size, room, noun) do
    if size > room + @fit_tolerance do
      raise ArgumentError,
            "invalid #{inspect(key)}, a #{size}-point #{noun} does not fit the " <>
              "#{room}-point content #{key}"
    end
  end

  defp validate_precise!(builder, font_size) do
    {width, height} = builder.current_page_size

    if max(width, height) > font_size * @precision_steps do
      raise ArgumentError,
            "invalid :font_size, a #{width} × #{height} page is too large to place " <>
              "#{font_size}-point text precisely; use a smaller page or larger text"
    end
  end

  defp validate_line_fits!(builder, font_size) do
    {_width, height} = builder.current_page_size
    line = font_size * builder.line_height
    room = height - builder.margin_top - builder.margin_bottom

    if line > room do
      raise ArgumentError,
            "invalid :font_size, a line #{line} points tall (font size × line height) " <>
              "does not fit the #{room}-point content height; reduce the font size, " <>
              "the line height or the margins"
    end

    validate_line_precise!(builder, font_size)
  end

  defp validate_line_fits_box!(builder, font_size, room) do
    line = font_size * builder.line_height

    if line > room + @fit_tolerance do
      raise ArgumentError,
            "invalid :font_size, a line #{line} points tall (font size × line height) " <>
              "does not fit the #{room}-point box; reduce the font size or the line " <>
              "height, or enlarge the box"
    end

    validate_line_precise!(builder, font_size)
  end

  defp validate_line_precise!(builder, font_size) do
    {width, height} = builder.current_page_size
    line = font_size * builder.line_height

    if max(width, height) > min(font_size, line) * @precision_steps do
      raise ArgumentError,
            "invalid :font_size, a #{width} × #{height} page is too large to place " <>
              "#{font_size}-point text with line height #{builder.line_height} " <>
              "precisely; use a smaller page or larger text"
    end

    :ok
  end
end
