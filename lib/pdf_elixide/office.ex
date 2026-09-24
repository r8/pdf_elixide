defmodule PdfElixide.Office do
  @moduledoc """
  Converts Word, PowerPoint and Excel files to PDF.

  `to_pdf/1` takes the bytes of a `.docx`, `.pptx` or `.xlsx` file and returns
  the bytes of a new PDF. Open the result to read it, or write it out as it is:

      {:ok, pdf} = PdfElixide.Office.to_pdf(File.read!("report.docx"))
      File.write!("report.pdf", pdf)

  The format is read from the file's own package, not from a name or an
  argument, so macro-enabled and template variants (`.docm`, `.dotx`, `.pptm`,
  `.ppsx`, `.xlsm`, …) are accepted too. The older binary formats (`.doc`,
  `.ppt`, `.xls`) and password-protected files are not.

  To convert the other way, see `PdfElixide.Document.to_docx/2`,
  `PdfElixide.Document.to_pptx/2` and `PdfElixide.Document.to_xlsx/2`. The
  [Office documents](guides/office.md) guide covers both directions, including
  how an import depends on fonts installed on the host.
  """

  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @doc """
  Converts a DOCX, PPTX or XLSX file to a new PDF and returns the PDF's bytes.

  Bytes that cannot be read as one of those packages — including a PDF, a zip
  file holding something else, a truncated or corrupted zip, or a
  password-protected Office file — return
  `{:error, %PdfElixide.Error{reason: :unsupported}}`. A package that is
  recognised but cannot be converted returns `{:error, %PdfElixide.Error{}}`
  with reason `:other`.

  A DOCX exported with `mode: :layout` does not keep its pages when converted
  back; see [Round trips](guides/office.md#round-trips).
  """
  @spec to_pdf(binary()) :: {:ok, binary()} | {:error, Error.t()}
  def to_pdf(bytes) when is_binary(bytes) do
    Wrap.call(fn -> Native.office_to_pdf(bytes) end)
  end

  @doc """
  Converts a DOCX, PPTX or XLSX file to a new PDF, raising an error if it fails.
  """
  @spec to_pdf!(binary()) :: binary()
  def to_pdf!(bytes) when is_binary(bytes) do
    to_pdf(bytes) |> Wrap.unwrap!()
  end
end
