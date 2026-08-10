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
  @no_form_pdf Path.join(@fixtures, "sample.pdf")

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
      :ok = Form.set_value(editor, "full_name", "Jane Doe")
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
      assert :ok = Form.set_value(editor, "person.first", "Zoe")
      assert {:ok, "Zoe"} = Form.value(editor, "person.first")
    end
  end

  describe "set_value/3" do
    test "returns :ok for a known field" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value(editor, "full_name", "Jane Doe")
    end

    test "reports an unknown field name as :not_found" do
      editor = Editor.open!(@form_pdf)

      # The native layer reports the same reason `field/2` does; what that
      # depends on upstream is pinned in upstream_drift_test.exs. The
      # signature-field guard runs ahead of the write and must stay transparent
      # to a name that is in no form at all.
      assert {:error, %Error{reason: :not_found}} =
               Form.set_value(editor, "no_such_field", "x")
    end

    test "text update is visible in subsequent Form.fields/1 read" do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "full_name", "Jane Doe")
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field.Text{value: "Jane Doe"} = field
    end

    test "boolean update is visible in subsequent Form.fields/1 read" do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "subscribe", false)
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "subscribe"))
      assert %Field.Button{value: false} = field

      :ok = Form.set_value(editor, "subscribe", true)
      assert {:ok, true} = Form.value(editor, "subscribe")
    end

    test "a list write reads back as a list, and survives a save and reopen" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value(editor, "country", ["Canada", "Mexico"])
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
      # read off a field is exactly what `set_value/3` accepts.
      for %{name: name, value: value} <- fields_before do
        assert :ok = Form.set_value(editor, name, value)
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
        assert_raise ArgumentError, fn -> Form.set_value(editor, "full_name", bad) end
      end
    end

    test "raises ArgumentError for the old tagged-tuple shapes" do
      editor = Editor.open!(@form_pdf)

      # Values are plain terms now. The tags this library used to require are
      # rejected rather than silently written as something else, so a caller
      # that missed the breaking change fails loudly.
      for old <- [{:text, "x"}, {:boolean, true}, {:array, ["a"]}] do
        assert_raise ArgumentError, fn -> Form.set_value(editor, "full_name", old) end
      end
    end
  end

  describe "set_value!/3" do
    test "returns :ok for a known field" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value!(editor, "full_name", "Test")
    end

    test "raises for an unknown field name" do
      editor = Editor.open!(@form_pdf)
      assert_raise Error, fn -> Form.set_value!(editor, "no_such_field", "x") end
    end

    test "raises ArgumentError for a value it cannot decode" do
      editor = Editor.open!(@form_pdf)
      assert_raise ArgumentError, fn -> Form.set_value!(editor, "full_name", {:text, "x"}) end
      assert_raise ArgumentError, fn -> Form.set_value!(editor, "full_name", 42) end
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
      # field this API has, and all four say so the same way. `set_value/3` is
      # the one that has to be made to — the name stays addressable upstream, so
      # without its guard the write would land and destroy the signature.
      assert {:error, %Error{reason: :not_found}} = Form.field(editor, "signature")
      assert {:error, %Error{reason: :not_found}} = Form.value(editor, "signature")

      # Not only the `nil` the field would report: setting a value replaces `/V`
      # outright, so a string destroys the signature dictionary just as
      # thoroughly as a null does.
      for value <- [nil, "x", true, ["a"]] do
        assert {:error, %Error{reason: :not_found}} =
                 Form.set_value(editor, "signature", value)
      end

      # The strongest available statement that nothing was written: a refused
      # call leaves the editor with nothing to save.
      refute Editor.modified?(editor)
    end

    test "set_value!/3 raises the same error" do
      editor = Editor.open!(@signature_pdf)
      assert_raise Error, fn -> Form.set_value!(editor, "signature", nil) end
    end

    test "an ordinary field on the same document is still writable" do
      editor = Editor.open!(@signature_pdf)
      assert :ok = Form.set_value(editor, "signer_name", "Bob")

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
                 Form.set_value(editor, "inherited.leaf", value)
      end

      refute Editor.modified?(editor)
    end

    test "keeps its signature dictionary across a save of the same document" do
      editor = Editor.open!(@signature_edge_pdf)

      assert {:error, %Error{reason: :not_found}} = Form.set_value(editor, "inherited.leaf", nil)
      assert :ok = Form.set_value(editor, "plain", "written")

      # The `/V` is an indirect reference, so an unguarded write would replace it
      # with `null` and the default garbage collection would drop the dictionary.
      bytes = Editor.to_binary!(editor, compress: false)
      assert bytes =~ "CAFEBABE"

      assert {:ok, %Field.Text{value: "written"}} =
               Form.field(Document.from_binary!(bytes), "plain")
    end

    test "does not make a kid carrying its own /FT unwritable" do
      editor = Editor.open!(@signature_edge_pdf)

      assert :ok = Form.set_value(editor, "inherited.typed", "still a text field")
    end

    test "does not make a name whose first field is not one unwritable" do
      # `shadowed` is declared twice, `/Tx` first and `/Sig` second. The write
      # reaches the first, so refusing it would deny a caller the only field of
      # that name they can see.
      editor = Editor.open!(@signature_edge_pdf)

      assert :ok = Form.set_value(editor, "shadowed", "written")

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
      assert {:error, %Error{reason: :invalid_pdf}} = Form.set_value(editor, "loop", "x")
    end

    test "does not stop the document being read otherwise" do
      doc = Document.open!(@cyclic_pdf)

      assert {:ok, 1} = Document.page_count(doc)
    end
  end
end
