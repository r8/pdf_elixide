defmodule PdfElixide.Form do
  @moduledoc """
  AcroForm field access for documents and editors.

  `fields/1`, `field/2` and `value/2` read from *either* source — a read-only
  `PdfElixide.Document` or a mutable `PdfElixide.Editor` (`t:source/0`) — so
  inspecting a form needs no editor. Writing needs one: `put_value/3`,
  `put_values/2` and `update_value/3` take an `Editor` only, and each returns
  it, so filling and saving compose as a pipeline.

      "form.pdf"
      |> PdfElixide.Editor.open!()
      |> PdfElixide.Form.put_value!("full_name", "Jane Doe")
      |> PdfElixide.Editor.save!("filled.pdf")
      |> PdfElixide.Editor.close()

  Fields come back as one struct per field type, listed in
  `PdfElixide.Form.Field`, each carrying the widget it is as a `:kind` and its
  decoded `/Ff` bits as `:flags`, and are addressed by the fully qualified name
  each carries. Only an existing field can be set — there is no way to add one — and
  a name that is not in the form is
  `{:error, %PdfElixide.Error{reason: :not_found}}`, from `field/2` and
  `value/2` as much as from `put_value/3`. Signature fields are not fillable and
  are not reported at all, and writing a check box or radio group back is not
  always faithful.

  A form whose field hierarchy is cyclic, or nested far deeper than any real
  form, is reported as an error by every function here rather than read — a
  cycle as `:invalid_pdf`, a hierarchy past the depth or size limit as
  `:unsupported`.

  Which lock a call takes follows its source: a shared read on a
  `PdfElixide.Document`, and the editor's exclusive lock on a
  `PdfElixide.Editor` — which `fields/1` takes too, so concurrent form work on
  one editor serializes even when it only reads. See the
  [Concurrency](guides/concurrency.md) guide.

  The [Forms](guides/forms.md) guide covers the field structs, both filling
  shapes, saving, and the signature and check-box caveats in full.
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

  A document with no AcroForm answers `{:ok, []}`, as does one whose form
  declares no fields.

  Signature fields are not reported; this API covers fillable form fields only.
  See the [Forms](guides/forms.md) guide.
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
      #=> {:ok, %PdfElixide.Form.Field.Text{name: "full_name", kind: :single_line,
      #     value: "John Doe", flags: %PdfElixide.Form.Field.Text.Flags{…}}}

  """
  @spec field(source(), String.t()) :: {:ok, Field.t()} | {:error, Error.t()}
  def field(source, name) when is_binary(name) do
    with {:ok, fields} <- fields(source) do
      case Enum.find(fields, &(&1.name == name)) do
        nil -> {:error, not_found(name)}
        field -> {:ok, field}
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
  carries that name. Reach for `field/2` when the field's type is needed too.

      PdfElixide.Form.value(doc, "full_name")
      #=> {:ok, "John Doe"}

  """
  @spec value(source(), String.t()) :: {:ok, Field.value()} | {:error, Error.t()}
  def value(source, name) when is_binary(name) do
    # Any-struct match: `Field` is an umbrella over four structs, every one of
    # which carries `:value`.
    with {:ok, %_{value: value}} <- field(source, name), do: {:ok, value}
  end

  @doc """
  Same as `value/2` but raises an error if it fails.
  """
  @spec value!(source(), String.t()) :: Field.value()
  def value!(source, name) when is_binary(name) do
    value(source, name) |> Wrap.unwrap!()
  end

  @doc """
  Writes the value of an existing form field on the given editor, and returns
  the editor it was given.

  The value is a plain term, the same shape `fields/1` returns — a string,
  `true`/`false`, a list of strings, or `nil`. Anything else raises
  `ArgumentError`; see `t:PdfElixide.Form.Field.value/0` for the full set.

      {:ok, editor} = PdfElixide.Form.put_value(editor, "full_name", "Jane Doe")
      {:ok, editor} = PdfElixide.Form.put_value(editor, "subscribe", true)

  Button fields are limited to `/Yes` and `/Off`, and a signature field cannot be
  written at all — it answers `:not_found`. The [Forms](guides/forms.md) guide
  has both.

  """
  @spec put_value(Editor.t(), String.t(), Field.value()) ::
          {:ok, Editor.t()} | {:error, Error.t()}
  def put_value(%Editor{ref: ref} = editor, name, value) when is_binary(name) do
    # `{:ok, _}`, never `{:ok, :ok}`: `Wrap.call/1` wraps any bare NIF return, so
    # pinning the literal would not be exhaustive.
    case Wrap.call(fn -> Native.editor_set_form_field_value(ref, name, value) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes the value of an existing form field on the given editor, raising an
  error if it fails.
  """
  @spec put_value!(Editor.t(), String.t(), Field.value()) :: Editor.t()
  def put_value!(%Editor{} = editor, name, value) when is_binary(name) do
    editor |> put_value(name, value) |> Wrap.unwrap!()
  end

  @doc """
  Writes several form field values on the given editor, and returns the editor.

  Takes a map with string keys, or a list of `{name, value}` pairs.

  Everything is validated before anything is written, against a single `fields/1`
  read. A name the form does not carry — a signature field included — is
  `{:error, %PdfElixide.Error{reason: :not_found}}`, and a duplicated name, a
  name that is not a string, or a value outside
  `t:PdfElixide.Form.Field.value/0` raises `ArgumentError` naming the field.

  **This is not a transaction.** What can still fail after validation is the
  handle itself — `:closed`, `:panic`, `:lock_poisoned` — and that stops at the
  first error, leaving earlier writes applied.

  A list is applied in its own order; a map is applied in `Enum` order, which is
  unspecified, so pass a list where the order matters. Empty input returns
  `{:ok, editor}` and makes no native call, so it leaves
  `PdfElixide.Editor.modified?/1` alone and answers the same way for a closed
  editor.

  It is a convenience, not a batching optimization — see the
  [Concurrency](guides/concurrency.md) guide for what it locks.
  """
  @spec put_values(Editor.t(), Enumerable.t({String.t(), Field.value()})) ::
          {:ok, Editor.t()} | {:error, Error.t()}
  def put_values(%Editor{} = editor, values) do
    case Enum.to_list(values) do
      [] ->
        {:ok, editor}

      pairs ->
        validate_pairs!(pairs)

        with {:ok, fields} <- fields(editor),
             :ok <- ensure_all_known(pairs, fields) do
          apply_values(editor, pairs)
        end
    end
  end

  @doc """
  Writes several form field values on the given editor, raising an error if it
  fails.
  """
  @spec put_values!(Editor.t(), Enumerable.t({String.t(), Field.value()})) :: Editor.t()
  def put_values!(%Editor{} = editor, values) do
    editor |> put_values(values) |> Wrap.unwrap!()
  end

  @doc """
  Reads a form field's value, applies `fun` to it, writes the result back, and
  returns the editor.

  A field carrying no value hands `fun` a `nil`. A name the form does not carry
  is `{:error, %PdfElixide.Error{reason: :not_found}}` and `fun` is not called.
  Whatever `fun` returns is written by `put_value/3` and must be a
  `t:PdfElixide.Form.Field.value/0`.

  **This is a read and then a write, not an atomic read-modify-write** — another
  process holding the same editor can write in between; see the
  [Concurrency](guides/concurrency.md) guide.
  """
  @spec update_value(Editor.t(), String.t(), (Field.value() -> Field.value())) ::
          {:ok, Editor.t()} | {:error, Error.t()}
  def update_value(%Editor{} = editor, name, fun)
      when is_binary(name) and is_function(fun, 1) do
    with {:ok, value} <- value(editor, name) do
      put_value(editor, name, fun.(value))
    end
  end

  @doc """
  Reads a form field's value, applies `fun` to it and writes the result back,
  raising an error if it fails.
  """
  @spec update_value!(Editor.t(), String.t(), (Field.value() -> Field.value())) :: Editor.t()
  def update_value!(%Editor{} = editor, name, fun)
      when is_binary(name) and is_function(fun, 1) do
    editor |> update_value(name, fun) |> Wrap.unwrap!()
  end

  # Names are checked before duplicates because a pair has to be well-formed
  # before it can be said to collide with another.
  defp validate_pairs!(pairs) do
    Enum.each(pairs, &validate_pair!/1)
    ensure_no_duplicates!(pairs)
  end

  defp validate_pair!({name, value}) when is_binary(name) do
    if valid_value?(value) do
      :ok
    else
      raise ArgumentError, "invalid value for form field #{inspect(name)}: #{inspect(value)}"
    end
  end

  defp validate_pair!({name, _value}) do
    raise ArgumentError, "form field name must be a string, got: #{inspect(name)}"
  end

  defp validate_pair!(other) do
    raise ArgumentError, "expected a {name, value} pair, got: #{inspect(other)}"
  end

  defp valid_value?(value) when is_binary(value) or is_boolean(value) or is_nil(value), do: true
  defp valid_value?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp valid_value?(_value), do: false

  # A duplicate is a caller bug rather than something to resolve silently, the
  # same rule a duplicated option key follows; see the "Errors versus
  # exceptions" section of `PdfElixide.Error`. Only a list can produce one.
  defp ensure_no_duplicates!(pairs) do
    pairs
    |> Enum.frequencies_by(fn {name, _value} -> name end)
    |> Enum.find(fn {_name, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {name, _count} -> raise ArgumentError, "duplicate form field name: #{inspect(name)}"
    end
  end

  defp ensure_all_known(pairs, fields) do
    known = MapSet.new(fields, & &1.name)

    pairs
    |> Enum.find(fn {name, _value} -> not MapSet.member?(known, name) end)
    |> case do
      nil -> :ok
      {name, _value} -> {:error, not_found(name)}
    end
  end

  defp apply_values(editor, pairs) do
    Enum.reduce_while(pairs, {:ok, editor}, fn {name, value}, _acc ->
      case put_value(editor, name, value) do
        {:ok, _editor} = ok -> {:cont, ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  defp not_found(name) do
    %Error{reason: :not_found, message: "Form field not found: #{name}"}
  end
end
