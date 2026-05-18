defmodule PdfElixide do
  @moduledoc """
  Elixir bindings for pdf_oxide, a high-performance PDF library written in Rust.
  """

  @opaque t :: reference()

  @doc """
  Opens a PDF document from the specified file path.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
  def open(path) when is_binary(path) do
    wrap(fn -> PdfElixide.Native.open(path) end)
  end

  @doc """
  Opens a PDF document from the specified file path, raising an error if it fails.
  """
  @spec open!(Path.t()) :: t()
  def open!(path) when is_binary(path) do
    case open(path) do
      {:ok, doc} -> doc
      {:error, reason} -> raise "Failed to open PDF: #{inspect(reason)}"
    end
  end

  @doc """
  Opens a PDF document from the given binary data.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, term()}
  def from_binary(bytes) when is_binary(bytes) do
    wrap(fn -> PdfElixide.Native.from_bytes(bytes) end)
  end

  @doc """
  Opens a PDF document from the given binary data, raising an error if it fails.
  """
  @spec from_binary!(binary()) :: t()
  def from_binary!(bytes) when is_binary(bytes) do
    case from_binary(bytes) do
      {:ok, doc} -> doc
      {:error, reason} -> raise "Failed to open PDF from binary: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the number of pages in the given PDF document.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def page_count(doc) when is_reference(doc) do
    wrap(fn -> PdfElixide.Native.page_count(doc) end)
  end

  @doc """
  Returns the number of pages in the given PDF document, raising an error if it fails.
  """
  @spec page_count!(t()) :: non_neg_integer()
  def page_count!(doc) when is_reference(doc) do
    case page_count(doc) do
      {:ok, count} -> count
      {:error, reason} -> raise "Failed to get page count: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the PDF specification version of the given document as a `{major, minor}` tuple.
  """
  @spec version(t()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def version(doc) when is_reference(doc) do
    wrap(fn -> PdfElixide.Native.version(doc) end)
  end

  @doc """
  Returns the PDF specification version of the given document, raising an error if it fails.
  """
  @spec version!(t()) :: {non_neg_integer(), non_neg_integer()}
  def version!(doc) when is_reference(doc) do
    case version(doc) do
      {:ok, ver} -> ver
      {:error, reason} -> raise "Failed to get PDF version: #{inspect(reason)}"
    end
  end

  # NIF result wrapper
  defp wrap(fun) do
    case fun.() do
      # NIF returned tagged ok
      {:ok, _} = result -> result
      # NIF returned tagged error
      {:error, _} = result -> result
      # NIF returned a bare value
      other -> {:ok, other}
    end
  rescue
    # Argument error from Rustler
    ArgumentError -> {:error, :badarg}
    # Structured Rust-side error via Error::Term
    e in ErlangError -> {:error, e.original}
    # Anything else (RuntimeError, FunctionClauseError, ...)
    e -> {:error, Exception.message(e)}
  end
end
