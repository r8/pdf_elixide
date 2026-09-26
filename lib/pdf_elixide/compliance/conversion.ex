defmodule PdfElixide.Compliance.Conversion do
  @moduledoc """
  The result of `PdfElixide.Compliance.convert/3`.

    * `:report` — the converted document validated against the requested
      level, as a `PdfElixide.Compliance.Report`. It describes what a full
      write of the editor now produces. Whether the conversion succeeded is
      `report.compliant?`.
    * `:actions` — what the conversion changed, as
      `PdfElixide.Compliance.Conversion.Action` structs, in the order they were
      made.
    * `:failures` — problems the conversion found and left in place, as
      `PdfElixide.Compliance.Conversion.Failure` structs. Each one is still
      listed in the report's errors, unless a later change resolved it.
  """

  alias PdfElixide.Compliance.Conversion.Action
  alias PdfElixide.Compliance.Conversion.Failure
  alias PdfElixide.Compliance.Report

  @enforce_keys [:report, :actions, :failures]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          report: Report.t(),
          actions: [Action.t()],
          failures: [Failure.t()]
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{report: report, actions: actions, failures: failures}) do
    %__MODULE__{
      report: Report.from_nif(report),
      actions: Enum.map(actions, &Action.from_nif/1),
      failures: Enum.map(failures, &Failure.from_nif/1)
    }
  end
end
