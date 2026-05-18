defmodule PdfElixide.Native do
  @moduledoc false

  use Rustler,
    otp_app: :pdf_elixide,
    crate: :pdf_elixide_nif

  # PdfDocument operations
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)
  def from_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)
end
