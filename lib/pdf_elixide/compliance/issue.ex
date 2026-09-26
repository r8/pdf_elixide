defmodule PdfElixide.Compliance.Issue do
  @moduledoc """
  One finding in a `PdfElixide.Compliance.Report`, an error or a warning.

    * `:code` — the finding's identifier, such as `"FONT-001"`, `"UA-FIG-001"`
      or `"XMETA-001"`. The prefix names the area checked; codes are strings
      to match on.
    * `:message` — a human-readable description.
    * `:clause` — the clause of the standard the finding refers to, such as
      `"6.1.4"`, or `nil` when none is given. PDF/A and PDF/UA warnings never
      carry one.
    * `:location` — where in the document the finding applies, as free text, or
      `nil`. Given for PDF/A and PDF/UA only.
    * `:page` — the zero-based index of the page the finding applies to, or
      `nil`. Given for PDF/X only.
    * `:object` — the number of the PDF object the finding applies to, or `nil`.
      Given for PDF/X only.
    * `:wcag` — the WCAG success criterion a PDF/UA finding maps to, or `nil`.
  """

  @enforce_keys [:code, :message, :clause, :location, :page, :object, :wcag]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          clause: String.t() | nil,
          location: String.t() | nil,
          page: non_neg_integer() | nil,
          object: non_neg_integer() | nil,
          wcag: String.t() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        code: code,
        message: message,
        clause: clause,
        location: location,
        page: page,
        object: object,
        wcag: wcag
      }) do
    %__MODULE__{
      code: code,
      message: message,
      clause: clause,
      location: location,
      page: page,
      object: object,
      wcag: wcag
    }
  end
end
