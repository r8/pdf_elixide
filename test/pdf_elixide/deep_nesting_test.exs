defmodule PdfElixide.DeepNestingTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor

  # The catalog nests 3,000 arrays.
  @deep_pdf Path.join([__DIR__, "..", "fixtures", "deep_nesting.pdf"])

  test "a document opens, extracts and closes" do
    doc = Document.open!(@deep_pdf)

    assert {:ok, _} = Document.text(doc, 0)
    assert :ok = Document.close(doc)
  end

  test "a document read from a binary is released by garbage collection" do
    {:ok, _} = Document.from_binary(File.read!(@deep_pdf))

    :erlang.garbage_collect()
  end

  test "an editor rewrites the document" do
    editor = Editor.open!(@deep_pdf)

    assert {:ok, pdf} = Editor.to_binary(editor)
    assert Document.from_binary!(pdf).page_count == 1
    assert :ok = Editor.close(editor)
  end
end
