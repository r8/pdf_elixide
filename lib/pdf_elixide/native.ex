defmodule PdfElixide.Native do
  @moduledoc false

  use Rustler,
    otp_app: :pdf_elixide,
    crate: :pdf_elixide_nif

  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
