defmodule PdfElixide.Form do
  @moduledoc """
  AcroForm field access for documents and editors.

  `fields/1` reads from *either* source — a read-only `PdfElixide.Document` or a
  mutable `PdfElixide.Editor` (`t:source/0`) — so inspecting a form needs no
  editor. `field/2` and `value/2` answer for one named field from the same two
  sources. Writing needs an editor: `set_value/3` takes an `Editor` only, since
  a document cannot be changed.

      # Inspect, read-only.
      doc = PdfElixide.Document.open!("form.pdf")
      fields = PdfElixide.Form.fields!(doc)
      PdfElixide.Form.value!(doc, "full_name")
      #=> {:text, "John Doe"}

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
  `{:error, %PdfElixide.Error{reason: :not_found}}`, from `field/2` and
  `value/2` as much as from `set_value/3`.

  Which lock `fields/1` takes follows its source: a shared read on a
  `PdfElixide.Document`, and the editor's exclusive lock on a
  `PdfElixide.Editor`, exactly as `set_value/3` takes. `field/2` and `value/2`
  take the same lock and cost the same, so reading several fields one at a time
  costs more than one `fields/1`. So concurrent form work on one editor
  serializes even when it only reads; see the
  [Concurrency](guides/concurrency.md) guide.
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
    fields(source) |> Wrap.unwrap!()
  end

  @doc """
  Returns the single form field carrying the given name.

  The name is the fully qualified one `PdfElixide.Form.Field` describes. A name
  that is not in the form is `{:error, %PdfElixide.Error{reason: :not_found}}`;
  a form with two fields of the same name answers with the first.

      PdfElixide.Form.field(doc, "full_name")
      #=> {:ok, %PdfElixide.Form.Field{kind: :text, value: {:text, "John Doe"}}}

  """
  @spec field(source(), String.t()) :: {:ok, Field.t()} | {:error, Error.t()}
  def field(source, name) when is_binary(name) do
    with {:ok, fields} <- fields(source) do
      case Enum.find(fields, &(&1.name == name)) do
        %Field{} = field -> {:ok, field}
        nil -> {:error, not_found(name)}
      end
    end
  end

  @doc """
  Same as `field/2` but raises an error if it fails.
  """
  @spec field!(source(), String.t()) :: Field.t()
  def field!(source, name) when is_binary(name) do
    field(source, name) |> Wrap.unwrap!()
  end

  @doc """
  Returns the value of the single form field carrying the given name.

  `{:ok, nil}` means the field exists but carries no value — distinct from
  `{:error, %PdfElixide.Error{reason: :not_found}}`, which means no field
  carries that name. Reach for `field/2` when the field's `:kind` is needed too.

      PdfElixide.Form.value(doc, "full_name")
      #=> {:ok, {:text, "John Doe"}}

  """
  @spec value(source(), String.t()) :: {:ok, Field.value()} | {:error, Error.t()}
  def value(source, name) when is_binary(name) do
    with {:ok, %Field{value: value}} <- field(source, name), do: {:ok, value}
  end

  @doc """
  Same as `value/2` but raises an error if it fails.
  """
  @spec value!(source(), String.t()) :: Field.value()
  def value!(source, name) when is_binary(name) do
    value(source, name) |> Wrap.unwrap!()
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
    # Local `case` rather than `Wrap.unwrap!/1`: `set_value/3` answers a bare
    # `:ok`, not `{:ok, value}`, so there is no payload to unwrap.
    case set_value(editor, name, value) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  # Mirrors upstream's own message for this condition, which `set_value/3`
  # propagates with the same reason atom.
  defp not_found(name) do
    %Error{reason: :not_found, message: "Form field not found: #{name}"}
  end
end
