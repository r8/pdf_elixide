defmodule PdfElixide.Native.Wrap do
  @moduledoc false

  alias PdfElixide.Error
  alias PdfElixide.Logging

  @reasons Error.__reasons__()

  defguardp is_tagged(reason, message) when reason in @reasons and is_binary(message)

  @doc false
  @spec call((-> term())) :: {:ok, term()} | {:error, Error.t()}
  def call(fun) do
    fun.()
  rescue
    exception -> handle_rescue(exception, __STACKTRACE__)
  else
    {:ok, _} = result ->
      result

    {:error, {reason, message}} when is_tagged(reason, message) ->
      {:error, %Error{reason: reason, message: message}}

    # Raised from `else`, not the body, so the `rescue` above cannot turn it
    # back into an error value.
    {:error, _} = malformed ->
      :erlang.error(malformed)

    other ->
      {:ok, other}
  after
    # `after` rather than the success path so a raising call still forwards
    # what it captured before failing.
    Logging.flush_pending()
  end

  @doc false
  @spec unwrap!({:ok, value} | {:error, Error.t()}) :: value when value: var
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)

  @doc false
  @spec call!((-> term())) :: term()
  def call!(fun), do: fun |> call() |> unwrap!()

  defp handle_rescue(
         %ErlangError{original: "Could not decode field " <> _ = message},
         stacktrace
       ) do
    reraise ArgumentError.exception(message), stacktrace
  end

  defp handle_rescue(%ErlangError{original: {reason, message}}, _stacktrace)
       when is_tagged(reason, message) do
    {:error, %Error{reason: reason, message: message}}
  end

  # Anything undeclared means the native boundary is broken, not the document.
  defp handle_rescue(exception, stacktrace), do: reraise(exception, stacktrace)
end
