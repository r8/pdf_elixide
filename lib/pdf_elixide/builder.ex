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

  ## Fonts

  Use a built-in family, bundled DejaVu Sans or a
  `PdfElixide.Builder.FontFamily`. The default is `:auto`. See
  [Fonts](guides/building-documents.md#fonts) for character coverage, style
  requirements and automatic font selection.

  ## Errors

  Invalid arguments raise at the call that receives them. Unsupported content
  returns `{:error, %PdfElixide.Error{reason: :unsupported}}` at build time;
  bang variants raise. See [Errors](guides/building-documents.md#errors) and
  [unsupported content](guides/building-documents.md#what-the-builder-will-not-draw).
  """

  alias PdfElixide.Builder.FontFamily
  alias PdfElixide.Color.RGB
  alias PdfElixide.Editor
  alias PdfElixide.Error
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

  `point` is a `t:point/0`. The text is placed outside the flow: it does not wrap, it may sit in the margins, and
  paragraphs, headings and lists around it neither move it nor make room for
  it. If no page has started yet, the first one starts here.

  `text` is a `t:text/0` without `\\n`; a run of whitespace is laid out as one
  space. Text extending beyond the page edge is refused when the document
  is built. See `t:text_at_opts/0` for the options.

      PdfElixide.Builder.text_at(builder, {72, 36}, "Confidential", font_size: 9)
  """
  @spec text_at(t(), point(), text(), text_at_opts()) :: t()
  def text_at(%__MODULE__{} = builder, {x, y} = point, text, opts \\ [])
      when is_number(x) and is_number(y) and (is_binary(text) or is_list(text)) and
             is_list(opts) do
    runs = runs!(text)
    validate_one_line!(runs)
    opts = Keyword.validate!(opts, @text_at_opts_keys)
    %{font: font, font_size: font_size} = build_paragraph_options(opts)
    font_size = font_size || builder.font_size
    LayoutOptions.point!("point", point)
    validate_precise!(builder, font_size)

    op =
      {:text_at,
       %{runs: runs, font: font || builder.font, font_size: font_size, x: x * 1.0, y: y * 1.0}}

    %{builder | ops: [op | builder.ops]}
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
  @spec __option_defaults__(:new | :paragraph | :heading) :: map()
  def __option_defaults__(:new), do: build_new_options([])
  def __option_defaults__(:paragraph), do: build_paragraph_options([])
  def __option_defaults__(:heading), do: build_heading_options([])

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

  defp run!(text) when is_binary(text), do: %{text: text, bold: false, italic: false, color: nil}

  defp run!({text, opts}) when is_binary(text) and is_list(opts) do
    opts = Keyword.validate!(opts, @run_opts_keys)

    %{
      text: text,
      bold: boolean!(:bold, Keyword.get(opts, :bold, false)),
      italic: boolean!(:italic, Keyword.get(opts, :italic, false)),
      color: color!(Keyword.get(opts, :color))
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

  defp color!(nil), do: nil

  defp color!(%RGB{} = color), do: LayoutOptions.rgb!(":color", color)

  defp color!(other) do
    raise ArgumentError, "invalid :color, expected a PdfElixide.Color.RGB: #{inspect(other)}"
  end

  defp text!(_key, nil), do: nil
  defp text!(_key, value) when is_binary(value), do: value

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
