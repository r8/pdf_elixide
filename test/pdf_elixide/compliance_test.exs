defmodule PdfElixide.ComplianceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Compliance
  alias PdfElixide.Compliance.Issue
  alias PdfElixide.Compliance.Report
  alias PdfElixide.Document
  alias PdfElixide.Error

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @sample_pdf Path.join(@fixtures, "sample.pdf")
  @tagged_pdf Path.join(@fixtures, "tagged.pdf")
  @declared_pdf Path.join(@fixtures, "compliance_declared.pdf")
  @output_intent_pdf Path.join(@fixtures, "spot_inks_and_intent.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  @owner_only_pdf Path.join(@fixtures, "encrypted_owner_only.pdf")
  @encrypted_objstm_pdf Path.join(@fixtures, "encrypted_objstm.pdf")
  @password "secret"

  @standards [
    :pdf_a_1a,
    :pdf_a_1b,
    :pdf_a_2a,
    :pdf_a_2b,
    :pdf_a_2u,
    :pdf_a_3a,
    :pdf_a_3b,
    :pdf_a_3u,
    :pdf_ua_1,
    :pdf_x_1a_2001,
    :pdf_x_1a_2003,
    :pdf_x_3_2002,
    :pdf_x_3_2003,
    :pdf_x_4,
    :pdf_x_4p,
    :pdf_x_5g,
    :pdf_x_5n,
    :pdf_x_5pg,
    :pdf_x_6
  ]

  defp open(path, opts \\ []) do
    doc = Document.open!(path, opts)
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp codes(issues), do: Enum.map(issues, & &1.code)

  describe "validate/2" do
    test "accepts every documented standard and echoes it" do
      doc = open(@sample_pdf)

      for standard <- @standards do
        assert {:ok, %Report{standard: ^standard, errors: [_ | _]}} =
                 Compliance.validate(doc, standard)
      end
    end

    test "reports a PDF/A failure as a report, not an error" do
      report = Compliance.validate!(open(@sample_pdf), :pdf_a_2b)

      assert %Report{compliant?: false, declared: nil} = report
      assert "XMP-001" in codes(report.errors)

      assert %Issue{clause: "6.7.2", location: nil, page: nil, object: nil, wcag: nil} =
               Enum.find(report.errors, &(&1.code == "XMP-001"))

      assert "WARN-007" in codes(report.warnings)
      assert Enum.all?(report.warnings, &is_nil(&1.clause))
    end

    test "PDF/UA findings carry a WCAG reference" do
      report = Compliance.validate!(open(@sample_pdf), :pdf_ua_1)

      assert %Issue{wcag: "1.3.1", clause: "7.1"} =
               Enum.find(report.errors, &(&1.code == "UA-DOC-001"))

      assert "WARN-007" in codes(report.warnings)
      refute "UA-DOC-001" in codes(Compliance.validate!(open(@tagged_pdf), :pdf_ua_1).errors)
    end

    test "PDF/X findings carry a zero-based page" do
      report = Compliance.validate!(open(@sample_pdf), :pdf_x_4)

      assert "XMETA-001" in codes(report.errors)

      assert [0, 1, 2] ==
               for(%Issue{code: "XBOX-001", page: page} <- report.errors, do: page)

      refute "XMETA-001" in codes(Compliance.validate!(open(@output_intent_pdf), :pdf_x_4).errors)
    end

    # Documented limitation: `sample.pdf` inherits its `/MediaBox` from `/Pages`.
    test "PDF/X reports an inherited MediaBox as missing" do
      report = Compliance.validate!(open(@sample_pdf), :pdf_x_4)

      assert [0, 1, 2] ==
               for(%Issue{code: "XBOX-004", page: page} <- report.errors, do: page)
    end

    test "reports the level a document declares, whatever was requested" do
      doc = open(@declared_pdf)

      assert %Report{declared: :pdf_a_1b} = Compliance.validate!(doc, :pdf_a_1b)
      assert %Report{declared: :pdf_a_1b} = Compliance.validate!(doc, :pdf_a_2b)
      assert %Report{declared: :pdf_x_4} = Compliance.validate!(doc, :pdf_x_1a_2001)
      assert %Report{declared: nil} = Compliance.validate!(doc, :pdf_ua_1)
    end

    test "an encrypted document fails PDF/A whether or not it needs a password" do
      for doc <- [open(@owner_only_pdf), open(@encrypted_pdf, password: @password)] do
        report = Compliance.validate!(doc, :pdf_a_2b)

        assert %Issue{clause: "6.1.4"} =
                 Enum.find(report.errors, &(&1.code == "CONTENT-005"))
      end
    end

    test "a password-protected handle stays usable after validating in place" do
      doc = open(@encrypted_pdf, password: @password)
      text = Document.text!(doc, 0)

      first = Compliance.validate!(doc, :pdf_ua_1)
      assert Compliance.validate!(doc, :pdf_ua_1) == first
      assert Document.text!(doc, 0) == text
    end

    test "refuses an encrypted document opened without its password" do
      for path <- [@encrypted_pdf, @encrypted_objstm_pdf], standard <- [:pdf_a_2b, :pdf_ua_1] do
        assert {:error, %Error{reason: :encrypted}} = Compliance.validate(open(path), standard)
      end
    end

    test "validates once authenticated" do
      doc = open(@encrypted_pdf)
      assert Document.authenticate!(doc, @password)

      assert %Report{} = Compliance.validate!(doc, :pdf_a_2b)
    end

    test "reports a closed document" do
      doc = Document.open!(@sample_pdf)
      Document.close(doc)

      assert {:error, %Error{reason: :closed}} = Compliance.validate(doc, :pdf_a_2b)
      assert_raise Error, fn -> Compliance.validate!(doc, :pdf_a_2b) end
    end

    test "raises ArgumentError for a standard it does not offer" do
      doc = open(@sample_pdf)

      for standard <- [:pdf_ua_2, :pdf_a] do
        assert_raise ArgumentError, ~r/unsupported compliance standard/, fn ->
          Compliance.validate(doc, standard)
        end
      end
    end

    test "raises FunctionClauseError for a standard that is not an atom" do
      doc = open(@sample_pdf)

      assert_raise FunctionClauseError, fn -> Compliance.validate(doc, untyped("pdf_a_2b")) end
      assert_raise FunctionClauseError, fn -> Compliance.validate!(doc, untyped("pdf_a_2b")) end
    end
  end
end
