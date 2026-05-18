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
    # BadArg from rustler — usually means a Rust panic or argument decode failure
    ArgumentError -> {:error, :badarg}
    # Structured Rust-side error via Error::Term
    e in ErlangError -> {:error, e.original}
    # Anything else (RuntimeError, FunctionClauseError, ...) — surface a message
    e -> {:error, Exception.message(e)}
  end
end
