defmodule PdfElixide.Native.Wrap do
  @moduledoc false

  alias PdfElixide.Error

  @doc false
  @spec call((-> term())) :: {:ok, term()} | {:error, Error.t()}
  def call(fun) do
    case fun.() do
      {:ok, _} = result -> result
      {:error, reason} -> {:error, normalize_error(reason)}
      other -> {:ok, other}
    end
  rescue
    exception -> handle_rescue(exception, __STACKTRACE__)
  end

  @doc false
  @spec unwrap!({:ok, value} | {:error, Error.t()}) :: value when value: var
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)

  @doc false
  @spec call!((-> term())) :: term()
  def call!(fun), do: fun |> call() |> unwrap!()

  # Our NIFs report failures by raising a `{reason, message}` term, which Elixir
  # normalizes to an `ErlangError`. Anything else is a caller bug — most often
  # the `:badarg` a NIF raises when it cannot decode its arguments, which
  # normalizes to `ArgumentError` — so it propagates untouched, the way the
  # public functions' guard clauses do.
  defp handle_rescue(
         %ErlangError{original: "Could not decode field " <> _ = message},
         stacktrace
       ) do
    reraise ArgumentError.exception(message), stacktrace
  end

  defp handle_rescue(%ErlangError{original: original}, _stacktrace) do
    {:error, normalize_error(original)}
  end

  defp handle_rescue(exception, stacktrace), do: reraise(exception, stacktrace)

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
