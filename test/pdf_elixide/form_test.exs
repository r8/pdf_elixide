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
  @no_form_pdf Path.join(@fixtures, "sample.pdf")

  describe "fields/1" do
    test "returns {:ok, []} for a document with no AcroForm" do
      doc = Document.open!(@no_form_pdf)
      assert {:ok, []} = Form.fields(doc)
    end

    test "returns {:ok, fields} with one struct per AcroForm field" do
      doc = Document.open!(@form_pdf)
      assert {:ok, fields} = Form.fields(doc)
      assert length(fields) == 3
      assert Enum.all?(fields, &match?(%Field{}, &1))
    end

    test "decodes a text field's name, kind, and string value" do
      doc = Document.open!(@form_pdf)
      {:ok, fields} = Form.fields(doc)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field{kind: :text, value: {:text, "John Doe"}} = field
    end

    test "decodes a checkbox button's /Yes value as {:boolean, true}" do
      doc = Document.open!(@form_pdf)
      {:ok, fields} = Form.fields(doc)
      field = Enum.find(fields, &(&1.name == "subscribe"))
      assert %Field{kind: :button, value: {:boolean, true}} = field
    end

    test "represents a field with no /V entry as value: nil" do
      doc = Document.open!(@form_pdf)
      {:ok, fields} = Form.fields(doc)
      field = Enum.find(fields, &(&1.name == "country"))
      assert %Field{kind: :choice, value: nil} = field
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
      assert length(fields) == 3
      assert Enum.all?(fields, &match?(%Field{}, &1))
      assert Enum.map(fields, & &1.name) == ["full_name", "subscribe", "country"]
    end
  end

  describe "fields/1 with %Editor{}" do
    test "returns {:ok, []} for an editor with no AcroForm" do
      editor = Editor.open!(@no_form_pdf)
      assert {:ok, []} = Form.fields(editor)
    end

    test "returns {:ok, fields} with one struct per AcroForm field" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, fields} = Form.fields(editor)
      assert length(fields) == 3
      assert Enum.all?(fields, &match?(%Field{}, &1))
    end

    test "decodes a text field's name, kind, and string value" do
      editor = Editor.open!(@form_pdf)
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field{kind: :text, value: {:text, "John Doe"}} = field
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
      fields = Form.fields!(editor)
      assert length(fields) == 3
      assert Enum.all?(fields, &match?(%Field{}, &1))
    end
  end

  describe "field/2" do
    test "returns the named field from a %Document{}" do
      doc = Document.open!(@form_pdf)

      assert {:ok, %Field{name: "full_name", kind: :text, value: {:text, "John Doe"}}} =
               Form.field(doc, "full_name")
    end

    test "returns the named field from an %Editor{}" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, %Field{name: "subscribe", kind: :button}} = Form.field(editor, "subscribe")
    end

    test "sees a value set on the editor" do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "full_name", {:text, "Jane Doe"})
      assert {:ok, %Field{value: {:text, "Jane Doe"}}} = Form.field(editor, "full_name")
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
      assert %Field{name: "country", kind: :choice} = Form.field!(doc, "country")
    end

    test "raises for an unknown field name" do
      doc = Document.open!(@form_pdf)
      assert_raise Error, fn -> Form.field!(doc, "no_such_field") end
    end
  end

  describe "value/2" do
    test "returns the value of the named field" do
      doc = Document.open!(@form_pdf)
      assert {:ok, {:text, "John Doe"}} = Form.value(doc, "full_name")
      assert {:ok, {:boolean, true}} = Form.value(doc, "subscribe")
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
      assert {:ok, {:text, "John Doe"}} = Form.value(editor, "full_name")
    end
  end

  describe "value!/2" do
    test "returns the value directly" do
      doc = Document.open!(@form_pdf)
      assert Form.value!(doc, "full_name") == {:text, "John Doe"}
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

    test "a parent carrying a name but no type is surfaced as its own field" do
      doc = Document.open!(@hierarchical_pdf)
      assert {:ok, %Field{kind: :unknown, value: nil}} = Form.field(doc, "person")
    end

    test "a value read from a document addresses the same field on an editor" do
      doc = Document.open!(@hierarchical_pdf)
      editor = Editor.open!(@hierarchical_pdf)

      assert {:ok, {:text, "Jane"}} = Form.value(doc, "person.first")
      assert :ok = Form.set_value(editor, "person.first", {:text, "Zoe"})
      assert {:ok, {:text, "Zoe"}} = Form.value(editor, "person.first")
    end
  end

  describe "set_value/3" do
    test "returns :ok for a known field" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value(editor, "full_name", {:text, "Jane Doe"})
    end

    test "reports an unknown field name as :not_found" do
      editor = Editor.open!(@form_pdf)

      # The native layer reports the same reason `field/2` does; what that
      # depends on upstream is pinned in upstream_drift_test.exs.
      assert {:error, %Error{reason: :not_found}} =
               Form.set_value(editor, "no_such_field", {:text, "x"})
    end

    test "text update is visible in subsequent Form.fields/1 read" do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "full_name", {:text, "Jane Doe"})
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "full_name"))
      assert %Field{kind: :text, value: {:text, "Jane Doe"}} = field
    end

    test "boolean update is visible in subsequent Form.fields/1 read" do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "subscribe", {:boolean, false})
      {:ok, fields} = Form.fields(editor)
      field = Enum.find(fields, &(&1.name == "subscribe"))
      assert %Field{value: {:boolean, false}} = field
    end

    test "round-trips a previously-read value unchanged" do
      editor = Editor.open!(@form_pdf)
      {:ok, fields_before} = Form.fields(editor)
      field = Enum.find(fields_before, &(&1.name == "full_name"))
      assert :ok = Form.set_value(editor, "full_name", field.value)
      {:ok, fields_after} = Form.fields(editor)
      after_field = Enum.find(fields_after, &(&1.name == "full_name"))
      assert after_field.value == field.value
    end

    test "raises ArgumentError for a value that is not a tagged tuple" do
      editor = Editor.open!(@form_pdf)

      # The NIF cannot decode the value and raises :badarg. That is a caller
      # bug, so it propagates rather than becoming an {:error, _} tuple.
      assert_raise ArgumentError, fn -> Form.set_value(editor, "full_name", "Jane Doe") end
      assert_raise ArgumentError, fn -> Form.set_value(editor, "full_name", {:nope, "x"}) end
    end
  end

  describe "set_value!/3" do
    test "returns :ok for a known field" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value!(editor, "full_name", {:text, "Test"})
    end

    test "raises for an unknown field name" do
      editor = Editor.open!(@form_pdf)
      assert_raise Error, fn -> Form.set_value!(editor, "no_such_field", {:text, "x"}) end
    end

    test "raises ArgumentError for a value that is not a tagged tuple" do
      editor = Editor.open!(@form_pdf)
      assert_raise ArgumentError, fn -> Form.set_value!(editor, "full_name", "Jane Doe") end
    end
  end
end
