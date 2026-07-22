defmodule PdfElixide.Native.Wrap do
  @moduledoc false

  alias PdfElixide.Error

  @doc """
  Runs a NIF call and normalizes the result.

  Returns `{:ok, value}` on success and `{:error, %PdfElixide.Error{}}` on
  failure, whether the NIF returned a tagged `{:error, term}` or raised.
  """
  @spec call((-> term())) :: {:ok, term()} | {:error, Error.t()}
  def call(fun) do
    case fun.() do
      # NIF returned tagged ok
      {:ok, _} = result -> result
      # NIF returned a tagged error, e.g. {:error, {reason_atom, message}}
      {:error, reason} -> {:error, normalize_error(reason)}
      # NIF returned a bare value
      other -> {:ok, other}
    end
  rescue
    e in ErlangError -> {:error, normalize_error(e.original)}
  end

  # Converts a raw NIF error term into a %PdfElixide.Error{} struct.
  defp normalize_error(%Error{} = error), do: error

  defp normalize_error({reason, message})
       when is_atom(reason) and is_binary(message) do
    %Error{reason: reason, message: message}
  end

  defp normalize_error(message) when is_binary(message) do
    %Error{reason: :other, message: message}
  end

  defp normalize_error(other) do
    %Error{reason: :other, message: inspect(other)}
  end
end
