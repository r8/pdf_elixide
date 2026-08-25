defmodule PdfElixide.Logging do
  @moduledoc """
  Diagnostics for content that extraction drops without failing.

  Most damaged pages do not produce an error. A content stream that will not
  decode, a font that fails to load, a Form XObject that cannot be processed
  and a character with no usable mapping are all handled by continuing with
  less content, so `PdfElixide.Document.text/1` returns `{:ok, text}` with
  material missing and no way to tell that page from a blank one. Each of those
  is reported internally as a log record. Enable capture and the records reach
  Elixir's `Logger`, naming the page and the reason.

  This is off by default and is a diagnostic aid, not an error channel — a
  captured record does not change what a call returns, and neither does a
  failure to forward one, which is reported at `:error` level and nothing more.
  Errors still arrive as `t:PdfElixide.Error.t/0`; see
  `t:PdfElixide.Document.text_opts/0` for what `:on_page_error` can and cannot
  catch.

  ## Enabling

      iex> PdfElixide.Logging.set_level(:warning)
      :ok

  Records are then forwarded to `Logger` at the matching level, tagged with
  `pdf_elixide: true` and the originating module in `:pdf_source` metadata.
  Turn it back off with `set_level(:off)`, which also discards anything
  captured but not yet forwarded.

  To capture at startup, set it in your application's `start/2` before opening
  any document.

  ## Cost, and why it is off by default

  Capture is process-global, not per-document or per-process: it affects every
  document handle in the VM. Records are buffered as they are produced and
  forwarded when the next call returns, so a level of `:debug` or `:trace` on a
  large document produces a great deal of output and measurably slows
  extraction. `:warning` is the level that reports dropped content.

  The buffer is bounded. If it fills before anything drains it — capture
  enabled but no further calls made — the oldest records are discarded, and a
  single warning reports how many were lost so a truncated capture cannot be
  mistaken for a complete one.
  """

  require Logger

  alias PdfElixide.Native

  @levels [:off, :error, :warning, :info, :debug, :trace]

  @typedoc """
  Capture level, from `:off` (capture nothing) through `:trace` (capture
  everything).

  `:warning` is the level at which dropped content is reported. `:error` is
  quieter than it sounds — a failure severe enough to be logged as an error is
  usually also returned as a `t:PdfElixide.Error.t/0`, so `:warning` is the
  useful floor for diagnosing missing text.
  """
  @type level :: :off | :error | :warning | :info | :debug | :trace

  @doc """
  Sets the capture level, returning `:ok`.

  Raises `ArgumentError` unless `level` is one of `#{inspect(@levels)}`.
  Setting `:off` also discards any records captured but not yet forwarded.
  """
  @spec set_level(level()) :: :ok
  def set_level(level) when level in @levels do
    :ok = Native.log_set_level(native_level(level))
    :ok
  end

  def set_level(level) do
    raise ArgumentError,
          "invalid log level #{inspect(level)}, expected one of #{inspect(@levels)}"
  end

  @doc """
  Returns whether capture is currently enabled.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Native.log_enabled()

  @doc """
  Forwards every captured record to `Logger` and empties the buffer.

  Called automatically after each library call while capture is enabled, so
  reach for it directly only to flush records left by a call that raised.
  Returns the number of records forwarded.
  """
  @spec flush() :: non_neg_integer()
  def flush do
    {records, dropped} = Native.log_drain()

    if dropped > 0 do
      Logger.warning(
        "pdf_elixide dropped #{dropped} buffered log record(s); the capture below is incomplete",
        pdf_elixide: true
      )
    end

    Enum.each(records, &forward/1)
    length(records)
  end

  # This runs from an `after` clause, so it must never replace the call's result.
  @doc false
  @spec flush_pending((-> term())) :: :ok
  def flush_pending(flush \\ &drain_pending/0) do
    flush.()
    :ok
  rescue
    exception -> report_failure(:error, exception, __STACKTRACE__)
  catch
    kind, reason -> report_failure(kind, reason, __STACKTRACE__)
  end

  # Avoid dispatching the dirty flush NIF when no records are pending.
  defp drain_pending do
    if Native.log_pending() > 0, do: flush()
  end

  defp report_failure(kind, reason, stacktrace) do
    # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
    Logger.error(
      "pdf_elixide could not forward captured log records: " <>
        Exception.format_banner(kind, reason),
      pdf_elixide: true,
      crash_reason: {reason, stacktrace}
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp forward({level, target, message}) do
    Logger.log(logger_level(level), message, pdf_elixide: true, pdf_source: target)
  end

  # `Logger` has no `:trace`; the finest level it offers is `:debug`.
  defp logger_level(:trace), do: :debug
  defp logger_level(:warn), do: :warning
  defp logger_level(level), do: level

  # The NIF mirrors the `log` crate's `Level` names, which spell it `warn`.
  defp native_level(:warning), do: :warn
  defp native_level(level), do: level
end
