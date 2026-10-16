defmodule PdfElixide.Builder do
  @moduledoc """
  Describes a new PDF as a pipeline of content, then lays it out in one call.

  Content operations return the builder for piping. Layout runs when the
  description is turned into a PDF with
  `to_binary/2` or `save/3`, or opened for further editing with
  `PdfElixide.Editor.from_builder/1`:

      PdfElixide.Builder.new(title: "Report")
      |> PdfElixide.Builder.paragraph("Revenue rose on the year.")
      |> PdfElixide.Builder.page()
      |> PdfElixide.Builder.paragraph("Appendix")
      |> PdfElixide.Builder.save!("report.pdf")

  ## Layout

  Text flows from the top margin down. Each line takes a box
  `font_size × line_height` points tall, and no box crosses a margin: a line
  that would cross the bottom margin starts a new page of the same size. Lines
  wrap at the right margin. A word wider than the line is split, and `\\n` in
  the text starts a new line. A paragraph leaves half its font size of space
  after it, which is dropped when a page break comes first.

  `page/2` starts a new page. The first content starts a page of its own, so
  calling `page/2` first does not add a blank one.

  ## Errors

  Malformed arguments raise where they are passed. Unknown options and
  invalid option values raise `ArgumentError`.

  Content that cannot be set faithfully returns
  `{:error, %PdfElixide.Error{reason: :unsupported}}` when built, with a
  message identifying the operation and refusal. Text uses Helvetica with
  Windows-1252 encoding; characters it cannot draw are refused.
  """

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
          font_size: float(),
          line_height: float(),
          current_page_size: {float(), float()},
          ops: [tuple()]
        }

  @typedoc """
  Options accepted by `new/1`.

    * `:title`, `:author`, `:subject`, `:creator` — written to the document
      information dictionary. Each defaults to `nil`, which leaves the entry
      out.
    * `:page_size` — a `t:PdfElixide.Editor.page_size/0` for every page that
      does not name its own. Defaults to `:letter`.
    * `:margin_top`, `:margin_bottom`, `:margin_left`, `:margin_right` —
      margins in points. Each defaults to `72`.
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
    :font_size,
    :line_height
  ]

  @typedoc """
  Options accepted by `paragraph/3`.

    * `:font_size` — text size in points. Defaults to `nil`, which uses the
      document's `:font_size`.

  A size whose line box is taller than the page's content area raises
  `ArgumentError`. See [Errors](#module-errors) for other failures.
  """
  @type paragraph_opts :: [font_size: number() | nil]

  @paragraph_opts_keys [:font_size]

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

  See [Layout](#module-layout) for how lines break and pages turn, and
  `t:paragraph_opts/0` for the options.
  """
  @spec paragraph(t(), String.t(), paragraph_opts()) :: t()
  def paragraph(%__MODULE__{} = builder, text, opts \\ [])
      when is_binary(text) and is_list(opts) do
    %{font_size: font_size} = build_paragraph_options(opts)
    font_size = font_size || builder.font_size
    validate_line_fits!(builder, font_size)

    op = {:paragraph, %{text: text, font_size: font_size}}
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

  @doc false
  @spec __native__(t()) :: map()
  def __native__(%__MODULE__{} = builder) do
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
    |> Map.put(:ops, Enum.reverse(builder.ops))
  end

  @doc false
  @spec __option_defaults__(:new | :paragraph) :: map()
  def __option_defaults__(:new), do: build_new_options([])
  def __option_defaults__(:paragraph), do: build_paragraph_options([])

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
      font_size: positive!(:font_size, Keyword.get(opts, :font_size, 12)),
      line_height: positive!(:line_height, Keyword.get(opts, :line_height, 1.5))
    })
  end

  defp build_paragraph_options(opts) do
    opts = Keyword.validate!(opts, @paragraph_opts_keys)

    %{font_size: optional_positive!(:font_size, Keyword.get(opts, :font_size))}
  end

  defp text!(_key, nil), do: nil
  defp text!(_key, value) when is_binary(value), do: value

  defp text!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a string or nil: #{inspect(value)}"
  end

  defp optional_positive!(_key, nil), do: nil
  defp optional_positive!(key, value), do: positive!(key, value)

  defp positive!(key, value) when is_number(value),
    do: LayoutOptions.positive!(key, value) * 1.0

  defp positive!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a positive number: #{inspect(value)}"
  end

  defp margin!(key, value) when is_number(value), do: LayoutOptions.margin!(key, value) * 1.0

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

  # Positions are written as 32-bit floats; past this many steps across a page
  # their rounding could merge neighbouring lines or runs.
  @precision_steps 131_072

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
