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

  @doc """
  Sets the value of an existing form field on the given editor.

  The value uses the same tagged-tuple shape returned by `fields/1`
  (e.g. `{:text, "Jane Doe"}`, `{:boolean, true}`, `nil`).
  """
  @spec set_value(Editor.t(), String.t(), Field.value()) :: :ok | {:error, term()}
  def set_value(%Editor{ref: ref}, name, value) when is_binary(name) do
    case Wrap.call(fn -> Native.editor_set_form_field_value(ref, name, value) end) do
      {:ok, :ok} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Sets the value of an existing form field on the given editor,
  raising an error if it fails.
  """
  @spec set_value!(Editor.t(), String.t(), Field.value()) :: :ok
  def set_value!(%Editor{} = editor, name, value) when is_binary(name) do
    case set_value(editor, name, value) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
