defmodule PdfElixide.FormTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Document
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
end
