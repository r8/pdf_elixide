defmodule PdfElixide.PageTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")

  describe "inspect/1" do
    test "renders the page index" do
      doc = Document.open!(@valid_pdf)
      assert inspect(Document.page!(doc, 2)) == "#PdfElixide.Page<2>"
    end
  end
end
