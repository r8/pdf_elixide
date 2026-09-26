defmodule PdfElixide.Compliance.Report do
  @moduledoc """
  The result of `PdfElixide.Compliance.validate/2`.

    * `:standard` — the standard the document was checked against, as
      requested.
    * `:compliant?` — `true` when the checks found no errors. Warnings do not
      affect it. See [What a report
      establishes](`m:PdfElixide.Compliance#module-what-a-report-establishes`).
    * `:declared` — the PDF/A or PDF/X level the document identifies itself as
      in its own metadata, or `nil` when it declares none. It is read whichever
      level was requested, so a document validated against `:pdf_a_2b` may
      declare `:pdf_a_1b`. Always `nil` for PDF/UA.
    * `:errors` — the requirements the document fails, as
      `PdfElixide.Compliance.Issue` structs.
    * `:warnings` — findings that do not fail the standard, including notes on
      checks that were only partly performed.
  """

  alias PdfElixide.Compliance
  alias PdfElixide.Compliance.Issue

  @enforce_keys [:standard, :compliant?, :declared, :errors, :warnings]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          standard: Compliance.standard(),
          compliant?: boolean(),
          declared: Compliance.standard() | nil,
          errors: [Issue.t()],
          warnings: [Issue.t()]
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        standard: standard,
        compliant: compliant,
        declared: declared,
        errors: errors,
        warnings: warnings
      }) do
    %__MODULE__{
      standard: standard,
      compliant?: compliant,
      declared: declared,
      errors: Enum.map(errors, &Issue.from_nif/1),
      warnings: Enum.map(warnings, &Issue.from_nif/1)
    }
  end
end
