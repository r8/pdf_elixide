defmodule PdfElixide.Form do
  @moduledoc """
  AcroForm field access for documents and editors.

  `fields/1` reads from *either* source — a read-only `PdfElixide.Document` or a
  mutable `PdfElixide.Editor` (`t:source/0`) — so inspecting a form needs no
  editor. Writing does: `set_value/3` takes an `Editor` only, since a document
  cannot be changed.

      # Inspect, read-only.
      doc = PdfElixide.Document.open!("form.pdf")
      fields = PdfElixide.Form.fields!(doc)

      # Fill and persist.
      editor = PdfElixide.Editor.open!("form.pdf")
      :ok = PdfElixide.Form.set_value(editor, "full_name", {:text, "Jane Doe"})
      :ok = PdfElixide.Form.set_value(editor, "subscribe", {:boolean, true})
      :ok = PdfElixide.Editor.save(editor, "filled.pdf")

  Fields come back as `PdfElixide.Form.Field` structs, and the tagged tuple a
  field's `:value` carries is the same shape `set_value/3` accepts, so a value
  read from one form can be written straight into another.

  Fields are addressed by name, and only an existing field can be set — there is
  no way to add one. A name that is not in the form is
  `{:error, %PdfElixide.Error{}}`.

  Which lock `fields/1` takes follows its source. On a `PdfElixide.Document` it
  is an ordinary shared read, so several processes can list one document's
  fields at once. On a `PdfElixide.Editor` it takes the editor's lock
  *exclusively*, exactly as `set_value/3` and every other editor call does — so
  concurrent form work on one editor serializes, whether it writes or only
  reads. See the "Sharing a document across processes" section of
  `PdfElixide.Document`.
  """

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form.Field
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @type source :: Document.t() | Editor.t()

  @doc """
  Extracts form fields from the given PDF document or editor.
  """
  @spec fields(source()) :: {:ok, [Field.t()]} | {:error, Error.t()}
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
  @spec set_value(Editor.t(), String.t(), Field.value()) :: :ok | {:error, Error.t()}
  def set_value(%Editor{ref: ref}, name, value) when is_binary(name) do
    case Wrap.call(fn -> Native.editor_set_form_field_value(ref, name, value) end) do
      {:ok, _} -> :ok
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
