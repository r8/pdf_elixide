defmodule PdfElixide.ConcurrencyTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Font
  alias PdfElixide.Document.Image
  alias PdfElixide.Document.Table
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form
  alias PdfElixide.Form.Field

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  @sample_pdf Path.join(@fixtures_dir, "sample.pdf")
  @image_pdf Path.join(@fixtures_dir, "image.pdf")
  @fonts_pdf Path.join(@fixtures_dir, "fonts.pdf")
  @table_pdf Path.join(@fixtures_dir, "table.pdf")
  @form_pdf Path.join(@fixtures_dir, "form.pdf")

  @concurrency 16

  # Generous on purpose: correctness, not latency, is what is being asserted.
  @timeout 60_000

  describe "shared reads" do
    setup do
      doc = Document.open!(@sample_pdf)
      on_exit(fn -> Document.close(doc) end)

      {:ok, doc: doc}
    end

    test "concurrent per-page text from one handle matches the serial result", %{doc: doc} do
      pages = Enum.to_list(0..(doc.page_count - 1))
      expected = Enum.map(pages, &Document.text!(doc, &1))

      # Non-vacuity: an empty or single-page fixture would make the fan-out
      # meaningless.
      assert length(expected) == 3
      refute Enum.any?(expected, &(&1 == ""))

      1..@concurrency
      |> Task.async_stream(fn _ -> Enum.map(pages, &Document.text!(doc, &1)) end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: @timeout
      )
      |> Enum.each(fn {:ok, actual} -> assert actual == expected end)
    end

    test "concurrent mixed extractors on one handle match their serial results", %{doc: doc} do
      # Each of these reaches a different upstream loader over the same shared
      # document, which is the combination only a shared lock ever produces.
      calls = [
        text: &Document.text!/1,
        spans: &Document.spans!/1,
        chars: &Document.chars!/1,
        metadata: &Document.metadata!/1,
        page_labels: &Document.page_labels!/1,
        outline: &Document.outline!/1,
        to_markdown: &Document.to_markdown!/1,
        # Handle-carrying, so two extractions never compare equal with `:ref` on —
        # the same reasoning `per_page_equivalence_test.exs` gives.
        fonts: fn d -> d |> Document.fonts!() |> Enum.map(&Map.delete(&1, :ref)) end,
        page_count: &Document.page_count/1,
        has_xfa?: &Document.has_xfa?/1
      ]

      expected = Map.new(calls, fn {name, call} -> {name, call.(doc)} end)

      calls
      |> List.duplicate(@concurrency)
      |> List.flatten()
      |> Enum.shuffle()
      |> Task.async_stream(fn {name, call} -> {name, call.(doc)} end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: @timeout
      )
      |> Enum.each(fn {:ok, {name, actual}} -> assert actual == expected[name] end)
    end
  end

  describe "a close landing mid-read" do
    # Few on purpose: enough readers for the race to be real, few enough not to
    # saturate the dirty-CPU pool that `close/1` also has to be scheduled on.
    @readers 4

    # Bounds a failure, not a measurement. Rust's `RwLock` queues writers on
    # every platform this runs on, so a reader that never observes `:closed`
    # means starvation — and without the deadline that would hang as an opaque
    # `Task.await` exit instead of failing by name.
    @deadline_ms 30_000

    setup do
      doc = Document.open!(@sample_pdf)
      on_exit(fn -> Document.close(doc) end)

      {:ok, doc: doc}
    end

    test "a close landing mid-read yields :closed, never a wrong result", %{doc: doc} do
      expected = Document.text!(doc, 0)
      refute expected == ""

      test_pid = self()

      readers =
        for _ <- 1..@readers do
          Task.async(fn ->
            # Issued before this reader reports readiness, so it happens-before
            # the `close/1` below: it cannot be the one that lost the race.
            first = Document.text(doc, 0)
            send(test_pid, {:ready, self()})
            {outcomes, stopped} = read_until_closed(doc, deadline(), [])

            %{first: first, outcomes: outcomes, stopped: stopped}
          end)
        end

      for _ <- 1..@readers, do: assert_receive({:ready, _}, @timeout)

      assert :ok = Document.close(doc)

      results = Task.await_many(readers, @timeout)

      # Non-vacuity, and it is structural rather than timed. Every reader's
      # first read was issued before the close was even called, and every
      # reader looped until it observed the close — so each reader's sequence
      # provably spans it. Neither half can degrade into "close always won" or
      # "close never happened". This does not claim a read was in flight at the
      # instant `close` took the write lock.
      assert Enum.all?(results, &(&1.first == {:ok, expected}))

      assert Enum.all?(results, &(&1.stopped == :saw_closed)),
             "a reader hit the #{@deadline_ms}ms deadline without ever observing :closed"

      # The acceptable outcomes, exhaustively: the right text, or `:closed`.
      # Comparing the text for equality rather than for shape is what makes
      # "never a wrong or partial result" an assertion; `:lock_poisoned` and
      # `:panic` are reachable through `Closable` and fail here too.
      for %{outcomes: outcomes} <- results, outcome <- outcomes do
        assert outcome == {:ok, expected} or closed_outcome?(outcome)
      end

      # A close is permanent: within one reader, no `:ok` follows a `:closed`.
      for %{outcomes: outcomes} <- results do
        tail = Enum.drop_while(outcomes, &(not closed_outcome?(&1)))
        assert Enum.all?(tail, &closed_outcome?/1)
      end

      assert Document.closed?(doc)
      assert {:error, %Error{reason: :closed}} = Document.text(doc, 0)

      # Struct-served, so it keeps answering — exactly what `close/1` promises.
      assert {:ok, 3} = Document.page_count(doc)
    end
  end

  describe "handles that are not documents" do
    test "concurrent reads of one image handle match the serial results" do
      doc = Document.open!(@image_pdf)
      [image | _] = Document.images!(doc, 0)

      on_exit(fn ->
        Image.close(image)
        Document.close(doc)
      end)

      png = Image.to_binary!(image)
      jpeg = Image.to_binary!(image, format: :jpeg)
      data = Image.data!(image)

      # Non-vacuity, and the reason equality across tasks is an assertion rather
      # than a cache hit: this fixture stores raw pixels, so every `to_binary/2`
      # call encodes afresh from the image behind the handle.
      assert <<137, 80, 78, 71, _::binary>> = png
      assert {:raw, _pixels, _pixel_format} = data

      calls = [
        png: &Image.to_binary!/1,
        jpeg: &Image.to_binary!(&1, format: :jpeg),
        data: &Image.data!/1
      ]

      expected = %{png: png, jpeg: jpeg, data: data}

      assert_concurrently_equal(calls, image, expected)
    end

    test "concurrent data/1 on one font handle matches the serial bytes" do
      doc = Document.open!(@fonts_pdf)
      font = doc |> Document.fonts!(0) |> Enum.find(& &1.embedded?)

      on_exit(fn ->
        if font, do: Font.close(font)
        Document.close(doc)
      end)

      # Load-bearing: `data/1` on a non-embedded font is `nil`, on which every
      # task would agree without reading anything.
      assert font
      bytes = Font.data!(font)
      assert is_binary(bytes) and byte_size(bytes) > 0

      assert_concurrently_equal([data: &Font.data!/1], font, %{data: bytes})
    end

    test "concurrent renders of one table handle match the serial output" do
      doc = Document.open!(@table_pdf)
      [table | _] = Document.tables!(doc, 0)

      on_exit(fn ->
        Table.close(table)
        Document.close(doc)
      end)

      markdown = Table.to_markdown!(table)
      html = Table.to_html!(table)
      text = Table.to_text!(table)

      # Non-vacuity: the separator markdown forces under every first row.
      assert markdown =~ "|---|"
      refute html == ""
      refute text == ""

      calls = [
        markdown: &Table.to_markdown!/1,
        html: &Table.to_html!/1,
        text: &Table.to_text!/1
      ]

      assert_concurrently_equal(calls, table, %{markdown: markdown, html: html, text: text})
    end
  end

  describe "a single editor" do
    # Enough rounds for the two writers and the readers to interleave; the
    # assertions below do not depend on how they do.
    @writes 25

    test "one writer per field on one editor, and no write is lost" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # Disjoint fields, one writer each, so the final state is determined by
      # each writer's *last* write rather than by who finished last.
      writers = [
        Task.async(fn ->
          for i <- 1..@writes, do: Form.put_value(editor, "full_name", "a-#{i}")
        end),
        Task.async(fn ->
          for i <- 1..@writes, do: Form.put_value(editor, "subscribe", even?(i))
        end)
      ]

      readers =
        for _ <- 1..(@concurrency - 2) do
          Task.async(fn -> for _ <- 1..@writes, do: Form.fields!(editor) end)
        end

      write_results = writers |> Task.await_many(@timeout) |> Enum.concat()

      # `Enum.concat/1`, not `List.flatten/1`: a snapshot is itself a list, and
      # flattening would merge every reader's forms into one list of fields.
      snapshots = readers |> Task.await_many(@timeout) |> Enum.concat()

      assert length(write_results) == 2 * @writes
      assert Enum.all?(write_results, &match?({:ok, %Editor{}}, &1))

      # Neither writer's last write was lost behind the other's.
      final = Map.new(Form.fields!(editor), &{&1.name, &1.value})
      assert final["full_name"] == "a-#{@writes}"
      assert final["subscribe"] == even?(@writes)

      # The property the exclusive lock actually buys: a read interleaved with
      # writes sees a whole form, never a half-applied mutation or a lost field.
      assert length(snapshots) == (@concurrency - 2) * @writes

      for fields <- snapshots do
        assert Enum.map(fields, & &1.name) == ["full_name", "subscribe", "country"]
        assert Enum.all?(fields, &well_formed_field?/1)
      end
    end

    test "to_binary/2 racing put_value/3 always yields a parseable PDF" do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      written = Enum.map(1..@concurrency, &"v-#{&1}")

      # The original value is allowed too: a snapshot taken before any write
      # still carries it.
      allowed = MapSet.new(["John Doe" | written])

      work =
        Enum.map(written, fn value ->
          fn -> {:write, Form.put_value(editor, "full_name", value)} end
        end) ++
          Enum.map(1..@concurrency, fn _ -> fn -> {:snapshot, Editor.to_binary!(editor)} end end)

      results =
        work
        |> Enum.shuffle()
        |> Task.async_stream(& &1.(),
          max_concurrency: @concurrency,
          ordered: false,
          timeout: @timeout
        )
        |> Enum.map(fn {:ok, result} -> result end)

      writes = for {:write, result} <- results, do: result
      snapshots = for {:snapshot, pdf} <- results, do: pdf

      assert length(writes) == @concurrency
      assert Enum.all?(writes, &match?({:ok, %Editor{}}, &1))
      assert length(snapshots) == @concurrency

      # Every snapshot was taken *between* mutations, never during one: it
      # parses, and its value is one whole written string rather than a torn or
      # missing one. Asserting that a *particular* value shows up would be a
      # timing assertion; a subset check cannot degrade silently, since a torn
      # or absent value fails it just the same.
      for pdf <- snapshots do
        assert <<"%PDF", _::binary>> = pdf

        fields = pdf |> Document.from_binary!() |> Form.fields!()
        assert length(fields) == 3

        value = Enum.find(fields, &(&1.name == "full_name")).value
        assert MapSet.member?(allowed, value)
      end
    end
  end

  describe "open and close cycles" do
    @workers 8
    @cycles 25

    test "many processes opening, reading and closing their own documents" do
      bytes = File.read!(@sample_pdf)

      serial = Document.open!(@sample_pdf)
      expected = Document.text!(serial, 0)
      :ok = Document.close(serial)
      refute expected == ""

      # No handle is shared here. What this exercises is allocation and
      # destruction running concurrently across handles, where a use-after-free
      # or a close racing collection would show.
      results =
        1..@workers
        |> Task.async_stream(
          fn worker ->
            for _ <- 1..@cycles do
              doc =
                if even?(worker),
                  do: Document.open!(@sample_pdf),
                  else: Document.from_binary!(bytes)

              {Document.text!(doc, 0), Document.close(doc), Document.closed?(doc)}
            end
          end,
          max_concurrency: @workers,
          ordered: false,
          timeout: @timeout
        )
        |> Enum.flat_map(fn {:ok, cycles} -> cycles end)

      # Non-vacuity: every cycle ran, so this cannot pass on zero of them.
      assert length(results) == @workers * @cycles
      assert Enum.all?(results, &(&1 == {expected, :ok, true}))
    end
  end

  # Fans `calls` at one handle `@concurrency` times over, shuffled, and asserts
  # every result equals the serial one in `expected`. Mixing the calls beats
  # repeating one: different call paths over a single shared value is the
  # combination sharing a handle uniquely produces.
  defp assert_concurrently_equal(calls, handle, expected) do
    calls
    |> List.duplicate(@concurrency)
    |> List.flatten()
    |> Enum.shuffle()
    |> Task.async_stream(fn {name, call} -> {name, call.(handle)} end,
      max_concurrency: @concurrency,
      ordered: false,
      timeout: @timeout
    )
    |> Enum.each(fn {:ok, {name, actual}} -> assert actual == expected[name] end)
  end

  defp read_until_closed(doc, deadline, acc) do
    outcome = Document.text(doc, 0)
    acc = [outcome | acc]

    cond do
      closed_outcome?(outcome) -> {Enum.reverse(acc), :saw_closed}
      System.monotonic_time(:millisecond) >= deadline -> {Enum.reverse(acc), :deadline}
      true -> read_until_closed(doc, deadline, acc)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @deadline_ms

  defp closed_outcome?({:error, %Error{reason: :closed}}), do: true
  defp closed_outcome?(_outcome), do: false

  defp well_formed_field?(%Field.Text{name: "full_name", value: value}),
    do: is_binary(value)

  defp well_formed_field?(%Field.Button{name: "subscribe", value: value}),
    do: is_boolean(value)

  defp well_formed_field?(%Field.Choice{name: "country", value: nil}), do: true
  defp well_formed_field?(_field), do: false

  defp even?(n), do: rem(n, 2) == 0
end
