defmodule PdfElixide.FormTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form
  alias PdfElixide.Form.Field

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @form_pdf Path.join(@fixtures, "form.pdf")
  @hierarchical_pdf Path.join(@fixtures, "form_hierarchical.pdf")
  @signature_pdf Path.join(@fixtures, "form_signature.pdf")
  @signature_edge_pdf Path.join(@fixtures, "form_signature_edge.pdf")
  @cyclic_pdf Path.join(@fixtures, "form_cyclic.pdf")
  @flags_pdf Path.join(@fixtures, "form_flags.pdf")
  @no_form_pdf Path.join(@fixtures, "sample.pdf")
  @flatten_pdf Path.join(@fixtures, "flatten.pdf")

  # The three `form.pdf` fields, in file order — one per struct the fixture can
  # express, which is every struct but `Unknown`. No fixture yields a non-nil
  # `:raw_type`, which the `#[cfg(test)]` tests in form.rs pin.
  @form_pdf_kinds [Field.Text, Field.Button, Field.Choice]

  defp kinds(fields), do: Enum.map(fields, & &1.__struct__)

  describe "fields/1" do
    test "returns {:ok, []} for a document with no AcroForm" do
      doc = Document.open!(@no_form_pdf)
      assert {:ok, []} = Form.fields(doc)
    end

    test "returns {:ok, fields} with one per-kind struct per AcroForm field" do
      doc = Document.open!(@form_pdf)
      assert {:ok, fields} = Form.fields(doc)
      assert kinds(fields) == @form_pdf_kinds
    end

    test "decodes a text field's name and string value" do
      doc = Document.open!(@form_pdf)
      {:ok, fields} = Form.fields(doc)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field.Text{value: "John Doe"} = field
    end

    test "decodes a checkbox button's /Yes value as true" do
      doc = Document.open!(@form_pdf)
      {:ok, fields} = Form.fields(doc)
      field = Enum.find(fields, &(&1.name == "subscribe"))
      assert %Field.Button{value: true} = field
    end

    test "represents a field with no /V entry as value: nil" do
      doc = Document.open!(@form_pdf)
      {:ok, fields} = Form.fields(doc)
      field = Enum.find(fields, &(&1.name == "country"))
      assert %Field.Choice{value: nil} = field
    end

    test "works on a document loaded from binary" do
      pdf_bytes = File.read!(@form_pdf)
      doc = Document.from_binary!(pdf_bytes)
      assert {:ok, [_ | _]} = Form.fields(doc)
    end
  end

  describe "fields!/1" do
    test "returns [] for a document with no AcroForm" do
      doc = Document.open!(@no_form_pdf)
      assert Form.fields!(doc) == []
    end

    test "returns the list of fields directly for the form fixture" do
      doc = Document.open!(@form_pdf)
      fields = Form.fields!(doc)
      assert kinds(fields) == @form_pdf_kinds
      assert Enum.map(fields, & &1.name) == ["full_name", "subscribe", "country"]
    end
  end

  describe "fields/1 with %Editor{}" do
    test "returns {:ok, []} for an editor with no AcroForm" do
      editor = Editor.open!(@no_form_pdf)
      assert {:ok, []} = Form.fields(editor)
    end

    test "returns the same per-kind structs a document does" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, fields} = Form.fields(editor)
      assert kinds(fields) == @form_pdf_kinds
    end

    test "decodes a text field's name and string value" do
      editor = Editor.open!(@form_pdf)
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field.Text{value: "John Doe"} = field
    end

    test "works on an editor loaded from binary" do
      editor = Editor.from_binary!(File.read!(@form_pdf))
      assert {:ok, [_ | _]} = Form.fields(editor)
    end
  end

  describe "fields!/1 with %Editor{}" do
    test "returns [] for an editor with no AcroForm" do
      editor = Editor.open!(@no_form_pdf)
      assert Form.fields!(editor) == []
    end

    test "returns the list of fields directly for the form fixture" do
      editor = Editor.open!(@form_pdf)
      assert kinds(Form.fields!(editor)) == @form_pdf_kinds
    end
  end

  describe "field/2" do
    test "returns the named field from a %Document{}" do
      doc = Document.open!(@form_pdf)

      assert {:ok, %Field.Text{name: "full_name", value: "John Doe"}} =
               Form.field(doc, "full_name")
    end

    test "returns the named field from an %Editor{}" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, %Field.Button{name: "subscribe"}} = Form.field(editor, "subscribe")
    end

    test "sees a value set on the editor" do
      editor = Editor.open!(@form_pdf)
      Form.put_value!(editor, "full_name", "Jane Doe")
      assert {:ok, %Field.Text{value: "Jane Doe"}} = Form.field(editor, "full_name")
    end

    test "reports an unknown field name as :not_found" do
      doc = Document.open!(@form_pdf)
      assert {:error, %Error{reason: :not_found}} = Form.field(doc, "no_such_field")
    end

    test "reports :not_found for a document with no AcroForm" do
      doc = Document.open!(@no_form_pdf)
      assert {:error, %Error{reason: :not_found}} = Form.field(doc, "full_name")
    end

    test "raises FunctionClauseError for a name that is not a binary" do
      doc = Document.open!(@form_pdf)
      assert_raise FunctionClauseError, fn -> Form.field(doc, :full_name) end
    end
  end

  describe "field!/2" do
    test "returns the field directly" do
      doc = Document.open!(@form_pdf)
      assert %Field.Choice{name: "country"} = Form.field!(doc, "country")
    end

    test "raises for an unknown field name" do
      doc = Document.open!(@form_pdf)
      assert_raise Error, fn -> Form.field!(doc, "no_such_field") end
    end
  end

  describe "value/2" do
    test "returns the value of the named field as a plain term" do
      doc = Document.open!(@form_pdf)
      assert {:ok, "John Doe"} = Form.value(doc, "full_name")
      assert {:ok, true} = Form.value(doc, "subscribe")
    end

    test "answers {:ok, nil} for a field with no /V entry" do
      doc = Document.open!(@form_pdf)

      # Asserted beside the :not_found case below: a field that exists but
      # carries no value must stay distinguishable from a name that is not in
      # the form.
      assert {:ok, nil} = Form.value(doc, "country")
      assert {:error, %Error{reason: :not_found}} = Form.value(doc, "no_such_field")
    end

    test "reads from an %Editor{} too" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, "John Doe"} = Form.value(editor, "full_name")
    end
  end

  describe "value!/2" do
    test "returns the value directly" do
      doc = Document.open!(@form_pdf)
      assert Form.value!(doc, "full_name") == "John Doe"
      assert Form.value!(doc, "country") == nil
    end

    test "raises for an unknown field name" do
      doc = Document.open!(@form_pdf)
      assert_raise Error, fn -> Form.value!(doc, "no_such_field") end
    end
  end

  describe "hierarchical field names" do
    test "a document and an editor report the same names" do
      doc = Document.open!(@hierarchical_pdf)
      editor = Editor.open!(@hierarchical_pdf)

      names = fn source -> source |> Form.fields!() |> Enum.map(& &1.name) |> Enum.sort() end

      assert names.(doc) == names.(editor)
    end

    test "a nested field is named by its full dotted path, not its /T alone" do
      doc = Document.open!(@hierarchical_pdf)
      names = doc |> Form.fields!() |> Enum.map(& &1.name)

      assert "person.first" in names
      refute "first" in names
      assert "email" in names
    end

    test "a parent carrying a name but no type is an Unknown with a nil raw_type" do
      doc = Document.open!(@hierarchical_pdf)
      editor = Editor.open!(@hierarchical_pdf)

      # The document extractor spells "no /FT" as `Unknown("")` where the editor
      # spells it `None`; both must normalize to nil so the two sources agree.
      assert {:ok, %Field.Unknown{raw_type: nil, value: nil}} = Form.field(doc, "person")
      assert {:ok, %Field.Unknown{raw_type: nil, value: nil}} = Form.field(editor, "person")
    end

    test "a value read from a document addresses the same field on an editor" do
      doc = Document.open!(@hierarchical_pdf)
      editor = Editor.open!(@hierarchical_pdf)

      assert {:ok, "Jane"} = Form.value(doc, "person.first")
      assert {:ok, ^editor} = Form.put_value(editor, "person.first", "Zoe")
      assert {:ok, "Zoe"} = Form.value(editor, "person.first")
    end
  end

  describe "field kinds and flags" do
    test "a document and an editor report every field identically" do
      doc = Document.open!(@flags_pdf)
      editor = Editor.open!(@flags_pdf)

      # The whole point of resolving `/Ff` in one place: upstream reads it from
      # two different structs on the two paths, and neither resolves inheritance.
      assert Form.fields!(doc) == Form.fields!(editor)
    end

    test "a button's kind comes from its /Ff bits" do
      doc = Document.open!(@flags_pdf)

      assert %Field.Button{kind: :push} = Form.field!(doc, "push")
      assert %Field.Button{kind: :radio} = Form.field!(doc, "radio")
      assert %Field.Button{kind: :check_box} = Form.field!(doc, "check")
    end

    test "a choice field's kind comes from its /Ff bits" do
      doc = Document.open!(@flags_pdf)

      assert %Field.Choice{kind: :combo_box} = Form.field!(doc, "combo")
      assert %Field.Choice{kind: :list_box} = Form.field!(doc, "list")
    end

    test "a text field's kind comes from its /Ff bits" do
      doc = Document.open!(@flags_pdf)

      assert %Field.Text{kind: :multiline} = Form.field!(doc, "notes")
      assert %Field.Text{kind: :single_line} = Form.field!(doc, "secret")
    end

    test "a field declaring no /Ff gets the specification's defaults, not an unknown" do
      doc = Document.open!(@flags_pdf)

      assert %Field.Button{kind: :check_box, flags: %Field.Button.Flags{raw: 0}} =
               Form.field!(doc, "check")

      assert %Field.Choice{kind: :list_box, flags: %Field.Choice.Flags{raw: 0}} =
               Form.field!(doc, "list")
    end

    test "decodes the bits the kind does not report" do
      doc = Document.open!(@flags_pdf)

      assert %Field.Text{flags: %Field.Text.Flags{password: true, multiline: false}} =
               Form.field!(doc, "secret")

      assert %Field.Text{flags: %Field.Text.Flags{read_only: true, raw: 1}} =
               Form.field!(doc, "locked")
    end

    test "an unknown field carries only the flags every field has" do
      doc = Document.open!(@hierarchical_pdf)

      assert %Field.Unknown{
               flags: %Field.Flags{read_only: false, required: false, no_export: false, raw: 0}
             } = Form.field!(doc, "person")
    end

    test "a kid with no /Ff of its own inherits its parent's" do
      doc = Document.open!(@flags_pdf)
      editor = Editor.open!(@flags_pdf)

      # Upstream reads /Ff off the field's own dictionary, so without the walk
      # this leaf would report a cleared 0 and classify as a check box.
      for source <- [doc, editor] do
        assert %Field.Button{kind: :radio, flags: %Field.Button.Flags{raw: 32_768}} =
                 Form.field!(source, "group.a")
      end
    end

    test "an own /Ff replaces an inherited one rather than merging with it" do
      doc = Document.open!(@flags_pdf)

      assert %Field.Button{kind: :push, flags: %Field.Button.Flags{radio: false, raw: 65_536}} =
               Form.field!(doc, "group.b")
    end
  end

  describe "put_value/3" do
    test "returns the editor it was given" do
      editor = Editor.open!(@form_pdf)

      # The same handle, not a copy: an editor is mutable, so a pipeline
      # sequences effects rather than threading a value.
      assert {:ok, ^editor} = Form.put_value(editor, "full_name", "Jane Doe")
    end

    test "reports an unknown field name as :not_found" do
      editor = Editor.open!(@form_pdf)

      # The native layer reports the same reason `field/2` does; what that
      # depends on upstream is pinned in upstream_drift_test.exs. The
      # signature-field guard runs ahead of the write and must stay transparent
      # to a name that is in no form at all.
      assert {:error, %Error{reason: :not_found}} =
               Form.put_value(editor, "no_such_field", "x")
    end

    test "reports a closed editor" do
      editor = Editor.open!(@form_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} =
               Form.put_value(editor, "full_name", "Jane Doe")
    end

    test "text update is visible in subsequent Form.fields/1 read" do
      editor = Editor.open!(@form_pdf)
      Form.put_value!(editor, "full_name", "Jane Doe")
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field.Text{value: "Jane Doe"} = field
    end

    test "boolean update is visible in subsequent Form.fields/1 read" do
      editor = Editor.open!(@form_pdf)
      Form.put_value!(editor, "subscribe", false)
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "subscribe"))
      assert %Field.Button{value: false} = field

      Form.put_value!(editor, "subscribe", true)
      assert {:ok, true} = Form.value(editor, "subscribe")
    end

    test "a list write reads back as a list, and survives a save and reopen" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, ^editor} = Form.put_value(editor, "country", ["Canada", "Mexico"])
      assert {:ok, %Field.Choice{value: ["Canada", "Mexico"]}} = Form.field(editor, "country")

      # Written as an array of text strings and re-parsed on the way back in, so
      # this is the one place `mix test` reaches the *document* path's list arm.
      reopened = Document.from_binary!(Editor.to_binary!(editor))
      assert {:ok, %Field.Choice{value: ["Canada", "Mexico"]}} = Form.field(reopened, "country")
    end

    test "round-trips a previously-read value unchanged" do
      editor = Editor.open!(@form_pdf)
      {:ok, fields_before} = Form.fields(editor)

      # Every kind the fixture carries, not just the text one: a plain value
      # read off a field is exactly what `put_value/3` accepts.
      for %{name: name, value: value} <- fields_before do
        assert {:ok, ^editor} = Form.put_value(editor, name, value)
        assert {:ok, ^value} = Form.value(editor, name)
      end
    end

    test "raises ArgumentError for a value it cannot decode" do
      editor = Editor.open!(@form_pdf)

      # The NIF cannot decode the value and raises :badarg. That is a caller
      # bug, so it propagates rather than becoming an {:error, _} tuple.
      #
      # `{:name, "x"}` was once a write-side escape and is now rejected like any
      # other tagged tuple: it wrote bytes byte-identical to a bare string, so
      # nothing it could express is lost.
      for bad <- [42, :yes, ["a", 5], {:name, 5}, {:name, "Export1"}, {:nope, "x"}] do
        assert_raise ArgumentError, fn -> Form.put_value(editor, "full_name", bad) end
      end
    end

    test "raises ArgumentError for the old tagged-tuple shapes" do
      editor = Editor.open!(@form_pdf)

      # Values are plain terms now. The tags this library used to require are
      # rejected rather than silently written as something else, so a caller
      # that missed the breaking change fails loudly.
      for old <- [{:text, "x"}, {:boolean, true}, {:array, ["a"]}] do
        assert_raise ArgumentError, fn -> Form.put_value(editor, "full_name", old) end
      end
    end
  end

  describe "put_value!/3" do
    test "returns the editor it was given, so it composes in a pipeline" do
      editor = Editor.open!(@form_pdf)

      assert ^editor =
               editor
               |> Form.put_value!("full_name", "Test")
               |> Form.put_value!("subscribe", true)

      assert {:ok, "Test"} = Form.value(editor, "full_name")
      assert {:ok, true} = Form.value(editor, "subscribe")
    end

    test "raises for an unknown field name" do
      editor = Editor.open!(@form_pdf)
      assert_raise Error, fn -> Form.put_value!(editor, "no_such_field", "x") end
    end

    test "raises ArgumentError for a value it cannot decode" do
      editor = Editor.open!(@form_pdf)
      assert_raise ArgumentError, fn -> Form.put_value!(editor, "full_name", {:text, "x"}) end
      assert_raise ArgumentError, fn -> Form.put_value!(editor, "full_name", 42) end
    end
  end

  describe "put_values/2" do
    test "writes every field of a map and returns the editor" do
      editor = Editor.open!(@form_pdf)

      assert {:ok, ^editor} =
               Form.put_values(editor, %{"full_name" => "Jane Doe", "subscribe" => false})

      assert {:ok, "Jane Doe"} = Form.value(editor, "full_name")
      assert {:ok, false} = Form.value(editor, "subscribe")
    end

    test "writes every field of a list, in the list's order" do
      editor = Editor.open!(@form_pdf)

      # The same name twice would be an ArgumentError, so ordering is shown with
      # two fields whose final values differ from the fixture's.
      assert {:ok, ^editor} =
               Form.put_values(editor, [{"full_name", "First"}, {"country", ["Canada"]}])

      assert {:ok, "First"} = Form.value(editor, "full_name")
      assert {:ok, ["Canada"]} = Form.value(editor, "country")
    end

    test "an empty map or list writes nothing at all" do
      for empty <- [%{}, []] do
        editor = Editor.open!(@form_pdf)

        assert {:ok, ^editor} = Form.put_values(editor, empty)

        # Not merely "no field changed": the short-circuit makes no native call,
        # which is the only way the flag can still be false here.
        refute Editor.modified?(editor)
      end
    end

    test "an empty write against a closed editor still answers {:ok, editor}" do
      editor = Editor.open!(@form_pdf)
      :ok = Editor.close(editor)

      # A consequence of making no native call, not a special case: the
      # short-circuit runs ahead of the validating read that would report the
      # handle.
      assert {:ok, ^editor} = Form.put_values(editor, [])
    end

    test "reports an unknown name as :not_found and writes nothing" do
      editor = Editor.open!(@form_pdf)

      assert {:error, %Error{reason: :not_found, message: message}} =
               Form.put_values(editor, [{"full_name", "Jane Doe"}, {"no_such_field", "x"}])

      assert message == "Form field not found: no_such_field"

      # The pre-validation contract: the *first* pair was valid and would have
      # been written had the check run per-field instead of up front.
      assert {:ok, "John Doe"} = Form.value(editor, "full_name")
      refute Editor.modified?(editor)
    end

    test "reports a signature field as :not_found and writes nothing" do
      editor = Editor.open!(@signature_pdf)

      # `fields/1` omits it, so the pre-validation read is what refuses it —
      # the same answer `put_value/3` reaches through its own guard.
      assert {:error, %Error{reason: :not_found}} =
               Form.put_values(editor, [{"signer_name", "Bob"}, {"signature", nil}])

      refute Editor.modified?(editor)
    end

    test "reports a closed editor" do
      editor = Editor.open!(@form_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} =
               Form.put_values(editor, %{"full_name" => "Jane Doe"})
    end

    test "raises ArgumentError for a duplicated name, and writes nothing" do
      editor = Editor.open!(@form_pdf)

      assert_raise ArgumentError, ~r/duplicate form field name: "full_name"/, fn ->
        Form.put_values(editor, [{"full_name", "First"}, {"full_name", "Second"}])
      end

      refute Editor.modified?(editor)
    end

    test "raises ArgumentError for a name that is not a string" do
      editor = Editor.open!(@form_pdf)

      assert_raise ArgumentError, ~r/form field name must be a string/, fn ->
        Form.put_values(editor, [{:full_name, "Jane Doe"}])
      end

      refute Editor.modified?(editor)
    end

    test "raises ArgumentError for anything that is not a {name, value} pair" do
      editor = Editor.open!(@form_pdf)

      assert_raise ArgumentError, ~r/expected a \{name, value\} pair/, fn ->
        Form.put_values(editor, ["full_name"])
      end
    end

    test "raises ArgumentError for each invalid value shape, and writes nothing" do
      editor = Editor.open!(@form_pdf)

      # The same set `put_value/3` rejects at the NIF boundary, refused here in
      # Elixir instead so that nothing has been written by the time it raises.
      for bad <- [42, :yes, ["a", 5], {:text, "x"}, {:name, "Export1"}, %{}] do
        assert_raise ArgumentError, ~r/invalid value for form field "full_name"/, fn ->
          Form.put_values(editor, [{"full_name", bad}])
        end
      end

      refute Editor.modified?(editor)
    end

    test "accepts every shape t:Field.value/0 admits" do
      editor = Editor.open!(@form_pdf)

      assert {:ok, ^editor} =
               Form.put_values(editor, [
                 {"full_name", "Jane Doe"},
                 {"subscribe", true},
                 {"country", ["Canada", "Mexico"]}
               ])

      assert {:ok, ^editor} = Form.put_values(editor, %{"full_name" => nil})
      assert {:ok, nil} = Form.value(editor, "full_name")
    end
  end

  describe "put_values!/2" do
    test "returns the editor, so it composes in a pipeline" do
      editor = Editor.open!(@form_pdf)

      assert ^editor = Form.put_values!(editor, %{"full_name" => "Jane Doe"})
      assert {:ok, "Jane Doe"} = Form.value(editor, "full_name")
    end

    test "raises the %Error{} for an unknown name" do
      editor = Editor.open!(@form_pdf)
      assert_raise Error, fn -> Form.put_values!(editor, %{"no_such_field" => "x"}) end
    end

    test "raises the %Error{} for a closed editor" do
      editor = Editor.open!(@form_pdf)
      :ok = Editor.close(editor)

      assert_raise Error, "Editor is closed", fn ->
        Form.put_values!(editor, %{"full_name" => "x"})
      end
    end

    test "raises ArgumentError for the caller bugs, exactly as put_values/2 does" do
      editor = Editor.open!(@form_pdf)

      assert_raise ArgumentError, fn ->
        Form.put_values!(editor, [{"full_name", "a"}, {"full_name", "b"}])
      end

      assert_raise ArgumentError, fn -> Form.put_values!(editor, [{:full_name, "a"}]) end
      assert_raise ArgumentError, fn -> Form.put_values!(editor, %{"full_name" => 42}) end
    end
  end

  describe "update_value/3" do
    test "reads the current value, writes the transformed one, returns the editor" do
      editor = Editor.open!(@form_pdf)

      assert {:ok, ^editor} = Form.update_value(editor, "full_name", &String.upcase/1)
      assert {:ok, "JOHN DOE"} = Form.value(editor, "full_name")
    end

    test "hands the fun a nil for a field carrying no value" do
      editor = Editor.open!(@form_pdf)

      assert {:ok, ^editor} =
               Form.update_value(editor, "country", fn
                 nil -> ["Canada"]
                 other -> other
               end)

      assert {:ok, ["Canada"]} = Form.value(editor, "country")
    end

    test "reports an unknown name as :not_found without calling the fun" do
      editor = Editor.open!(@form_pdf)
      test_pid = self()

      assert {:error, %Error{reason: :not_found}} =
               Form.update_value(editor, "no_such_field", fn value ->
                 send(test_pid, :fun_was_called)
                 value
               end)

      refute_received :fun_was_called
    end

    test "raises ArgumentError when the fun returns a shape that cannot be written" do
      editor = Editor.open!(@form_pdf)

      assert_raise ArgumentError, fn -> Form.update_value(editor, "full_name", fn _ -> 42 end) end
    end

    test "raises FunctionClauseError for a non-function or a wrong arity" do
      editor = Editor.open!(@form_pdf)

      assert_raise FunctionClauseError, fn -> Form.update_value(editor, "full_name", "nope") end

      assert_raise FunctionClauseError, fn ->
        Form.update_value(editor, "full_name", fn a, b -> {a, b} end)
      end
    end
  end

  describe "update_value!/3" do
    test "returns the editor, so it composes in a pipeline" do
      editor = Editor.open!(@form_pdf)

      assert ^editor = Form.update_value!(editor, "full_name", &String.upcase/1)
      assert {:ok, "JOHN DOE"} = Form.value(editor, "full_name")
    end

    test "raises for an unknown field name" do
      editor = Editor.open!(@form_pdf)

      assert_raise Error, fn ->
        Form.update_value!(editor, "no_such_field", &Function.identity/1)
      end
    end
  end

  describe "signature fields" do
    test "are not reported by fields/1, from either source" do
      doc = Document.open!(@signature_pdf)
      editor = Editor.open!(@signature_pdf)

      # The fixture carries a `/Sig` field and a `/Tx` one; only the second is a
      # fillable form field, so only the second is reported.
      assert {:ok, [%Field.Text{name: "signer_name"}]} = Form.fields(doc)
      assert {:ok, [%Field.Text{name: "signer_name"}]} = Form.fields(editor)
    end

    test "answer :not_found from every function that takes a name" do
      editor = Editor.open!(@signature_pdf)

      # The uniformity is the point of the atom: a signature field is not a form
      # field this API has, and all four say so the same way. `put_value/3` is
      # the one that has to be made to — the name stays addressable upstream, so
      # without its guard the write would land and destroy the signature.
      assert {:error, %Error{reason: :not_found}} = Form.field(editor, "signature")
      assert {:error, %Error{reason: :not_found}} = Form.value(editor, "signature")

      # Not only the `nil` the field would report: setting a value replaces `/V`
      # outright, so a string destroys the signature dictionary just as
      # thoroughly as a null does.
      for value <- [nil, "x", true, ["a"]] do
        assert {:error, %Error{reason: :not_found}} =
                 Form.put_value(editor, "signature", value)
      end

      # The strongest available statement that nothing was written: a refused
      # call leaves the editor with nothing to save.
      refute Editor.modified?(editor)
    end

    test "put_value!/3 raises the same error" do
      editor = Editor.open!(@signature_pdf)
      assert_raise Error, fn -> Form.put_value!(editor, "signature", nil) end
    end

    test "an ordinary field on the same document is still writable" do
      editor = Editor.open!(@signature_pdf)
      assert {:ok, ^editor} = Form.put_value(editor, "signer_name", "Bob")

      # The fixture's `/V` is an indirect reference, so an unguarded write would
      # replace it with `null` and the default garbage collection would drop the
      # signature dictionary entirely. Its `/Contents` still being here is what
      # says the guard held across a save.
      bytes = Editor.to_binary!(editor, compress: false)
      assert bytes =~ "DEADBEEF"

      assert {:ok, %Field.Text{value: "Bob"}} =
               Form.field(Document.from_binary!(bytes), "signer_name")
    end
  end

  describe "a signature typed on an ancestor" do
    # Upstream reads `/FT` off the field's own dictionary only, so it classifies
    # `inherited.leaf` as a field of no known kind. Left at that it would be an
    # ordinary fillable field, and writing to it destroys the signature.

    test "is not reported by fields/1, from either source" do
      doc = Document.open!(@signature_edge_pdf)
      editor = Editor.open!(@signature_edge_pdf)

      # What survives: `inherited.typed`, which overrides the inherited `/Sig`
      # with its own `/Tx`; `shadowed`, whose *first* field is the text one; and
      # the `plain` control. Both sources must answer identically.
      names = fn source -> Enum.map(Form.fields!(source), & &1.name) end

      assert names.(doc) == ["inherited.typed", "shadowed", "plain"]
      assert names.(editor) == names.(doc)
    end

    test "answers :not_found from every function that takes a name" do
      editor = Editor.open!(@signature_edge_pdf)

      assert {:error, %Error{reason: :not_found}} = Form.field(editor, "inherited.leaf")
      assert {:error, %Error{reason: :not_found}} = Form.value(editor, "inherited.leaf")

      for value <- [nil, "x", true, ["a"]] do
        assert {:error, %Error{reason: :not_found}} =
                 Form.put_value(editor, "inherited.leaf", value)
      end

      refute Editor.modified?(editor)
    end

    test "keeps its signature dictionary across a save of the same document" do
      editor = Editor.open!(@signature_edge_pdf)

      assert {:error, %Error{reason: :not_found}} = Form.put_value(editor, "inherited.leaf", nil)
      assert {:ok, ^editor} = Form.put_value(editor, "plain", "written")

      # The `/V` is an indirect reference, so an unguarded write would replace it
      # with `null` and the default garbage collection would drop the dictionary.
      bytes = Editor.to_binary!(editor, compress: false)
      assert bytes =~ "CAFEBABE"

      assert {:ok, %Field.Text{value: "written"}} =
               Form.field(Document.from_binary!(bytes), "plain")
    end

    test "does not make a kid carrying its own /FT unwritable" do
      editor = Editor.open!(@signature_edge_pdf)

      assert {:ok, ^editor} = Form.put_value(editor, "inherited.typed", "still a text field")
    end

    test "does not make a name whose first field is not one unwritable" do
      # `shadowed` is declared twice, `/Tx` first and `/Sig` second. The write
      # reaches the first, so refusing it would deny a caller the only field of
      # that name they can see.
      editor = Editor.open!(@signature_edge_pdf)

      assert {:ok, ^editor} = Form.put_value(editor, "shadowed", "written")

      bytes = Editor.to_binary!(editor, compress: false)

      assert {:ok, %Field.Text{value: "written"}} =
               Form.field(Document.from_binary!(bytes), "shadowed")
    end
  end

  describe "a cyclic field tree" do
    test "is refused rather than walked, from every function that reads one" do
      # `form_cyclic.pdf`'s only field is its own `/Kids` entry. Upstream's
      # extractor would recurse until the native stack is gone, which aborts the
      # OS process — so the assertion that matters most here is that the suite
      # gets to run its next test at all.
      doc = Document.open!(@cyclic_pdf)
      editor = Editor.open!(@cyclic_pdf)

      assert {:error, %Error{reason: :invalid_pdf}} = Form.fields(doc)
      assert {:error, %Error{reason: :invalid_pdf}} = Form.fields(editor)
      assert {:error, %Error{reason: :invalid_pdf}} = Form.field(doc, "loop")
      assert {:error, %Error{reason: :invalid_pdf}} = Form.value(doc, "loop")
      assert {:error, %Error{reason: :invalid_pdf}} = Form.put_value(editor, "loop", "x")
    end

    test "does not stop the document being read otherwise" do
      doc = Document.open!(@cyclic_pdf)

      assert {:ok, 1} = Document.page_count(doc)
    end
  end

  describe "flatten/1" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@flatten_pdf)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Form.flatten(editor)
      assert Editor.modified?(editor)
    end

    test "removes the AcroForm and the widgets from the written document" do
      editor = Editor.open!(@flatten_pdf)
      doc = Document.open!(@flatten_pdf)
      assert length(Document.annotations!(doc, 0)) == 3

      {:ok, flattened} = editor |> Form.flatten!() |> Editor.to_binary()
      {:ok, doc} = Document.from_binary(flattened)

      assert Form.fields!(doc) == []
      # Only the widgets go: the fixture's non-widget annotation survives.
      assert length(Document.annotations!(doc, 0)) == 1
    end

    test "is not an error for a document carrying no form" do
      editor = Editor.open!(@no_form_pdf)
      assert {:ok, ^editor} = Form.flatten(editor)
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@flatten_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Form.flatten(editor)
    end

    test "flatten!/1 raises for a closed editor" do
      editor = Editor.open!(@flatten_pdf)
      :ok = Editor.close(editor)

      assert_raise Error, fn -> Form.flatten!(editor) end
    end
  end

  describe "flatten/2" do
    test "keeps the fields whose widgets are on an unflattened page" do
      editor = Editor.open!(@flatten_pdf)

      {:ok, flattened} = editor |> Form.flatten!(0) |> Editor.to_binary()
      {:ok, doc} = Document.from_binary(flattened)

      assert Enum.map(Form.fields!(doc), & &1.name) == ["comments"]
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@flatten_pdf)

      assert {:error, %Error{reason: :out_of_range}} = Form.flatten(editor, 2)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@flatten_pdf)

      assert_raise FunctionClauseError, fn -> Form.flatten(editor, -1) end
    end
  end
end
