defmodule PdfElixide.Native do
  @moduledoc false

  use Rustler,
    otp_app: :pdf_elixide,
    crate: :pdf_elixide_nif

  # Document operations
  def document_open(_path), do: err()
  def document_from_bytes(_bytes), do: err()
  def document_page_count(_doc), do: err()
  def document_version(_doc), do: err()
  def document_extract_text(_doc, _page_index), do: err()
  def document_form_fields(_doc), do: err()

  # Editor operations
  def editor_open(_path), do: err()
  def editor_from_bytes(_bytes), do: err()
  def editor_form_fields(_editor), do: err()
  def editor_set_form_field_value(_editor, _name, _value), do: err()
  def editor_to_bytes(_editor), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
