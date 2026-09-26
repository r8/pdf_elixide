defmodule PdfElixide.Compliance do
  @moduledoc """
  Checks a document against the PDF/A, PDF/UA and PDF/X standards.

      {:ok, doc} = PdfElixide.Document.open("report.pdf")
      {:ok, report} = PdfElixide.Compliance.validate(doc, :pdf_a_2b)
      report.compliant?
      #=> false
      Enum.map(report.errors, & &1.code)
      #=> ["XMP-001", …]

  `validate/2` returns a `PdfElixide.Compliance.Report` listing the errors and
  warnings found. A document that fails a standard is an ordinary report with
  `compliant?: false`, not an error; `{:error, %PdfElixide.Error{}}` means the
  document could not be read far enough to check it.

  ## What a report establishes

  Validation runs this library's own checks for the requested standard, which
  cover a subset of each standard's requirements. `compliant?: true` means those
  checks found no errors; it is not a conformance certification. Use a dedicated
  conformance validator where a claim of compliance has to hold up.

  PDF/A and PDF/UA reports list checks that were only partly performed among
  their warnings, under code `"WARN-007"`, so even a report with no errors
  carries warnings.

  PDF/A and PDF/X forbid encryption, so an encrypted document always fails them.
  PDF/UA-2 is not offered: this library performs no check specific to it.

  PDF/X checks read each page's boxes from the page's own dictionary. A page
  that inherits its `/MediaBox` from the page tree is reported as missing one
  (`"XBOX-004"`), and its boxes are not checked for consistency.

  ## Memory and locking

  Validation reads a private copy of the document, parsed from its bytes, so
  it holds about two extra copies of the file in memory for its duration. It
  takes a *shared* read on the handle, and so runs alongside other reads — with
  one exception: a document that cannot be opened without a password is
  validated in place and takes the handle *exclusively*. See the
  [Concurrency](guides/concurrency.md) guide.
  """

  alias PdfElixide.Compliance.Report
  alias PdfElixide.Document
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @typedoc """
  A standard and level to validate against.

    * PDF/A: `:pdf_a_1a`, `:pdf_a_1b`, `:pdf_a_2a`, `:pdf_a_2b`, `:pdf_a_2u`,
      `:pdf_a_3a`, `:pdf_a_3b`, `:pdf_a_3u`.
    * PDF/UA: `:pdf_ua_1`.
    * PDF/X: `:pdf_x_1a_2001`, `:pdf_x_1a_2003`, `:pdf_x_3_2002`,
      `:pdf_x_3_2003`, `:pdf_x_4`, `:pdf_x_4p`, `:pdf_x_5g`, `:pdf_x_5n`,
      `:pdf_x_5pg`, `:pdf_x_6`.
  """
  @type standard ::
          :pdf_a_1a
          | :pdf_a_1b
          | :pdf_a_2a
          | :pdf_a_2b
          | :pdf_a_2u
          | :pdf_a_3a
          | :pdf_a_3b
          | :pdf_a_3u
          | :pdf_ua_1
          | :pdf_x_1a_2001
          | :pdf_x_1a_2003
          | :pdf_x_3_2002
          | :pdf_x_3_2003
          | :pdf_x_4
          | :pdf_x_4p
          | :pdf_x_5g
          | :pdf_x_5n
          | :pdf_x_5pg
          | :pdf_x_6

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

  @doc """
  Validates the document against `standard`.

  Returns `{:ok, report}` whether or not the document complies; see
  `PdfElixide.Compliance.Report`. An atom that is not a `t:standard/0` raises
  `ArgumentError`. An encrypted document opened without its password returns
  `{:error, %PdfElixide.Error{reason: :encrypted}}` until
  `PdfElixide.Document.authenticate/2` succeeds.
  """
  @spec validate(Document.t(), standard()) :: {:ok, Report.t()} | {:error, Error.t()}
  def validate(%Document{ref: ref}, standard) when is_atom(standard) do
    standard = validate_standard!(standard)

    with {:ok, report} <- Wrap.call(fn -> Native.document_validate(ref, standard) end) do
      {:ok, Report.from_nif(report)}
    end
  end

  @doc """
  Validates the document against `standard`, raising an error if it cannot be
  checked.
  """
  @spec validate!(Document.t(), standard()) :: Report.t()
  def validate!(%Document{} = doc, standard) when is_atom(standard) do
    validate(doc, standard) |> Wrap.unwrap!()
  end

  # The NIF rejects an unknown atom too, but as a decode error rather than an
  # `ArgumentError` naming it.
  defp validate_standard!(standard) when standard in @standards, do: standard

  defp validate_standard!(other) do
    raise ArgumentError, "unsupported compliance standard #{inspect(other)}"
  end
end
