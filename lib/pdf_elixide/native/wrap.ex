defmodule PdfElixide.Native.Wrap do
  @moduledoc false

  alias PdfElixide.Error

  @doc """
  Runs a NIF call and normalizes the result.

  Returns `{:ok, value}` on success and `{:error, %PdfElixide.Error{}}` on
  failure, whether the NIF returned a tagged `{:error, term}` or raised.

  Two failures are *not* normalized, because they report a caller bug rather
  than a condition of the document: the `:badarg` a NIF raises when it cannot
  decode an argument (already an `ArgumentError`), and a Rustler options-map
  field decode failure, which is re-raised as an `ArgumentError` naming the
  offending field. See the "Errors versus exceptions" section of
  `PdfElixide.Error`.
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
    exception -> handle_rescue(exception, __STACKTRACE__)
  end

  # Our NIFs report failures by raising a `{reason, message}` term, which Elixir
  # normalizes to an `ErlangError`. Anything else is a caller bug — most often
  # the `:badarg` a NIF raises when it cannot decode its arguments, which
  # normalizes to `ArgumentError` — so it propagates untouched, the way the
  # public functions' guard clauses do.
  #
  # `rescue e in ErlangError` cannot draw this line: it matches every raw Erlang
  # error but binds the *normalized* exception, so `e.original` blew up with a
  # `KeyError` on anything that normalized to a different struct.
  #
  # A bad value inside an options map is the second caller bug that reaches
  # here. Rustler reports a `NifMap` field decode failure by raising a plain
  # *string* rather than `:badarg`, so it needs its own clause — and the string
  # is worth keeping, because it names the field that failed where `:badarg`
  # could not. Matching the message prefix couples this to Rustler's wording,
  # deliberately: should that wording ever change, the clause below stops
  # matching and the error degrades to `%Error{reason: :other}` — the behavior
  # this library shipped before, not a crash. `wrap_test.exs` pins both halves.
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
