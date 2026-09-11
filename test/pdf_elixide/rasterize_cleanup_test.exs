defmodule PdfElixide.RasterizeCleanupTest do
  @moduledoc false
  # Run alone: every rasterize call on the node shares the directory under test.
  use ExUnit.Case, async: false

  alias PdfElixide.Document
  alias PdfElixide.Error

  @media_box_pdf Elixir.Path.join([__DIR__, "..", "fixtures", "media_box.pdf"])

  defp flatten_dir do
    Elixir.Path.join(System.tmp_dir!(), "pdf_oxide_flatten_#{:os.getpid()}")
  end

  test "a rasterize that fails part-way leaves no page images behind" do
    doc = Document.open!(@media_box_pdf)
    on_exit(fn -> Document.close(doc) end)

    # The reversed-corner page fails after page 0 is written; a preflight refusal
    # would pass the cleanup assertion without creating the directory.
    assert {:error, %Error{reason: :invalid_pdf}} = Document.rasterize(doc, dpi: 18)

    refute File.exists?(flatten_dir())
  end
end
