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
      #=> "John Doe"

      # Fill and persist.
      editor = PdfElixide.Editor.open!("form.pdf")
      :ok = PdfElixide.Form.set_value(editor, "full_name", "Jane Doe")
      :ok = PdfElixide.Form.set_value(editor, "subscribe", true)
      :ok = PdfElixide.Editor.save(editor, "filled.pdf")

  Fields come back as one struct per field type — `PdfElixide.Form.Field.Text`,
  `.Button`, `.Choice`, `.Unknown`, all listed in `PdfElixide.Form.Field` — so
  the field's type is what you match on. A field's `:value` is a plain term and
  is what `set_value/3` accepts, so a value read from one form can be written
  straight into another — with one exception, on button fields, described under
  "Check boxes and radio groups" below.

  Fields are addressed by name, and only an existing field can be set — there is
  no way to add one. A name that is not in the form is
  `{:error, %PdfElixide.Error{reason: :not_found}}`, from `field/2` and
  `value/2` as much as from `set_value/3`.

  A form whose field hierarchy is cyclic, or nested far deeper than any real
  form, is reported as an error by every function here rather than read.

  Which lock `fields/1` takes follows its source: a shared read on a
  `PdfElixide.Document`, and the editor's exclusive lock on a
  `PdfElixide.Editor`, exactly as `set_value/3` takes. `field/2` and `value/2`
  take the same lock and cost the same, so reading several fields one at a time
  costs more than one `fields/1`. So concurrent form work on one editor
  serializes even when it only reads; see the
  [Concurrency](guides/concurrency.md) guide.

  ## Signature fields

  A signature field (`/FT /Sig`) is not a fillable field, and this API does not
  have one: `fields/1` omits it, and `field/2`, `value/2` and `set_value/3` all
  answer `{:error, %PdfElixide.Error{reason: :not_found}}` for its name, exactly
  as they would for a name the form does not carry.

  `set_value/3` has to refuse it rather than merely fail to find it. A
  signature's `/V` is a signature dictionary rather than a value, and writing
  *any* value over it — `nil` included — replaces that dictionary, so a filled
  form would silently come back unsigned.

  This holds for a field whose `/FT` is declared on an ancestor rather than on
  the field itself, which the PDF specification permits. Reading, verifying and
  producing signatures is a separate capability, and not one this library
  offers.

  ## Check boxes and radio groups

  Setting a button field writes `/Yes` for `true` and `/Off` for `false`, and
  those are the only two states `set_value/3` can produce. That makes the
  read-then-write round trip lossy for some check boxes and radio groups, in two
  ways.

  A box whose on-state is `/On` rather than `/Yes` reads as `true`, since both
  names mean "checked", but writing that `true` back emits `/Yes` — which is not
  the state the widget declares, so the box comes back **unchecked**. Nothing in
  the value reveals this; the two spellings are indistinguishable once read.
  (`/No` collapses to `false` and writes `/Off` in the same way, but harmlessly:
  `/Off` is the off state for every check box.)

  A box whose on-state is a *custom* name — `/Export1`, say — cannot be checked
  at all: `true` writes `/Yes`, which matches no widget state, and no other value
  writes a PDF name either. Writing the on-state's name as a string is not a
  workaround and makes matters worse: it goes into `/V` *and* is copied into the
  widget's `/AS`, where the PDF specification requires a name, so a reader may
  render the field wrongly.

  Either field needs its dictionaries edited directly, which this library does
  not expose. Reading such a field is unaffected — only writing one back is.
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

  Signature fields are not reported; this API covers fillable form fields only.
  See the "Signature fields" section above.
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
      #=> {:ok, %PdfElixide.Form.Field.Text{name: "full_name", value: "John Doe"}}

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
  Sets the value of an existing form field on the given editor.

  The value is a plain term, the same shape `fields/1` returns — a string,
  `true`/`false`, a list of strings, or `nil`. Anything else raises
  `ArgumentError`; see `t:PdfElixide.Form.Field.value/0` for the full set.

      :ok = PdfElixide.Form.set_value(editor, "full_name", "Jane Doe")
      :ok = PdfElixide.Form.set_value(editor, "subscribe", true)

  Button fields are limited to `/Yes` and `/Off`; see the "Check boxes and radio
  groups" section above. A signature field cannot be written at all; see
  "Signature fields".

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
