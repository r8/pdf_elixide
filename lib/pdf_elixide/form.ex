defmodule PdfElixide.Form do
  @moduledoc """
  Representation of the form fields within a PDF document.
  """
  alias PdfElixide.Document
  alias PdfElixide.Form.Field
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @doc """
  Extracts form fields from the given PDF document.
  """
  @spec fields(Document.t()) :: {:ok, [Field.t()]} | {:error, term()}
  def fields(%Document{ref: ref}) do
    Wrap.call(fn -> Native.document_form_fields(ref) end)
  end

  @doc """
  Extracts form fields from the given PDF document, raising an error if it fails.
  """
  @spec fields!(Document.t()) :: [Field.t()]
  def fields!(%Document{} = doc) do
    case fields(doc) do
      {:ok, fields} -> fields
      {:error, error} -> raise error
    end
  end
end
