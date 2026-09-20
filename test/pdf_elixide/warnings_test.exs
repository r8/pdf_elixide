defmodule PdfElixide.WarningsTest do
  @moduledoc false

  # Exact process-wide assertions require isolation from async modules.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Logging
  alias PdfElixide.Signature
  alias PdfElixide.Warning

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @missing_endobj Path.join(@fixtures, "warnings_missing_endobj.pdf")
  @header_at_eof Path.join(@fixtures, "warnings_header_at_eof.pdf")
  @stream_cr Path.join(@fixtures, "warnings_stream_cr.pdf")
  @broken_page Path.join(@fixtures, "broken_page.pdf")
  @encrypted Path.join(@fixtures, "encrypted.pdf")
  @encrypted_missing_endobj Path.join(@fixtures, "warnings_encrypted_missing_endobj.pdf")
  @sample Path.join(@fixtures, "sample.pdf")

  @password "secret"

  @bound 4096

  @concurrency 16
  @timeout 60_000

  setup do
    Logging.take_structured_warnings()
    :ok
  end

  defp open(path, opts \\ []) do
    doc = Document.open!(path, opts)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp eof_entry(object \\ 5, bytes \\ 256) do
    %Warning{
      category: :eof_premature,
      page: nil,
      message:
        "Unexpected EOF while reading object #{object} (no endobj found after #{bytes} bytes)",
      spec_section: "7.5"
    }
  end

  defp encrypt_entry, do: eof_entry(10, 909)

  defp route(doc, :text), do: Document.text!(doc, 0)
  defp route(doc, :text_all), do: Document.text!(doc)
  defp route(doc, :markdown), do: Document.to_markdown!(doc, 0)
  defp route(doc, :markdown_all), do: Document.to_markdown!(doc)
  defp route(doc, :html), do: Document.to_html!(doc, 0)
  defp route(doc, :html_all), do: Document.to_html!(doc)
  defp route(doc, :plain_text), do: Document.to_plain_text!(doc, 0)
  defp route(doc, :plain_text_all), do: Document.to_plain_text!(doc)
  defp route(doc, :chars), do: Document.chars!(doc, 0)
  defp route(doc, :words), do: Document.words!(doc, 0)
  defp route(doc, :spans), do: Document.spans!(doc, 0)
  defp route(doc, :search), do: Document.search!(doc, "Warned")
  defp route(doc, :render), do: Document.render!(doc, 0, dpi: 20)
  defp route(doc, :text_layers), do: Document.text!(doc, 0, exclude_layers: ["none"])
  defp route(doc, :text_inks), do: Document.text!(doc, 0, exclude_inks: ["none"])

  defp route(doc, :text_region) do
    Document.text!(doc, 0, region: %Rect{x: 0.0, y: 0.0, width: 999.0, height: 999.0})
  end

  defp encryption_entry do
    %Warning{
      category: :encryption,
      page: nil,
      message:
        "PDF is encrypted and requires a password; call authenticate() before extracting text",
      spec_section: "7.6"
    }
  end

  # One parse of the damaged encrypted fixture records both: the unreadable
  # object, then the reader refusing to go on without a password.
  defp parse_entries(count) do
    List.duplicate([encrypt_entry(), encryption_entry()], count) |> List.flatten()
  end

  describe "per document" do
    test "records nothing at open and one entry once the object is read" do
      doc = open(@missing_endobj)

      assert Document.structured_warnings!(doc) == []
      assert Document.text!(doc, 0) == "Warned"
      assert Document.structured_warnings!(doc) == [eof_entry()]
    end

    test "listing does not empty the list, and a cached object records once" do
      doc = open(@missing_endobj)
      Document.text!(doc, 0)

      assert Document.structured_warnings!(doc) == [eof_entry()]
      Document.text!(doc, 0)
      assert Document.structured_warnings!(doc) == [eof_entry()]
    end

    test "is per handle" do
      damaged = open(@missing_endobj)
      twin = open(@missing_endobj)
      clean = open(@sample)
      Document.text!(damaged, 0)

      assert Document.structured_warnings!(damaged) == [eof_entry()]
      assert Document.structured_warnings!(twin) == []
      assert Document.structured_warnings!(clean) == []
      assert Logging.structured_warnings() == []
    end

    test "reports :closed after close/1" do
      doc = Document.open!(@missing_endobj)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.structured_warnings(doc)
    end

    test "concurrent readers all see the entry" do
      doc = open(@missing_endobj)
      Document.text!(doc, 0)

      1..@concurrency
      |> Task.async_stream(fn _ -> Document.structured_warnings!(doc) end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: @timeout
      )
      |> Enum.each(fn {:ok, seen} -> assert seen == [eof_entry()] end)
    end

    # Each extraction retries the uncached object and adds warnings.
    # Fill without listing to exercise the bound for callers who never list.
    test "an overflowed list keeps the newest entries and reports the drop on the next listing" do
      doc = open(@header_at_eof)

      assert Document.text!(doc, 0) == ""
      assert [%Warning{category: :eof_premature} | _] = Document.structured_warnings!(doc)

      extra = 200
      for _ <- 1..(@bound + extra), do: Document.text!(doc, 0)

      log =
        capture_log(fn ->
          assert length(Document.structured_warnings!(doc)) == @bound
        end)

      assert [_, dropped] =
               Regex.run(~r/discarded (\d+) structured warning\(s\); the document's list/, log)

      assert String.to_integer(dropped) >= extra
      assert capture_log(fn -> Document.structured_warnings!(doc) end) == ""
    end

    # The damaged `/Encrypt` dictionary records one warning per parse.
    test "entries survive authenticate/2, and each attempt's re-read adds its own" do
      doc = open(@encrypted_missing_endobj)
      assert Document.structured_warnings!(doc) == parse_entries(1)

      refute Document.authenticate!(doc, "wrong")
      assert Document.structured_warnings!(doc) == parse_entries(2)

      assert Document.authenticate!(doc, @password)
      assert Document.structured_warnings!(doc) == parse_entries(3)

      reference = open(@encrypted, password: @password)
      assert Document.text!(doc, 0) == Document.text!(reference, 0)
      assert Document.structured_warnings!(doc) == parse_entries(3)
      assert Logging.structured_warnings() == []
    end

    # `/V 9` is no encryption version, so the handler fails after the
    # `/Encrypt` dictionary has been read. Same length, so nothing moves.
    test "an attempt that fails with an error still keeps what its re-read recorded" do
      bytes = File.read!(@encrypted_missing_endobj)
      assert length(:binary.matches(bytes, "/V 5")) == 1
      doc = Document.from_binary!(String.replace(bytes, "/V 5", "/V 9"))
      on_exit(fn -> Document.close(doc) end)

      assert Document.structured_warnings!(doc) == [encrypt_entry()]
      assert {:error, %Error{reason: :unsupported}} = Document.authenticate(doc, @password)
      assert Document.structured_warnings!(doc) == List.duplicate(encrypt_entry(), 2)
    end

    test "a handle opened with its password records the open's read once" do
      doc = open(@encrypted_missing_endobj, password: @password)
      assert Document.structured_warnings!(doc) == parse_entries(1)

      # Already authenticated, so this authenticates in place with no re-parse.
      assert Document.authenticate!(doc, @password)
      assert Document.structured_warnings!(doc) == parse_entries(1)
    end

    test "reads interleaved with the first extraction see nothing or the entry" do
      doc = open(@missing_endobj)

      results =
        1..@concurrency
        |> Enum.flat_map(fn _ -> [:read, :extract] end)
        |> Enum.shuffle()
        |> Task.async_stream(
          fn
            :read -> {:read, Document.structured_warnings!(doc)}
            :extract -> {:extract, Document.text!(doc, 0)}
          end,
          max_concurrency: @concurrency,
          ordered: false,
          timeout: @timeout
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for {:extract, text} <- results, do: assert(text == "Warned")
      for {:read, seen} <- results, do: assert(seen in [[], [eof_entry()]])
      assert Document.structured_warnings!(doc) == [eof_entry()]
    end
  end

  describe "process-wide" do
    # Which feed a reader-level condition reaches depends on the call, not the
    # category: extraction and conversion attribute what they meet to the
    # document, every other call leaves it here.
    test "a parser condition lands here when no extraction claimed it" do
      doc = open(@stream_cr)
      assert Document.search!(doc, "Warned") != []

      assert [
               %Warning{
                 category: :spec_violation,
                 page: nil,
                 message: "SPEC VIOLATION: Stream keyword followed by CR alone" <> _,
                 spec_section: "7.3.8.1"
               }
             ] = Logging.structured_warnings()

      assert Document.structured_warnings!(doc) == []
    end

    test "the same condition lands on the document when extraction raised it" do
      doc = open(@stream_cr)
      assert Document.text!(doc, 0) == "Warned"

      assert [%Warning{category: :spec_violation, spec_section: "7.3.8.1"}] =
               Document.structured_warnings!(doc)

      assert Logging.structured_warnings() == []
    end

    # Exactly which calls claim a reader-level condition is what
    # `PdfElixide.Warning`'s "Which feed a warning reaches" promises, and the
    # set is upstream's rather than ours — `text/3` under a layer or ink filter
    # takes a route that does not claim, and `to_plain_text` never claims. The
    # whole-document converters are listed separately because upstream gives
    # `to_markdown_all` and `to_html_all` their own scope, so they can drift
    # away from the per-page pair.
    for route <- [:text, :text_region, :text_all, :markdown, :markdown_all, :html, :html_all] do
      test "#{route} claims the condition for its document" do
        doc = open(@stream_cr)
        route(doc, unquote(route))

        assert [%Warning{category: :spec_violation}] = Document.structured_warnings!(doc)
        assert Logging.structured_warnings() == []
      end
    end

    for route <- [
          :text_layers,
          :text_inks,
          :plain_text,
          :plain_text_all,
          :chars,
          :words,
          :spans,
          :search,
          :render
        ] do
      test "#{route} leaves the condition process-wide" do
        doc = open(@stream_cr)
        route(doc, unquote(route))

        assert Document.structured_warnings!(doc) == []
        assert [%Warning{category: :spec_violation}] = Logging.structured_warnings()
      end
    end

    test "listing does not empty the feed; taking does" do
      doc = open(@stream_cr)
      Document.search!(doc, "Warned")

      seen = Logging.structured_warnings()
      assert length(seen) == 1
      assert Logging.structured_warnings() == seen
      assert Logging.take_structured_warnings() == seen
      assert Logging.structured_warnings() == []
      assert Logging.take_structured_warnings() == []
    end

    test "a parse with no handle behind it is visible when it returns" do
      refute Signature.document_timestamp?(File.read!(@stream_cr))

      assert [%Warning{category: :spec_violation, spec_section: "7.3.8.1"}] =
               Logging.structured_warnings()
    end

    test "a failed open leaves nothing waiting in the feed" do
      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(@encrypted, password: "wrong")

      assert {:error, %Error{reason: :encrypted}} = Editor.open(@encrypted)
      assert Logging.structured_warnings() == []
    end

    test "a page that resolves through neither lookup leaves both feeds empty" do
      doc = open(@broken_page)

      assert {:ok, _} = Document.text(doc)
      assert Document.structured_warnings!(doc) == []
      assert Logging.structured_warnings() == []
    end

    test "an overflowed feed keeps the newest entries and reports the drop on take" do
      bytes = File.read!(@stream_cr)
      overflow = @bound + 5

      for _ <- 1..overflow do
        doc = Document.from_binary!(bytes)
        Document.search!(doc, "Warned")
        Document.close(doc)
      end

      assert length(Logging.structured_warnings()) == @bound

      log =
        capture_log(fn ->
          assert length(Logging.take_structured_warnings()) == @bound
        end)

      assert log =~ "discarded 5 structured warning(s)"
      assert capture_log(fn -> Logging.take_structured_warnings() end) == ""
    end
  end
end
