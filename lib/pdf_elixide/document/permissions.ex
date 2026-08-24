defmodule PdfElixide.Document.Permissions do
  @moduledoc """
  Decoded `/P` permission flags from a PDF's standard encryption dictionary
  (ISO 32000-1 §7.6.3.2, Table 22).

  Obtain it with `PdfElixide.Document.permissions/1`, which answers `{:ok, nil}`
  for a document that is not encrypted (and therefore has no permission
  dictionary).

  Per the PDF specification these flags are **advisory** — conforming readers are
  not required to enforce them. They are surfaced so that callers who wish to
  honor them can.

  ## Fields

    * `:print_low_res` — print (low resolution).
    * `:modify` — modify contents (other than annotation / form fill).
    * `:copy` — copy or extract text and graphics.
    * `:annotate` — add or modify annotations and fill form fields.
    * `:fill_forms` — fill interactive form fields (revision ≥ 3).
    * `:accessibility` — extract text/graphics for accessibility (revision ≥ 3).
    * `:assemble` — insert, rotate, or delete pages (revision ≥ 3).
    * `:print_high_res` — print at high resolution (revision ≥ 3).
    * `:raw` — the raw two's-complement `/P` integer, for callers that need the
      undecoded value.
  """

  @enforce_keys [
    :print_low_res,
    :modify,
    :copy,
    :annotate,
    :fill_forms,
    :accessibility,
    :assemble,
    :print_high_res,
    :raw
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          print_low_res: boolean(),
          modify: boolean(),
          copy: boolean(),
          annotate: boolean(),
          fill_forms: boolean(),
          accessibility: boolean(),
          assemble: boolean(),
          print_high_res: boolean(),
          raw: integer()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        print_low_res: print_low_res,
        modify: modify,
        copy: copy,
        annotate: annotate,
        fill_forms: fill_forms,
        accessibility: accessibility,
        assemble: assemble,
        print_high_res: print_high_res,
        raw: raw
      }) do
    %__MODULE__{
      print_low_res: print_low_res,
      modify: modify,
      copy: copy,
      annotate: annotate,
      fill_forms: fill_forms,
      accessibility: accessibility,
      assemble: assemble,
      print_high_res: print_high_res,
      raw: raw
    }
  end
end
