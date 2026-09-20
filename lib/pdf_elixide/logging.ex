defmodule PdfElixide.Logging do
  @moduledoc """
  Diagnostics for content that extraction drops without failing.

  Extraction can omit content and still return `{:ok, text}`. Enable capture
  to forward diagnostic records to Elixir's `Logger` and help explain missing
  content.

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

  ## Attribution

  Under concurrent use, a record may be forwarded by a process other than the
  one whose work produced it. Forwarded records therefore omit that process's
  `Logger` metadata. Use `:pdf_source`, the message and the timestamp instead;
  the `:pid` added by `Logger` identifies only the forwarding process.

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

  ## Structured warnings

  Some tolerated conditions are recorded as `t:PdfElixide.Warning.t/0`
  values, independently of capture and without explicit enablement.
  `PdfElixide.Document.structured_warnings/1` lists per-document warnings;
  `structured_warnings/0` and `take_structured_warnings/0` read the process-wide
  feed. Which feed a warning reaches depends on the call that raised it; see
  "Which feed a warning reaches" in `PdfElixide.Warning`.

  Under concurrent use an entry may come from any handle in the VM; see the
  [Concurrency](guides/concurrency.md) guide.
  """

  require Logger

  alias PdfElixide.Native
  alias PdfElixide.Warning

  @levels [:off, :error, :warning, :info, :debug, :trace]

  @typedoc """
  Capture level, from `:off` (capture nothing) through `:trace` (capture
  everything).

  Use `:warning` to diagnose missing content.
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

  Library calls that capture records automatically attempt to forward them,
  including when a call raises. Returns the number of records forwarded.

  Records reach `Logger` without the calling process's own metadata; see
  "Attribution" in the module documentation.
  """
  @spec flush() :: non_neg_integer()
  def flush do
    {records, dropped} = Native.log_drain()

    # Do not attribute globally captured records to the draining process.
    saved = Logger.metadata()
    Logger.reset_metadata([])

    try do
      if dropped > 0 do
        Logger.warning(
          "pdf_elixide dropped #{dropped} buffered log record(s); the capture below is incomplete",
          pdf_elixide: true
        )
      end

      Enum.each(records, &forward/1)
      length(records)
    after
      Logger.reset_metadata(saved)
    end
  end

  @doc """
  Lists the warnings recorded process-wide, oldest first, without emptying the
  list.

  See "Structured warnings" in the module documentation for which conditions
  are recorded here and how they are attributed.
  """
  @spec structured_warnings() :: [Warning.t()]
  def structured_warnings do
    Enum.map(Native.warnings_snapshot(), &Warning.from_nif/1)
  end

  @doc """
  Returns the warnings recorded process-wide, oldest first, and empties the
  list.

  The list is bounded and discards the oldest entries when full. If it
  overflowed since it was last emptied, a single `Logger` warning
  reports how many entries were discarded, so a truncated list cannot be
  mistaken for a complete one.
  """
  @spec take_structured_warnings() :: [Warning.t()]
  def take_structured_warnings do
    {warnings, dropped} = Native.warnings_take()
    report_discarded(dropped, "the process-wide list")

    Enum.map(warnings, &Warning.from_nif/1)
  end

  @doc false
  @spec report_discarded(non_neg_integer(), String.t()) :: :ok
  def report_discarded(0, _what), do: :ok

  def report_discarded(dropped, what) do
    Logger.warning(
      "pdf_elixide discarded #{dropped} structured warning(s); #{what} is incomplete",
      pdf_elixide: true
    )
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

  # Keep this outside the reset: the forwarding failure belongs to this process.
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
