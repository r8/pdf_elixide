defmodule PdfElixide.Document.Page do
  @moduledoc """
  A handle to one page of a `PdfElixide.Document`.

  A `%Page{}` is just its document and a zero-based `:index` — it holds no
  native resource of its own, which is why there is no `Page.close/1` and why
  building one costs nothing. It stays valid exactly as long as its document
  does: closing the document makes every page handle taken from it report
  `{:error, %PdfElixide.Error{reason: :closed}}`.

  Get one from `PdfElixide.Document.page/2`, all of them from
  `PdfElixide.Document.pages/1`, or iterate the document directly — it
  implements `Enumerable` over its pages:

      for page <- doc, do: PdfElixide.Document.Page.text!(page)

  Every extractor `PdfElixide.Document` offers is available here for a single
  page, taking the same options. Working a page at a time is also the way to
  bound memory on a large document, since only one page's results are live at
  once — see the "Whole-document extraction and memory" section of
  `PdfElixide.Document`.
  """

  # `PdfElixide.Document.Path` — the vector-path struct — is deliberately left
  # unaliased: a bare `Path` alias shadows `Elixir.Path`, silently turning every
  # filesystem-path `Path.t()` in this module into the struct type.
  alias PdfElixide.Document
  alias PdfElixide.Document.Annotation
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Font
  alias PdfElixide.Document.Image
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:doc, :index]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          doc: Document.t(),
          index: non_neg_integer()
        }

  @typedoc """
  A page's clockwise display rotation in degrees — always one of these four.
  """
  @type rotation :: 0 | 90 | 180 | 270

  @doc """
  Returns the page's `/MediaBox` — the sheet it is imposed on — as a
  `PdfElixide.Geometry.Rect` in unrotated user space.

  The rect is normalized: `:x` and `:y` are the bottom-left corner and `:width`
  and `:height` are non-negative, even for a file that writes the two corners in
  the reverse order. It is **not** turned to match `rotation/1`: a `90`-degree
  page of a 612 × 792 MediaBox still reports 612 × 792 and displays 792 points
  wide.

  The origin need not be `{0.0, 0.0}`, and when it is not, nothing this library
  returns is rebased on it — an extracted `bbox` is in the same user space as
  the media box, so a glyph at the left edge of a page whose box starts at
  `10.0` reports an `x` near `10.0`, not near `0.0`. See the "Page boxes and the
  coordinate origin" section of `PdfElixide.Document`.

  `/MediaBox` is inheritable (ISO 32000-1 §7.7.3.4): a page without one takes
  the box from an ancestor `/Pages` node. When *two* ancestors declare one,
  which of them wins is not stable — see the same section. An indirect reference
  is resolved, both for the array itself and for any element of it.

  A page with no `/MediaBox` anywhere above it, or whose entry is not an array,
  or is an array of fewer than four elements, is malformed and yields
  `%PdfElixide.Error{reason: :invalid_pdf}` — no default page size is
  substituted. One malformation is *not* reported: an element that is not a
  number reads as `0.0`, so such a page reports a smaller box rather than
  failing.

  A page whose `:index` is not a page of the document — only reachable from a
  hand-built or stale `%Page{}` — yields `%PdfElixide.Error{reason: :out_of_range}`.
  """
  @spec media_box(t()) :: {:ok, Rect.t()} | {:error, Error.t()}
  def media_box(%__MODULE__{doc: %Document{ref: ref}, index: index}) do
    Wrap.call(fn -> Native.document_get_page_media_box(ref, index) end)
  end

  @doc """
  Same as `media_box/1` but raises an error if it fails.
  """
  @spec media_box!(t()) :: Rect.t()
  def media_box!(page) do
    case media_box(page) do
      {:ok, box} -> box
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the page's width in points.

  This is `media_box/1`'s `:width`, in unrotated user space. Like it, the value
  is never negative and is **not** swapped for a rotated page: a page with
  `rotation/1` of `90` or `270` displays as height × width. See `rotation/1`.
  """
  @spec width(t()) :: {:ok, float()} | {:error, Error.t()}
  def width(%__MODULE__{} = page) do
    # Matching `%Rect{}` rather than reading `box.width` keeps the boundary
    # loud: if the Rust `#[module = ...]` attribute and this struct ever stop
    # naming the same module, that is a `CaseClauseError` here instead of a
    # silently wrong return value.
    case media_box(page) do
      {:ok, %Rect{width: width}} -> {:ok, width}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Same as `width/1` but raises an error if it fails.
  """
  @spec width!(t()) :: float()
  def width!(page) do
    case width(page) do
      {:ok, w} -> w
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the page's height in points.

  This is `media_box/1`'s `:height`, in unrotated user space, and like `width/1`
  it is never negative and is not swapped for a rotated page. See `rotation/1`.
  """
  @spec height(t()) :: {:ok, float()} | {:error, Error.t()}
  def height(%__MODULE__{} = page) do
    case media_box(page) do
      {:ok, %Rect{height: height}} -> {:ok, height}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Same as `height/1` but raises an error if it fails.
  """
  @spec height!(t()) :: float()
  def height!(page) do
    case height(page) do
      {:ok, h} -> h
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the page's `/Rotate` — the clockwise rotation a viewer applies when
  displaying it — as `0`, `90`, `180` or `270`.

  A page's own `/Rotate` wins, but the entry is inheritable (ISO 32000-1
  §7.7.3.4): a page without one takes the value from an ancestor `/Pages` node,
  and `0` when no ancestor has one either. When *two* ancestors declare one,
  which of them wins is not stable — see the "Page boxes and the coordinate
  origin" section of `PdfElixide.Document`, which covers `/Rotate` as well.

  Two normalizations come from `pdf_oxide` and are worth knowing:

    * a value outside `0..359` wraps, so `-90` reads as `270`;
    * a value that is **not a multiple of 90** is invalid per §7.7.3.3 and reads
      as `0` — it is *not* rounded down, so `45` is `0`, not `90`.

  `media_box/1`, and the `width/1` and `height/1` derived from it, are MediaBox
  measurements in unrotated user space and are never swapped to match: a
  `90`-degree page of a 612 × 792 MediaBox displays 792 points wide and 612
  tall. Rotation also decides which frame an extracted
  `bbox` is expressed in — see the "Rotated pages and extracted geometry" section
  of `PdfElixide.Document`.

  A page whose `:index` is not a page of the document — only reachable from a
  hand-built or stale `%Page{}` — yields `%PdfElixide.Error{reason: :out_of_range}`.
  """
  @spec rotation(t()) :: {:ok, rotation()} | {:error, Error.t()}
  def rotation(%__MODULE__{doc: %Document{ref: ref}, index: index}) do
    Wrap.call(fn -> Native.document_get_page_rotation(ref, index) end)
  end

  @doc """
  Same as `rotation/1` but raises an error if it fails.
  """
  @spec rotation!(t()) :: rotation()
  def rotation!(page) do
    case rotation(page) do
      {:ok, degrees} -> degrees
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the page's logical page label (e.g. `"i"`, `"1"`, `"A-1"`).

  This is the human-facing page number the PDF may define, independent of the
  zero-based physical index. Pages outside any declared label range fall back to
  their decimal page number.

  A page whose `:index` is not a page of the document — only reachable from a
  hand-built or stale `%Page{}` — yields `%PdfElixide.Error{reason: :out_of_range}`.

  Every call re-reads the document's label ranges, so use
  `PdfElixide.Document.page_labels/1` to label a whole document.
  """
  @spec label(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def label(%__MODULE__{doc: %Document{ref: ref}, index: index}) do
    Wrap.call(fn -> Native.document_page_label(ref, index) end)
  end

  @doc """
  Same as `label/1` but raises an error if it fails.
  """
  @spec label!(t()) :: String.t()
  def label!(page) do
    case label(page) do
      {:ok, label} -> label
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text content of the page.

  A page that cannot be extracted is an error here, where
  `PdfElixide.Document.text/1` skips it by default — `:on_page_error` is a
  whole-document option and does nothing on this path.

  See `t:PdfElixide.Document.text_opts/0` for the available options.
  """
  @spec text(t(), Document.text_opts()) :: {:ok, String.t()} | {:error, Error.t()}
  def text(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.text(doc, index, opts)
  end

  @doc """
  Same as `text/2` but raises an error if it fails.
  """
  @spec text!(t(), Document.text_opts()) :: String.t()
  def text!(page, opts \\ []) when is_list(opts) do
    case text(page, opts) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  @doc """
  Converts the page to Markdown.

  See `t:PdfElixide.Document.markdown_opts/0` for the available options.
  """
  @spec to_markdown(t(), Document.markdown_opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_markdown(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.to_markdown(doc, index, opts)
  end

  @doc """
  Same as `to_markdown/2` but raises an error if it fails.
  """
  @spec to_markdown!(t(), Document.markdown_opts()) :: String.t()
  def to_markdown!(page, opts \\ []) when is_list(opts) do
    case to_markdown(page, opts) do
      {:ok, markdown} -> markdown
      {:error, error} -> raise error
    end
  end

  @doc """
  Converts the page to an HTML fragment.

  See `t:PdfElixide.Document.html_opts/0` for the available options.
  """
  @spec to_html(t(), Document.html_opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_html(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.to_html(doc, index, opts)
  end

  @doc """
  Same as `to_html/2` but raises an error if it fails.
  """
  @spec to_html!(t(), Document.html_opts()) :: String.t()
  def to_html!(page, opts \\ []) when is_list(opts) do
    case to_html(page, opts) do
      {:ok, html} -> html
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the words of the page, each with its bounding box and font metadata.

  See `t:PdfElixide.Document.words_opts/0` for the available options.
  """
  @spec words(t(), Document.words_opts()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  def words(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.words(doc, index, opts)
  end

  @doc """
  Same as `words/2` but raises an error if it fails.
  """
  @spec words!(t(), Document.words_opts()) :: [Word.t()]
  def words!(page, opts \\ []) when is_list(opts) do
    case words(page, opts) do
      {:ok, words} -> words
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text lines of the page, each with its bounding box and words.

  See `t:PdfElixide.Document.text_lines_opts/0` for the available options.
  """
  @spec text_lines(t(), Document.text_lines_opts()) ::
          {:ok, [TextLine.t()]} | {:error, Error.t()}
  def text_lines(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.text_lines(doc, index, opts)
  end

  @doc """
  Same as `text_lines/2` but raises an error if it fails.
  """
  @spec text_lines!(t(), Document.text_lines_opts()) :: [TextLine.t()]
  def text_lines!(page, opts \\ []) when is_list(opts) do
    case text_lines(page, opts) do
      {:ok, lines} -> lines
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the characters of the page, each with its bounding box, font
  metadata, and typographic placement.

  See `t:PdfElixide.Document.chars_opts/0` for the available options.
  """
  @spec chars(t(), Document.chars_opts()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  def chars(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.chars(doc, index, opts)
  end

  @doc """
  Same as `chars/2` but raises an error if it fails.
  """
  @spec chars!(t(), Document.chars_opts()) :: [Char.t()]
  def chars!(page, opts \\ []) when is_list(opts) do
    case chars(page, opts) do
      {:ok, chars} -> chars
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the spans of the page, each a run of text sharing one text state.

  See `t:PdfElixide.Document.spans_opts/0` for the available options.
  """
  @spec spans(t(), Document.spans_opts()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  def spans(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.spans(doc, index, opts)
  end

  @doc """
  Same as `spans/2` but raises an error if it fails.
  """
  @spec spans!(t(), Document.spans_opts()) :: [Span.t()]
  def spans!(page, opts \\ []) when is_list(opts) do
    case spans(page, opts) do
      {:ok, spans} -> spans
      {:error, error} -> raise error
    end
  end

  @doc """
  Detects the tables of the page.

  Returns `{:ok, []}` when the page has no detectable table. See
  `t:PdfElixide.Document.tables_opts/0` for the available options.
  """
  @spec tables(t(), Document.tables_opts()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  def tables(%__MODULE__{doc: doc, index: index}, opts \\ []) when is_list(opts) do
    Document.tables(doc, index, opts)
  end

  @doc """
  Same as `tables/2` but raises an error if it fails.
  """
  @spec tables!(t(), Document.tables_opts()) :: [Table.t()]
  def tables!(page, opts \\ []) when is_list(opts) do
    case tables(page, opts) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the vector paths of the page — lines, curves, rectangles, and shapes.

  Returns `{:ok, []}` when the page has no vector graphics.
  """
  @spec paths(t()) :: {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def paths(%__MODULE__{doc: doc, index: index}) do
    Document.paths(doc, index)
  end

  @doc """
  Same as `paths/1` but raises an error if it fails.
  """
  @spec paths!(t()) :: [PdfElixide.Document.Path.t()]
  def paths!(page) do
    case paths(page) do
      {:ok, paths} -> paths
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the raster images of the page — photos, logos, and scanned pictures.

  Returns `{:ok, []}` when the page has no images.
  """
  @spec images(t()) :: {:ok, [Image.t()]} | {:error, Error.t()}
  def images(%__MODULE__{doc: doc, index: index}) do
    Document.images(doc, index)
  end

  @doc """
  Same as `images/1` but raises an error if it fails.
  """
  @spec images!(t()) :: [Image.t()]
  def images!(page) do
    case images(page) do
      {:ok, images} -> images
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the fonts referenced by the page.

  Returns `{:ok, []}` when the page references no fonts — and also when the page
  or its `/Resources` could not be read, which `PdfElixide.Document.fonts/2`
  explains.
  """
  @spec fonts(t()) :: {:ok, [Font.t()]} | {:error, Error.t()}
  def fonts(%__MODULE__{doc: doc, index: index}) do
    Document.fonts(doc, index)
  end

  @doc """
  Same as `fonts/1` but raises an error if it fails.
  """
  @spec fonts!(t()) :: [Font.t()]
  def fonts!(page) do
    case fonts(page) do
      {:ok, fonts} -> fonts
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the annotations on the page.

  Returns `{:ok, []}` when the page has no annotations.
  """
  @spec annotations(t()) :: {:ok, [Annotation.t()]} | {:error, Error.t()}
  def annotations(%__MODULE__{doc: doc, index: index}) do
    Document.annotations(doc, index)
  end

  @doc """
  Same as `annotations/1` but raises an error if it fails.
  """
  @spec annotations!(t()) :: [Annotation.t()]
  def annotations!(page) do
    case annotations(page) do
      {:ok, annotations} -> annotations
      {:error, error} -> raise error
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Page{index: index}, _opts) do
      concat(["#PdfElixide.Document.Page<", to_string(index), ">"])
    end
  end
end
