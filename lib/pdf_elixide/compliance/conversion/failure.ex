defmodule PdfElixide.Compliance.Conversion.Failure do
  @moduledoc """
  A finding `PdfElixide.Compliance.convert/3` could not resolve.

    * `:code` — the finding's code, such as `"FONT-001"`, matching
      `PdfElixide.Compliance.Issue`'s `:code`.
    * `:reason` — why it was left in place: a conversion option turned the
      fix off, or no automatic fix exists.
  """

  @enforce_keys [:code, :reason]

  defstruct @enforce_keys

  @type t :: %__MODULE__{code: String.t(), reason: String.t()}

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{code: code, reason: reason}) do
    %__MODULE__{code: code, reason: reason}
  end
end
