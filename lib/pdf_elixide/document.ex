defmodule PdfElixide.Document do
  @moduledoc """
  Read-only representation of a PDF document.
  """

  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:ref, :version]
  defstruct [:ref, :version, :source_path]

  @type t :: %__MODULE__{
          ref: reference(),
          version: {non_neg_integer(), non_neg_integer()},
          source_path: Path.t() | nil
        }

  @doc """
  Opens a PDF document from the specified file path.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
  def open(path) when is_binary(path) do
    with {:ok, ref} <- Wrap.call(fn -> Native.document_open(path) end),
         {:ok, version} <- Wrap.call(fn -> Native.document_version(ref) end) do
      {:ok, %__MODULE__{ref: ref, version: version, source_path: path}}
    end
  end

  @doc """
  Opens a PDF document from the specified file path, raising an error if it fails.
  """
  @spec open!(Path.t()) :: t()
  def open!(path) when is_binary(path) do
    case open(path) do
      {:ok, doc} -> doc
      {:error, error} -> raise error
    end
  end

  @doc """
  Opens a PDF document from the given binary data.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, term()}
  def from_binary(bytes) when is_binary(bytes) do
    with {:ok, ref} <- Wrap.call(fn -> Native.document_from_bytes(bytes) end),
         {:ok, version} <- Wrap.call(fn -> Native.document_version(ref) end) do
      {:ok, %__MODULE__{ref: ref, version: version, source_path: nil}}
    end
  end

  @doc """
  Opens a PDF document from the given binary data, raising an error if it fails.
  """
  @spec from_binary!(binary()) :: t()
  def from_binary!(bytes) when is_binary(bytes) do
    case from_binary(bytes) do
      {:ok, doc} -> doc
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the PDF specification version of the given document as a `{major, minor}` tuple.
  """
  @spec version(t()) :: {non_neg_integer(), non_neg_integer()} | {:error, term()}
  def version(%__MODULE__{version: v}), do: v

  @doc """
  Returns the file path from which the document was loaded, or `nil` if it was loaded from binary data.
  """
  @spec source_path(t()) :: Path.t() | nil
  def source_path(%__MODULE__{source_path: p}), do: p

  @doc """
  Returns the number of pages in the given PDF document.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def page_count(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> PdfElixide.Native.document_page_count(ref) end)
  end

  @doc """
  Returns the number of pages in the given PDF document, raising an error if it fails.
  """
  @spec page_count!(t()) :: non_neg_integer()
  def page_count!(doc) do
    case page_count(doc) do
      {:ok, count} -> count
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text content of the page at the given zero-based index.
  """
  @spec extract_text(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def extract_text(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    Wrap.call(fn -> PdfElixide.Native.document_extract_text(ref, page_index) end)
  end

  @doc """
  Extracts the text content of the page at the given zero-based index,
  raising an error if it fails.
  """
  @spec extract_text!(t(), non_neg_integer()) :: binary()
  def extract_text!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case extract_text(doc, page_index) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document{version: {maj, min}, source_path: path}, _opts) do
      src = if path, do: Path.basename(path), else: "<binary>"
      concat(["#PdfElixide.Document<", src, " v", to_string(maj), ".", to_string(min), ">"])
    end
  end
end
