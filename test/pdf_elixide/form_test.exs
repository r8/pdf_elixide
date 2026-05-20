defmodule PdfElixide.FormTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Form
  alias PdfElixide.Form.Field

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @form_pdf Path.join(@fixtures, "form.pdf")
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

  describe "set_value/3" do
    test "returns :ok for a known field" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value(editor, "full_name", {:text, "Jane Doe"})
    end

    test "returns {:error, _} for an unknown field name" do
      editor = Editor.open!(@form_pdf)
      assert {:error, _} = Form.set_value(editor, "no_such_field", {:text, "x"})
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
  end

  describe "set_value!/3" do
    test "returns :ok for a known field" do
      editor = Editor.open!(@form_pdf)
      assert :ok = Form.set_value!(editor, "full_name", {:text, "Test"})
    end

    test "raises for an unknown field name" do
      editor = Editor.open!(@form_pdf)
      assert_raise RuntimeError, fn -> Form.set_value!(editor, "no_such_field", {:text, "x"}) end
    end
  end
end
