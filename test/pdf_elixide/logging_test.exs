defmodule PdfElixide.LoggingTest do
  @moduledoc false

  # Capture is process-global, so these must not run alongside anything that
  # opens a document — a concurrent call would drain this test's buffer.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PdfElixide.Document
  alias PdfElixide.Logging

  # `broken_page.pdf`'s third page does not resolve through the page tree. It is
  # the only fixture here that makes upstream log while still returning `:ok`,
  # which is the whole case this module exists for.
  @broken "test/fixtures/broken_page.pdf"
  @clean "test/fixtures/sample.pdf"

  setup do
    on_exit(fn -> Logging.set_level(:off) end)
    :ok
  end

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
      # `Wrap.call/1` drains on a pending-record count rather than on the enable
      # flag, so this is what pins that the automatic path still fires at all —
      # the test above would pass on its explicit `flush/0` alone.
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
end
