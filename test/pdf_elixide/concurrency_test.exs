defmodule PdfElixide.ConcurrencyTest do
  @moduledoc """
  One `%Document{}` handle, read from many processes at once.

  Every read-only document NIF takes the handle's lock *shared*
  (`Closable::with_read`), which is what the "Sharing a document across
  processes" section of `PdfElixide.Document` promises callers. What is asserted
  here is the half that can be asserted — that sharing a handle still returns the
  *right* answers — and not the speedup: `RwLock` fairness, the size of the
  dirty-CPU pool and upstream's own cold-load serialization would all make a
  timing assertion flaky while pinning nothing. That reads really do overlap is
  pinned deterministically in Rust instead, by `two_with_read_calls_overlap` in
  `native/pdf_elixide_nif/src/resource.rs`.

  Correctness is the risk the shared lock actually took on. Upstream's interior
  mutability — a `Mutex` object cache, lazily built page and font caches, an
  encryption handler initialized on first use — was previously reached by one
  thread at a time no matter what the caller did. Interleaving *different*
  extractors matters more than repeating one, since each drives a different
  loader over the same caches, which is why the second test mixes them rather
  than fanning one call out wider.

  `authenticate/2` is deliberately not exercised concurrently: it is the one
  document call that keeps an exclusive lock, and a test for it could only pass
  vacuously — a reader that happens to run entirely before or entirely after the
  transition proves nothing. `with_lock_excludes_a_concurrent_reader`, alongside
  the overlap test above, carries that claim instead.
  """
  use ExUnit.Case, async: true

  alias PdfElixide.Document

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  @concurrency 16

  # Generous on purpose: correctness, not latency, is what is being asserted.
  @timeout 60_000

  setup do
    doc = Document.open!(Path.join(@fixtures_dir, "sample.pdf"))
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
