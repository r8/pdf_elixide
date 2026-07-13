defmodule PdfElixide.Native do
  @moduledoc false

  mix_config = Mix.Project.config()
  version = mix_config[:version]
  github_url = mix_config[:package][:links]["Source"]

  use RustlerPrecompiled,
    otp_app: :pdf_elixide,
    crate: :pdf_elixide_nif,
    base_url: "#{github_url}/releases/download/v#{version}",
    version: version

  # Document operations
  def document_open(_path, _options), do: err()
  def document_from_bytes(_bytes, _options), do: err()
  def document_version(_doc), do: err()
  def document_page_count(_doc), do: err()
  def document_has_structure_tree(_doc), do: err()
  def document_is_encrypted(_doc), do: err()
  def document_authenticate(_doc, _password), do: err()
  def document_extract_text(_doc, _page_index), do: err()
  def document_extract_all_text(_doc), do: err()
  def document_get_page_width(_doc, _page_index), do: err()
  def document_get_page_height(_doc, _page_index), do: err()
  def document_form_fields(_doc), do: err()

  # Editor operations
  def editor_open(_path), do: err()
  def editor_from_bytes(_bytes), do: err()
  def editor_form_fields(_editor), do: err()
  def editor_set_form_field_value(_editor, _name, _value), do: err()
  def editor_to_bytes(_editor, _options), do: err()
  def editor_save(_editor, _path, _options), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
