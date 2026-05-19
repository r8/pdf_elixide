defmodule PdfElixide.Native do
  @moduledoc false

  use Rustler,
    otp_app: :pdf_elixide,
    crate: :pdf_elixide_nif

  # Document operations
  def document_open(_path), do: :erlang.nif_error(:nif_not_loaded)
  def document_from_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def document_page_count(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_version(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_extract_text(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)
end
