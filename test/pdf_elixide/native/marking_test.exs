defmodule PdfElixide.Native.MarkingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  # add_redaction also marks the page, so it must enable the scan; it stays
  # listed although only the wrapper calls it, in case a NIF reaches upstream's.
  @marking_calls [
    ".apply_page_redactions(",
    ".apply_all_redactions(",
    ".add_redaction(",
    ".flatten_forms()",
    ".flatten_forms_on_page(",
    ".flatten_all_annotations()",
    ".flatten_page_annotations("
  ]

  setup_all do
    {:ok, nifs: PdfElixide.NifSource.nifs()}
  end

  test "every NIF that marks a page records the category", %{nifs: nifs} do
    offenders =
      for %{file: file, name: name, body: body} <- nifs,
          Enum.any?(@marking_calls, &String.contains?(body, &1)),
          not String.contains?(body, ".mark("),
          do: "#{file}: #{name}"

    assert offenders == [],
           """
           These NIFs mark a page for redaction or flattening without calling
           `OpenEditor::mark`, which gates the sweep that reports the mark to
           `dropped_by_an_incremental_save`. An incremental save would write a
           file missing the mark and report success. Add the call, naming the
           category the NIF marked:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}
           """
  end

  # The assertion above is vacuous if the parse finds no marking call at all.
  # `add_redaction` is spelled only in the wrapper, so that file joins the corpus.
  test "the marking calls are still spelled the way this test greps for them", %{nifs: nifs} do
    wrapper = File.read!(Path.join(PdfElixide.NifSource.src_dir(), "open_editor.rs"))
    corpus = [wrapper | Enum.map(nifs, & &1.body)]

    found =
      for call <- @marking_calls,
          Enum.any?(corpus, &String.contains?(&1, call)),
          do: call

    assert found == @marking_calls
  end
end
