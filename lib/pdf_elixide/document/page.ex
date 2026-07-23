defmodule PdfElixide.Document.Page do
  @moduledoc """
  Representation of a page of a PDF document.
  """

  alias PdfElixide.Document
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Image
  alias PdfElixide.Document.Path
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:doc, :index]
  defstruct [:doc, :index]

  @type t :: %__MODULE__{
          doc: Document.t(),
          index: non_neg_integer()
        }

  @doc """
  Returns the page's width in points.
  """
  @spec width(t()) :: {:ok, float()} | {:error, Error.t()}
  def width(%__MODULE__{doc: %Document{ref: ref}, index: index}) do
    Wrap.call(fn -> Native.document_get_page_width(ref, index) end)
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
  """
  @spec height(t()) :: {:ok, float()} | {:error, Error.t()}
  def height(%__MODULE__{doc: %Document{ref: ref}, index: index}) do
    Wrap.call(fn -> Native.document_get_page_height(ref, index) end)
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
  Extracts the text content of the page.
  """
  @spec text(t()) :: {:ok, binary()} | {:error, Error.t()}
  def text(%__MODULE__{doc: doc, index: index}) do
    Document.text(doc, index)
  end

  @doc """
  Same as `text/1` but raises an error if it fails.
  """
  @spec text!(t()) :: binary()
  def text!(page) do
    case text(page) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the words of the page, each with its bounding box and font metadata.
  """
  @spec words(t()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  def words(%__MODULE__{doc: doc, index: index}) do
    Document.words(doc, index)
  end

  @doc """
  Same as `words/1` but raises an error if it fails.
  """
  @spec words!(t()) :: [Word.t()]
  def words!(page) do
    case words(page) do
      {:ok, words} -> words
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text lines of the page, each with its bounding box and words.
  """
  @spec text_lines(t()) :: {:ok, [TextLine.t()]} | {:error, Error.t()}
  def text_lines(%__MODULE__{doc: doc, index: index}) do
    Document.text_lines(doc, index)
  end

  @doc """
  Same as `text_lines/1` but raises an error if it fails.
  """
  @spec text_lines!(t()) :: [TextLine.t()]
  def text_lines!(page) do
    case text_lines(page) do
      {:ok, lines} -> lines
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the characters of the page, each with its bounding box, font
  metadata, and typographic placement.
  """
  @spec chars(t()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  def chars(%__MODULE__{doc: doc, index: index}) do
    Document.chars(doc, index)
  end

  @doc """
  Same as `chars/1` but raises an error if it fails.
  """
  @spec chars!(t()) :: [Char.t()]
  def chars!(page) do
    case chars(page) do
      {:ok, chars} -> chars
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the spans of the page, each a run of text sharing one text state.
  """
  @spec spans(t()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  def spans(%__MODULE__{doc: doc, index: index}) do
    Document.spans(doc, index)
  end

  @doc """
  Same as `spans/1` but raises an error if it fails.
  """
  @spec spans!(t()) :: [Span.t()]
  def spans!(page) do
    case spans(page) do
      {:ok, spans} -> spans
      {:error, error} -> raise error
    end
  end

  @doc """
  Detects the tables of the page.

  Returns `{:ok, []}` when the page has no detectable table.
  """
  @spec tables(t()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  def tables(%__MODULE__{doc: doc, index: index}) do
    Document.tables(doc, index)
  end

  @doc """
  Same as `tables/1` but raises an error if it fails.
  """
  @spec tables!(t()) :: [Table.t()]
  def tables!(page) do
    case tables(page) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the vector paths of the page — lines, curves, rectangles, and shapes.

  Returns `{:ok, []}` when the page has no vector graphics.
  """
  @spec paths(t()) :: {:ok, [Path.t()]} | {:error, Error.t()}
  def paths(%__MODULE__{doc: doc, index: index}) do
    Document.paths(doc, index)
  end

  @doc """
  Same as `paths/1` but raises an error if it fails.
  """
  @spec paths!(t()) :: [Path.t()]
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

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Page{index: index}, _opts) do
      concat(["#PdfElixide.Document.Page<", to_string(index), ">"])
    end
  end
end
