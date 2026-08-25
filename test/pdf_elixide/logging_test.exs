defmodule PdfElixide.LoggingTest do
  @moduledoc false

  # Capture is process-global, so these must not run alongside anything that
  # opens a document — a concurrent call would drain this test's buffer.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PdfElixide.Document
  alias PdfElixide.Error
  alias PdfElixide.Logging

  # The default formatter prints only the metadata keys named in config, so
  # `capture_log/1` cannot see which keys an event carried. This handler can.
  defmodule Collector do
    @moduledoc false

    def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
  end

  # `broken_page.pdf`'s third page does not resolve through the page tree. It is
  # the only fixture here that makes upstream log while still returning `:ok`.
  @broken "test/fixtures/broken_page.pdf"
  @clean "test/fixtures/sample.pdf"

  setup do
    on_exit(fn -> Logging.set_level(:off) end)
    :ok
  end

  defp collect(level) do
    :ok =
      :logger.add_handler(:pdf_elixide_test_collector, Collector, %{
        config: %{pid: self()},
        level: level
      })

    on_exit(fn -> :logger.remove_handler(:pdf_elixide_test_collector) end)
  end

  # Exercise a caller key that is deliberately absent from this Logger config.
  # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
  defp tag_caller, do: Logger.metadata(request_id: "REQ-A")

  defp extract(path) do
    {:ok, doc} = Document.open(path)
    result = Document.text(doc)
    Document.close(doc)
    result
  end

  describe "set_level/1" do
    test "is off by default and toggles" do
      refute Logging.enabled?()

      assert :ok = Logging.set_level(:warning)
      assert Logging.enabled?()

      assert :ok = Logging.set_level(:off)
      refute Logging.enabled?()
    end

    test "rejects an unknown level by name" do
      assert_raise ArgumentError, ~r/invalid log level :verbose/, fn ->
        Logging.set_level(:verbose)
      end
    end

    test "every documented level is accepted" do
      for level <- [:off, :error, :warning, :info, :debug, :trace] do
        assert :ok = Logging.set_level(level)
      end
    end
  end

  describe "capture" do
    test "a page that degrades to empty text is silent while capture is off" do
      log = capture_log(fn -> assert {:ok, _} = extract(@broken) end)

      refute log =~ "Page tree traversal failed"
    end

    test "the same page reports why its text is missing while capture is on" do
      Logging.set_level(:warning)

      log =
        capture_log(fn ->
          # Still `:ok` — capture is a diagnostic channel, not an error one.
          assert {:ok, _} = extract(@broken)
          Logging.flush()
        end)

      assert log =~ "Page tree traversal failed"
      assert log =~ "Page index 2 not found"
    end

    test "records reach Logger without an explicit flush" do
      Logging.set_level(:warning)

      log = capture_log(fn -> assert {:ok, _} = extract(@broken) end)

      assert log =~ "Page tree traversal failed"
    end

    test "a clean document stays quiet at :warning" do
      Logging.set_level(:warning)

      log =
        capture_log(fn ->
          assert {:ok, "Page One\fPage Two\fPage Three"} = extract(@clean)
          Logging.flush()
        end)

      refute log =~ "[warning]"
    end

    test "a call that both logs and fails still returns its error" do
      Logging.set_level(:warning)

      log =
        capture_log(fn ->
          {:ok, doc} = Document.open(@broken)
          assert {:error, %Error{reason: :invalid_pdf}} = Document.text(doc, 2)
          Document.close(doc)
        end)

      assert log =~ "Page tree traversal failed"
    end

    test "turning capture off discards what was buffered but not forwarded" do
      Logging.set_level(:warning)
      # Forwarded as it is captured, so this call's own records go to `Logger`
      # here rather than being left for the `flush/0` below.
      capture_log(fn -> assert {:ok, _} = extract(@broken) end)
      Logging.set_level(:off)

      log = capture_log(fn -> assert 0 = Logging.flush() end)

      refute log =~ "Page tree traversal failed"
    end
  end

  describe "attribution" do
    test "a forwarded record carries none of the flushing process's metadata" do
      collect(:warning)
      tag_caller()
      Logging.set_level(:warning)

      capture_log(fn -> assert {:ok, _} = extract(@broken) end)

      assert_receive {:log_event, %{meta: %{pdf_source: _} = meta}}
      refute Map.has_key?(meta, :request_id)
    end

    test "the flushing process keeps its own metadata afterwards" do
      tag_caller()
      Logging.set_level(:warning)

      capture_log(fn -> assert {:ok, _} = extract(@broken) end)

      assert Logger.metadata() == [request_id: "REQ-A"]
    end

    test "a failing flush is still reported with the flushing process's metadata" do
      collect(:error)
      tag_caller()

      capture_log(fn -> assert :ok = Logging.flush_pending(fn -> raise "boom" end) end)

      assert_receive {:log_event, %{meta: %{request_id: "REQ-A", crash_reason: _}}}
    end
  end

  describe "flush/0" do
    test "returns the number of records forwarded and empties the buffer" do
      Logging.set_level(:warning)

      capture_log(fn ->
        assert {:ok, _} = extract(@broken)
        assert Logging.flush() >= 0
        assert 0 = Logging.flush()
      end)
    end

    test "works while capture is off, so records left by a raising call still reach Logger" do
      assert 0 = Logging.flush()
    end
  end

  describe "flush_pending/1" do
    test "a raising flush is reported instead of reaching the caller" do
      log =
        capture_log(fn ->
          assert :ok = Logging.flush_pending(fn -> raise "boom" end)
        end)

      assert log =~ "could not forward captured log records"
      assert log =~ "** (RuntimeError) boom"
    end

    test "a throwing flush is reported instead of reaching the caller" do
      log =
        capture_log(fn ->
          assert :ok = Logging.flush_pending(fn -> throw(:boom) end)
        end)

      assert log =~ "could not forward captured log records"
      assert log =~ "** (throw) :boom"
    end

    test "an exiting flush is reported instead of reaching the caller" do
      log =
        capture_log(fn ->
          assert :ok = Logging.flush_pending(fn -> exit(:boom) end)
        end)

      assert log =~ "could not forward captured log records"
      assert log =~ "** (exit) :boom"
    end

    test "an unloaded NIF is reported instead of reaching the caller" do
      log =
        capture_log(fn ->
          assert :ok = Logging.flush_pending(fn -> :erlang.nif_error(:nif_not_loaded) end)
        end)

      assert log =~ "could not forward captured log records"
      assert log =~ ":nif_not_loaded"
    end

    test "the report carries the stacktrace as :crash_reason" do
      collect(:error)

      capture_log(fn -> assert :ok = Logging.flush_pending(fn -> raise "boom" end) end)

      assert_receive {:log_event,
                      %{meta: %{crash_reason: {%RuntimeError{message: "boom"}, [_ | _]}}}}
    end

    test "the default drains what a call left buffered" do
      Logging.set_level(:warning)

      capture_log(fn ->
        assert {:ok, _} = extract(@broken)
        assert :ok = Logging.flush_pending()
      end)
    end
  end
end
