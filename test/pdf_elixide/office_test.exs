defmodule PdfElixide.OfficeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Document
  alias PdfElixide.Error
  alias PdfElixide.Office

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @sample_pdf Path.join(@fixtures, "sample.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @encrypted_objstm_pdf Path.join(@fixtures, "encrypted_objstm.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  @password "secret"

  @exports [
    to_docx: "word/document.xml",
    to_pptx: "ppt/presentation.xml",
    to_xlsx: "xl/workbook.xml"
  ]
  @modes [:auto, :layout, :flow]

  defp open(path, opts \\ []) do
    doc = Document.open!(path, opts)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp parts(package) do
    {:ok, files} = :zip.unzip(package, [:memory])
    Map.new(files, fn {name, data} -> {to_string(name), data} end)
  end

  defp rezip(package, fun) do
    {:ok, parts} = :zip.unzip(package, [:memory])
    {:ok, {_, zipped}} = :zip.create(~c"x.zip", Enum.map(parts, fun), [:memory])
    zipped
  end

  defp pdf_text(pdf) do
    doc = Document.from_binary!(pdf)
    on_exit(fn -> Document.close(doc) end)
    {doc.page_count, Document.text!(doc)}
  end

  describe "export" do
    test "writes each format's main part, carrying the document's text" do
      doc = open(@sample_pdf)

      for {export, main_part} <- @exports, mode <- @modes do
        parts = parts(apply(Document, export, [doc, [mode: mode]]) |> elem(1))

        assert Map.has_key?(parts, main_part), "#{export} #{mode}"

        assert Enum.any?(Map.values(parts), &String.contains?(&1, "Page One")),
               "#{export} #{mode}"
      end
    end

    test ":layout positions each run in a frame and :flow does not" do
      doc = open(@sample_pdf)

      layout = parts(Document.to_docx!(doc, mode: :layout))["word/document.xml"]
      flow = parts(Document.to_docx!(doc, mode: :flow))["word/document.xml"]

      assert layout =~ "w:framePr"
      refute flow =~ "w:framePr"
    end

    test ":auto lays out a short document" do
      doc = open(@sample_pdf)

      for {export, _} <- @exports do
        assert parts(apply(Document, :"#{export}!", [doc])) ==
                 parts(apply(Document, :"#{export}!", [doc, [mode: :layout]]))
      end
    end

    test "round-trips through each format back to the same pages" do
      doc = open(@sample_pdf)

      for package <- [
            Document.to_docx!(doc, mode: :flow),
            Document.to_pptx!(doc, mode: :layout),
            Document.to_pptx!(doc, mode: :flow),
            Document.to_xlsx!(doc, mode: :layout),
            Document.to_xlsx!(doc, mode: :flow)
          ] do
        {pages, text} = pdf_text(Office.to_pdf!(package))

        assert pages == 3
        assert text =~ ~r/Page One\s*\fPage Two\s*\fPage Three/
      end
    end

    # Both fixtures: a plain-xref file reads its page count unauthenticated and
    # an object-stream one does not, so they reach export by different routes.
    test "refuses an encrypted document until it is authenticated" do
      for path <- [@encrypted_pdf, @encrypted_objstm_pdf] do
        doc = open(path)

        for {export, _} <- @exports do
          assert {:error, %Error{reason: :encrypted}} = apply(Document, export, [doc])
        end

        assert Document.authenticate!(doc, @password)
        assert {:ok, _} = Document.to_docx(doc)
        assert {:ok, _} = Document.to_docx(open(path, password: @password))
      end
    end

    test "fails on a page it cannot read, like the other whole-document converters" do
      doc = open(@broken_page_pdf)

      for {export, _} <- @exports, mode <- @modes do
        assert {:error, %Error{reason: :invalid_pdf}} =
                 apply(Document, export, [doc, [mode: mode]])
      end
    end

    test "reports a closed handle" do
      doc = Document.open!(@sample_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Document.to_docx(doc)
      assert_raise Error, fn -> Document.to_xlsx!(doc) end
    end

    test "raises ArgumentError for a mode it does not know" do
      doc = open(@sample_pdf)

      assert_raise ArgumentError, ~r/:mode/, fn -> Document.to_pptx(doc, mode: :bogus) end
    end
  end

  describe "import" do
    test "converts each format, detected from the package" do
      for fixture <- ~w(sample.docx sample.pptx sample.xlsx) do
        {pages, text} = pdf_text(Office.to_pdf!(File.read!(Path.join(@fixtures, fixture))))

        assert pages == 3, fixture
        assert text =~ ~r/Page One\s*\fPage Two\s*\fPage Three/, fixture
      end
    end

    test "converts a DOCX this library did not write, honouring its page break" do
      {pages, text} = pdf_text(Office.to_pdf!(File.read!(Path.join(@fixtures, "hello.docx"))))

      assert pages == 2
      assert text =~ "Hello from Word"
      assert text =~ ~r/\fAfter the break/
    end

    test "converts a package whose main part has no content-type override" do
      for target <- ["word/document.xml", "Word/document.xml"] do
        docx =
          rezip(File.read!(Path.join(@fixtures, "hello.docx")), fn
            {~c"[Content_Types].xml", xml} ->
              {~c"[Content_Types].xml", String.replace(xml, ~r/<Override [^>]*>/, "")}

            {~c"_rels/.rels", xml} ->
              {~c"_rels/.rels", String.replace(xml, "word/document.xml", target)}

            part ->
              part
          end)

        {pages, text} = pdf_text(Office.to_pdf!(docx))

        assert pages == 2, target
        assert text =~ "Hello from Word", target
      end
    end

    # Nested deeper than a dirty scheduler's stack can recurse through.
    test "converts deeply nested tables" do
      body =
        Enum.reduce(1..150, "<w:p><w:r><w:t>deep</w:t></w:r></w:p>", fn _, inner ->
          "<w:tbl><w:tr><w:tc>" <> inner <> "<w:p/></w:tc></w:tr></w:tbl>"
        end)

      docx =
        rezip(File.read!(Path.join(@fixtures, "hello.docx")), fn
          {~c"word/document.xml", _} ->
            {~c"word/document.xml",
             ~s(<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">) <>
               "<w:body>" <> body <> "<w:p/></w:body></w:document>"}

          part ->
            part
        end)

      assert {:ok, _} = Office.to_pdf(docx)
    end

    test "refuses a legacy or password-protected Office file as :unsupported" do
      compound = <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1>> <> :binary.copy(<<0>>, 504)

      assert {:error, %Error{reason: :unsupported, message: message}} = Office.to_pdf(compound)
      assert message =~ "legacy binary Office file or a password-protected package"
    end

    test "refuses bytes that are not an Office package as :unsupported" do
      {:ok, {_, odt}} =
        :zip.create(
          ~c"x.odt",
          [
            {~c"[Content_Types].xml",
             ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
               ~s(<Override PartName="/content.xml" ContentType="application/vnd.oasis.opendocument.text"/>) <>
               "</Types>"},
            {~c"content.xml", "<x/>"}
          ],
          [:memory]
        )

      for bytes <- [File.read!(@sample_pdf), "", odt] do
        assert {:error,
                %Error{reason: :unsupported, message: "not a DOCX, PPTX or XLSX package" <> _}} =
                 Office.to_pdf(bytes)
      end

      assert_raise Error, fn -> Office.to_pdf!("") end
    end

    test "reports a recognised package it cannot convert as :other" do
      docx =
        rezip(File.read!(Path.join(@fixtures, "hello.docx")), fn
          {~c"word/document.xml", _} -> {~c"word/document.xml", "<w:document"}
          part -> part
        end)

      assert {:error, %Error{reason: :other}} = Office.to_pdf(docx)
    end

    test "raises FunctionClauseError for input that is not a binary" do
      assert_raise FunctionClauseError, fn -> Office.to_pdf(untyped(~c"docx")) end
    end
  end
end
