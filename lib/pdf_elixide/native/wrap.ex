defmodule PdfElixide.Native.Wrap do
  @moduledoc false

  @doc """
  Runs a NIF call and converts raised errors to `{:error, term`.
  Returns `{:ok, value}` on success.
  """
  def call(fun) do
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
