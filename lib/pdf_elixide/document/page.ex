defmodule PdfElixide.Document.Page do
  @moduledoc """
  Representation of a page of a PDF document.
  """

  alias PdfElixide.Document
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
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
  @spec width(t()) :: {:ok, float()} | {:error, term()}
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
  @spec height(t()) :: {:ok, float()} | {:error, term()}
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
  @spec text(t()) :: {:ok, binary()} | {:error, term()}
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
  @spec words(t()) :: {:ok, [Word.t()]} | {:error, term()}
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
  @spec text_lines(t()) :: {:ok, [TextLine.t()]} | {:error, term()}
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
  @spec chars(t()) :: {:ok, [Char.t()]} | {:error, term()}
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

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Page{index: index}, _opts) do
      concat(["#PdfElixide.Document.Page<", to_string(index), ">"])
    end
  end
end
