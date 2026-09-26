defmodule PdfElixide.ComplianceConversionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Compliance
  alias PdfElixide.Compliance.Conversion
  alias PdfElixide.Compliance.Conversion.Action
  alias PdfElixide.Compliance.Conversion.Failure
  alias PdfElixide.Compliance.Report
  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @sample_pdf Path.join(@fixtures, "sample.pdf")
  @sanitize_pdf Path.join(@fixtures, "sanitize.pdf")
  @fonts_pdf Path.join(@fixtures, "fonts.pdf")
  @symbol_font_pdf Path.join(@fixtures, "symbol_font.pdf")
  @metadata_pdf Path.join(@fixtures, "metadata.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @password "secret"

  defp open(path, opts \\ []) do
    editor = Editor.open!(path, opts)
    on_exit(fn -> Editor.close(editor) end)
    editor
  end

  defp written(editor) do
    doc = Document.from_binary!(Editor.to_binary!(editor))
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp types(%Conversion{actions: actions}), do: Enum.map(actions, & &1.type)
  defp codes(list), do: Enum.map(list, & &1.code)

  describe "convert/3" do
    test "reports the document a full write now produces" do
      editor = open(@sample_pdf)

      assert {:ok, %Conversion{report: %Report{} = report} = conversion} =
               Compliance.convert(editor, :pdf_a_2b)

      assert %Report{standard: :pdf_a_2b, declared: :pdf_a_2b, compliant?: true} = report
      assert [:added_xmp_metadata, :added_output_intent] = types(conversion)
      assert [%Action{fixed: "XMP-001"}, %Action{}] = conversion.actions
      assert conversion.failures == []

      assert Compliance.validate!(written(editor), :pdf_a_2b) == report
    end

    test "writes pending edits into the document first" do
      editor = open(@sample_pdf)
      Editor.delete_page!(editor, 0)
      Editor.embed_file!(editor, "data.csv", "a,b", relationship: :data)

      Compliance.convert!(editor, :pdf_a_3b)

      assert Editor.page_count!(editor) == 2
      assert [%{name: "data.csv"}] = Editor.embedded_files!(editor)
      assert written(editor).page_count == 2
    end

    test "leaves the editor modified until a full write" do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_2b)

      assert Editor.modified?(editor)
      Editor.to_binary!(editor)
      refute Editor.modified?(editor)
    end

    @tag :tmp_dir
    test "refuses an incremental save afterwards", %{tmp_dir: dir} do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_2b)
      path = Path.join(dir, "out.pdf")

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, path, incremental: true)

      assert message =~ "converted to PDF/A"
      assert {:ok, ^editor} = Editor.save(editor, path)
    end

    @tag :tmp_dir
    test "refuses an encrypted write afterwards", %{tmp_dir: dir} do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_2b)
      encryption = [encryption: [user_password: @password]]

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.to_binary(editor, encryption)

      assert message =~ "PDF/A"

      assert {:error, %Error{reason: :unsupported}} =
               Editor.save(editor, Path.join(dir, "out.pdf"), encryption)

      refute Document.encrypted?(written(editor))
    end

    @tag :tmp_dir
    test "refuses a compressed write after a PDF/A-1 conversion", %{tmp_dir: dir} do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_1b)
      path = Path.join(dir, "out.pdf")

      assert {:error, %Error{reason: :unsupported, message: message}} = Editor.to_binary(editor)
      assert message =~ "compress: false"
      assert {:error, %Error{reason: :unsupported}} = Editor.save(editor, path)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, path, incremental: true)

      assert message =~ "incremental save"

      assert {:ok, pdf} = Editor.to_binary(editor, compress: false)
      assert :binary.match(pdf, "pdfaid:part") != :nomatch
    end

    test "refuses a merge after a PDF/A-1 conversion" do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_1b)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.merge(editor, @fonts_pdf)

      assert message =~ "Nothing has been merged"
      assert Editor.page_count!(editor) == 3
      assert {:ok, _} = Editor.to_binary(editor, compress: false)
    end

    test "keeps the encryption refusal through a later merge" do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_2b)
      Editor.merge!(editor, @fonts_pdf)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.to_binary(editor, encryption: [user_password: @password])

      assert message =~ "PDF/A"
      assert Compliance.validate!(written(editor), :pdf_a_2b).declared == :pdf_a_2b
    end

    test "declares every PDF/A level it converts to" do
      for level <- [
            :pdf_a_1a,
            :pdf_a_1b,
            :pdf_a_2a,
            :pdf_a_2b,
            :pdf_a_2u,
            :pdf_a_3a,
            :pdf_a_3b,
            :pdf_a_3u
          ] do
        editor = open(@sample_pdf)

        assert %Report{standard: ^level, declared: ^level} =
                 Compliance.convert!(editor, level).report

        assert {:ok, _} = Editor.to_binary(editor, compress: false)
      end
    end

    test "refuses a PDF/A-1 declaration it would keep compressed" do
      converted = open(@sample_pdf)
      Compliance.convert!(converted, :pdf_a_1b)
      editor = Editor.from_binary!(Editor.to_binary!(converted, compress: false))
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Compliance.convert(editor, :pdf_a_1b)

      assert message =~ "Nothing has been converted"
      refute Editor.modified?(editor)

      Editor.sanitize!(editor,
        scrub_metadata: true,
        remove_javascript: false,
        remove_embedded_files: false
      )

      assert %Report{declared: :pdf_a_1b} = Compliance.convert!(editor, :pdf_a_1b).report

      assert [dict] =
               Regex.run(
                 ~r{<<[^>]*/Type\s*/Metadata[^>]*>>},
                 Editor.to_binary!(editor, compress: false)
               )

      refute dict =~ "/Filter"
    end

    # `metadata.pdf` carries an uncompressed XMP packet declaring no level.
    test "refuses a PDF/A-1 declaration it would add to existing metadata" do
      editor = open(@metadata_pdf)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Compliance.convert(editor, :pdf_a_1b)

      assert message =~ "existing XMP metadata"
      refute Editor.modified?(editor)

      Editor.sanitize!(editor,
        scrub_metadata: true,
        remove_javascript: false,
        remove_embedded_files: false
      )

      assert %Report{declared: :pdf_a_1b} = Compliance.convert!(editor, :pdf_a_1b).report
    end

    test "lifts the write refusals once the declaration is scrubbed" do
      editor = open(@sample_pdf)
      Compliance.convert!(editor, :pdf_a_1b)

      Editor.sanitize!(editor,
        scrub_metadata: true,
        remove_javascript: false,
        remove_embedded_files: false
      )

      assert Compliance.validate!(written(editor), :pdf_a_1b).declared == nil

      assert {:ok, _} = Editor.to_binary(editor, encryption: [user_password: @password])
    end

    test "refuses a document declaring another level and leaves the editor unchanged" do
      converted = open(@sample_pdf)
      Compliance.convert!(converted, :pdf_a_2b)
      editor = Editor.from_binary!(Editor.to_binary!(converted))
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Compliance.convert(editor, :pdf_a_3b)

      assert message =~ ":pdf_a_2b"
      assert message =~ "Nothing has been converted"
      refute Editor.modified?(editor)
      assert Compliance.validate!(written(editor), :pdf_a_2b).declared == :pdf_a_2b

      assert {:ok, %Conversion{}} = Compliance.convert(editor, :pdf_a_2b)
    end

    test "converts to another level once the declaration is removed" do
      converted = open(@sample_pdf)
      Compliance.convert!(converted, :pdf_a_2b)
      editor = Editor.from_binary!(Editor.to_binary!(converted))
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor,
        scrub_metadata: true,
        remove_javascript: false,
        remove_embedded_files: false
      )

      assert %Report{declared: :pdf_a_3b} = Compliance.convert!(editor, :pdf_a_3b).report
      assert Compliance.validate!(written(editor), :pdf_a_3b).declared == :pdf_a_3b
    end

    test "removes JavaScript unless told not to" do
      assert :removed_javascript in types(Compliance.convert!(open(@sanitize_pdf), :pdf_a_2b))

      conversion = Compliance.convert!(open(@sanitize_pdf), :pdf_a_2b, remove_javascript: false)

      refute :removed_javascript in types(conversion)
      assert [%Failure{code: "CONTENT-002"}] = conversion.failures
      assert "CONTENT-002" in codes(conversion.report.errors)
    end

    test "removes attached files where the level forbids them" do
      editor = open(@sanitize_pdf)
      assert :removed_embedded_files in types(Compliance.convert!(editor, :pdf_a_2b))
      assert Editor.embedded_files!(editor) == []

      kept = open(@sanitize_pdf)
      refute :removed_embedded_files in types(Compliance.convert!(kept, :pdf_a_3b))
      assert [_] = Editor.embedded_files!(kept)

      conversion =
        Compliance.convert!(open(@sanitize_pdf), :pdf_a_2b, remove_embedded_files: false)

      assert "FILE-001" in codes(conversion.failures)
    end

    test "leaves fonts unembedded by default" do
      conversion = Compliance.convert!(open(@fonts_pdf), :pdf_a_2b)

      refute conversion.report.compliant?
      assert [%Failure{code: "FONT-001"}] = conversion.failures
      assert "FONT-001" in codes(conversion.report.errors)
    end

    test "reports an unembedded Symbol font as the validation of the output does" do
      editor = open(@symbol_font_pdf)
      report = Compliance.convert!(editor, :pdf_a_2b).report

      refute report.compliant?
      assert "FONT-001" in codes(report.errors)
      assert Compliance.validate!(written(editor), :pdf_a_2b) == report
    end

    # What the machine has installed decides between the two outcomes.
    test "embeds each missing font or says why not" do
      conversion = Compliance.convert!(open(@fonts_pdf), :pdf_a_2b, embed_fonts: true)

      assert [_ | _] =
               Enum.filter(conversion.actions, &(&1.type == :embedded_font)) ++
                 Enum.filter(conversion.failures, &(&1.code == "FONT-001"))
    end

    test "embeds the ICC profile it is given" do
      editor = open(@sample_pdf)
      profile = :binary.copy("PROFILE!", 16)

      Compliance.convert!(editor, :pdf_a_2b, icc_profile: profile)

      assert :binary.match(Editor.to_binary!(editor, compress: false), profile) != :nomatch
    end

    test "refuses a profile the document's existing output intent would displace" do
      converted = open(@sample_pdf)
      Compliance.convert!(converted, :pdf_a_2b)
      editor = Editor.from_binary!(Editor.to_binary!(converted))
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Compliance.convert(editor, :pdf_a_2b, icc_profile: :binary.copy("PROFILE!", 16))

      assert message =~ ":icc_profile"
      refute Editor.modified?(editor)

      assert {:ok, %Conversion{}} = Compliance.convert(editor, :pdf_a_2b)
    end

    test "sets a language for a level a target and adds no structure" do
      conversion = Compliance.convert!(open(@sample_pdf), :pdf_a_2a)

      assert :added_language in types(conversion)
      refute :added_structure in types(conversion)
      refute conversion.report.compliant?
    end

    test "converts an editor opened with a password and writes it unencrypted" do
      editor = open(@encrypted_pdf, password: @password)

      assert {:ok, %Conversion{}} = Compliance.convert(editor, :pdf_a_2b)
      refute Document.encrypted?(written(editor))
    end

    test "refuses a pending redaction and leaves the editor unchanged" do
      editor = open(@sample_pdf)
      Editor.add_redaction!(editor, 0, %Rect{x: 0.0, y: 0.0, width: 10.0, height: 10.0})

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Compliance.convert(editor, :pdf_a_2b)

      assert message =~ "Nothing has been converted"
      assert Compliance.validate!(written(editor), :pdf_a_2b).declared == nil
    end

    test "refuses an editor with no pages" do
      editor = open(@sample_pdf)
      for _ <- 1..3, do: Editor.delete_page!(editor, 0)

      assert {:error, %Error{reason: :unsupported}} = Compliance.convert(editor, :pdf_a_2b)
    end

    test "reports a closed editor" do
      editor = Editor.open!(@sample_pdf)
      Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Compliance.convert(editor, :pdf_a_2b)
    end

    test "raises ArgumentError for a standard that is not PDF/A" do
      editor = open(@sample_pdf)

      for standard <- [:pdf_ua_1, :pdf_x_4, :pdf_a_4] do
        assert_raise ArgumentError, ~r/#{inspect(standard)}/, fn ->
          Compliance.convert(editor, standard)
        end
      end
    end

    test "raises FunctionClauseError for a standard that is not an atom" do
      editor = open(@sample_pdf)

      assert_raise FunctionClauseError, fn ->
        Compliance.convert(editor, untyped("pdf_a_2b"))
      end
    end

    test "raises ArgumentError naming an option of the wrong type" do
      editor = open(@sample_pdf)

      assert_raise ArgumentError, ~r/:icc_profile/, fn ->
        Compliance.convert(editor, :pdf_a_2b, icc_profile: 1)
      end
    end
  end
end
