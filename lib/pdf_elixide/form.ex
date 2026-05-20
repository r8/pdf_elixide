defmodule PdfElixide.Form do
  @moduledoc """
  Representation of the form fields within a PDF document.
  """
  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Form.Field
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @type source :: Document.t() | Editor.t()

  @doc """
  Extracts form fields from the given PDF document or editor.
  """
  @spec fields(source()) :: {:ok, [Field.t()]} | {:error, term()}
  def fields(%Document{ref: ref}) do
    Wrap.call(fn -> Native.document_form_fields(ref) end)
  end

  def fields(%Editor{ref: ref}) do
    Wrap.call(fn -> Native.editor_form_fields(ref) end)
  end

  @doc """
  Extracts form fields from the given PDF document or editor,
  raising an error if it fails.
  """
  @spec fields!(source()) :: [Field.t()]
  def fields!(source) do
    case fields(source) do
      {:ok, fields} -> fields
      {:error, error} -> raise error
    end
  end
end
