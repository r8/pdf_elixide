defmodule PdfElixide do
  @moduledoc """
  Elixir bindings for pdf_oxide, a high-performance PDF library written in Rust.
  """

  alias PdfElixide.Document

  @doc """
  Opens a PDF document from the specified file path.
  See `PdfElixide.Document.open/1`.
  """
  @spec open(Path.t()) :: {:ok, Document.t()} | {:error, term()}
  defdelegate open(path), to: Document

  @doc """
  Opens a PDF document from the specified file path, raising an error if it fails.
  See `PdfElixide.Document.open!/1`.
  """
  @spec open!(Path.t()) :: Document.t()
  defdelegate open!(path), to: Document

  @doc """
  Opens a PDF document from the given binary data.
  See `PdfElixide.Document.from_binary/1`.
  """
  @spec from_binary(binary()) :: {:ok, Document.t()} | {:error, term()}
  defdelegate from_binary(bin), to: Document

  @doc """
  Opens a PDF document from the given binary data, raising an error if it fails.
  See `PdfElixide.Document.from_binary!/1`.
  """
  @spec from_binary!(binary()) :: Document.t()
  defdelegate from_binary!(bin), to: Document
end
