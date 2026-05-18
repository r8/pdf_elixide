defmodule PdfElixide.Native do
  @moduledoc false

  use Rustler,
    otp_app: :pdf_elixide,
    crate: :pdf_elixide_nif

  # PdfDocument operations
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)
  def from_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def page_count(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def version(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def extract_text(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)
end
