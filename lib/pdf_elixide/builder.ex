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

  Paragraphs, headings and lists wrap within the margins and start new pages
  as needed. `text_at/4` places text outside that flow. See
  [Flowing text](guides/building-documents.md#flowing-text) for line spacing,
  page breaks and heading placement.

  ## Drawing

  Draw shapes and paths outside the text flow. See
  [Drawing shapes](guides/building-documents.md#drawing-shapes) for positioning,
  paint options and redrawing an extracted path.

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

  Runs are joined as they are written, so a space between two runs belongs
  in one of them.
  """
  @type text :: String.t() | [String.t() | {String.t(), run_opts()}]

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
  @type run_opts :: [bold: boolean(), italic: boolean(), color: RGB.t() | nil]

  @run_opts_keys [:bold, :italic, :color]

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

  Sizes must be positive and margins non-negative, leaving room on the page.
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
  # their rounding could merge neighbouring lines or runs.
  @precision_steps 131_072

  @typedoc """
  Options accepted by `text_at/4`: `:font` and `:font_size`, as for
  `paragraph/3`.
  """
  @type text_at_opts :: [font: font() | nil, font_size: number() | nil]

  @text_at_opts_keys [:font, :font_size]

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

    struct!(__MODULE__, Map.merge(options, %{current_page_size: options.page_size, ops: []}))
  end

  @doc """
  Starts a new page, of `page_size` if given and otherwise the size of the
  page before it.

  `page_size` is a `t:PdfElixide.Editor.page_size/0`. The document's margins
  apply to every page, so they must leave room on this one.
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
    opts = Keyword.validate!(opts, @numbered_list_opts_keys)
    style = list_style!(Keyword.get(opts, :style, :decimal))
    start = start!(Keyword.get(opts, :start, 1))

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
    %{builder | ops: [{:space, margin!(:points, points)} | builder.ops]}
  end

  @doc """
  Adds a thin grey line across the page between the margins.

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
    %Rect{x: x, y: y, width: width, height: height} = rect!(rect)
    {x, width} = if width < 0, do: {x + width, -width}, else: {x, width}
    {y, height} = if height < 0, do: {y + height, -height}, else: {y, height}

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

    reach!(operations, "radius #{inspect(radius)} around center #{inspect(center)}")
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

    reach!(operations, "radii #{inspect(radii)} around center #{inspect(center)}")
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
      raise ArgumentError, "invalid points, a polygon needs at least three: #{inspect(points)}"
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

    reach!(operations, "radius #{inspect(radius)} around center #{inspect(center)}")
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
            "invalid operation #{inspect(op)}: its coordinates must fit a 32-bit float"
    end
  end

  # Arguments that fit can still reach past the range once the curve is laid
  # around them.
  defp reach!(operations, what) do
    values = for op <- operations, op != :close_path, value <- tl(Tuple.to_list(op)), do: value

    if not Enum.all?(values, &LayoutOptions.fits_f32?/1) do
      raise ArgumentError, "invalid #{what}: the shape reaches past the 32-bit float range"
    end
  end

  defp rect!(%Rect{x: x, y: y, width: width, height: height} = rect)
       when is_number(x) and is_number(y) and is_number(width) and is_number(height) do
    LayoutOptions.rect!("rect", rect)
  end

  defp rect!(rect) do
    raise ArgumentError, "invalid rect, expected numbers in every field: #{inspect(rect)}"
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
  # use it; a paragraph names it by its position in `:families`.
  @doc false
  @spec __native__(t()) :: map()
  def __native__(%__MODULE__{} = builder) do
    {ops, {families, _index}} =
      builder.ops
      |> Enum.reverse()
      |> Enum.map_reduce({[], %{}}, &native_op/2)

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
    |> Map.merge(%{ops: ops, families: families |> Enum.reverse() |> Enum.map(faces)})
  end

  defp native_op({tag, %{font: %FontFamily{id: id} = family} = block}, acc) do
    {families, index} = acc

    {position, acc} =
      case Map.fetch(index, id) do
        {:ok, position} -> {position, acc}
        :error -> {map_size(index), {[family | families], Map.put(index, id, map_size(index))}}
      end

    {{tag, %{block | font: {:family, position}}}, acc}
  end

  defp native_op(op, acc), do: {op, acc}

  @doc false
  @spec __option_defaults__(:new | :paragraph | :heading | :shape | :line) :: map()
  def __option_defaults__(:new), do: build_new_options([])
  def __option_defaults__(:paragraph), do: build_paragraph_options([])
  def __option_defaults__(:heading), do: build_heading_options([])
  def __option_defaults__(:shape), do: build_shape_options([])
  def __option_defaults__(:line), do: build_line_options([])

  defp build_new_options(opts) do
    opts = Keyword.validate!(opts, @new_opts_keys)

    margins =
      Map.new([:margin_top, :margin_bottom, :margin_left, :margin_right], fn key ->
        {key, margin!(key, Keyword.get(opts, key, 72))}
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
        stroke_width: margin!(:stroke_width, Keyword.get(opts, :stroke_width, 1)),
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
    {Enum.map(lengths, &positive!(:dash_pattern, &1)), margin!(:dash_pattern, phase)}
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

  defp start!(start) when is_integer(start) and start >= 1, do: start

  defp start!(start) do
    raise ArgumentError, "invalid :start, expected a positive integer: #{inspect(start)}"
  end

  defp runs!(text) when is_binary(text), do: [run!(text)]
  defp runs!(runs), do: Enum.map(runs, &run!/1)

  defp run!(text) when is_binary(text),
    do: %{text: LayoutOptions.utf8!("text", text), bold: false, italic: false, color: nil}

  defp run!({text, opts}) when is_binary(text) and is_list(opts) do
    opts = Keyword.validate!(opts, @run_opts_keys)

    %{
      text: LayoutOptions.utf8!("text", text),
      bold: boolean!(:bold, Keyword.get(opts, :bold, false)),
      italic: boolean!(:italic, Keyword.get(opts, :italic, false)),
      color: color!(:color, Keyword.get(opts, :color))
    }
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
  defp text!(key, value) when is_binary(value), do: LayoutOptions.utf8!(key, value)

  defp text!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a string or nil: #{inspect(value)}"
  end

  defp optional_positive!(_key, nil), do: nil
  defp optional_positive!(key, value), do: positive!(key, value)

  defp positive!(key, value) when is_number(value), do: LayoutOptions.positive!(key, value)

  defp positive!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a positive number: #{inspect(value)}"
  end

  defp margin!(key, value) when is_number(value), do: LayoutOptions.margin!(key, value)

  defp margin!(key, value) do
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

  defp page_size!({width, height}),
    do: {positive!(:page_size, width), positive!(:page_size, height)}

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
              "use paragraph/3 for text that breaks"
    end
  end

  # Spelled as the layout spells it, so both refuse the same text.
  defp validate_precise!(builder, font_size) do
    {width, height} = builder.current_page_size

    if max(width, height) > font_size * @precision_steps do
      raise ArgumentError,
            "invalid :font_size, a #{width} × #{height} page is too large to place " <>
              "#{font_size}-point text precisely; use a smaller page or larger text"
    end
  end

  # Spelled as the layout spells them, so both refuse the same lines.
  defp validate_line_fits!(builder, font_size) do
    {width, height} = builder.current_page_size
    line = font_size * builder.line_height
    room = height - builder.margin_top - builder.margin_bottom

    if line > room do
      raise ArgumentError,
            "invalid :font_size, a line #{line} points tall (font size × line height) " <>
              "does not fit the #{room}-point content height; reduce the font size, " <>
              "the line height or the margins"
    end

    if max(width, height) > min(font_size, line) * @precision_steps do
      raise ArgumentError,
            "invalid :font_size, a #{width} × #{height} page is too large to place " <>
              "#{font_size}-point text with line height #{builder.line_height} " <>
              "precisely; use a smaller page or larger text"
    end

    :ok
  end
end
