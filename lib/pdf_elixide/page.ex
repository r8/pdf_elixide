defmodule PdfElixide.Page do
  @moduledoc """
  Representation of a page of a PDF document.
  """

  alias PdfElixide.Document

  @enforce_keys [:doc, :index]
  defstruct [:doc, :index]

  @type t :: %__MODULE__{
          doc: Document.t(),
          index: non_neg_integer()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Page{index: index}, _opts) do
      concat(["#PdfElixide.Page<", to_string(index), ">"])
    end
  end
end
