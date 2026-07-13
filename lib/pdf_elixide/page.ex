defmodule PdfElixide.Page do
  @moduledoc """
  Representation of a page of a PDF document.
  """

  alias PdfElixide.Document
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
    Document.extract_text(doc, index)
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

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Page{index: index}, _opts) do
      concat(["#PdfElixide.Page<", to_string(index), ">"])
    end
  end
end
