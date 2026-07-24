defmodule PdfElixide.EditorTest do
  use ExUnit.Case, async: true

  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @invalid_pdf Path.join(@fixtures, "invalid.bin")

  describe "open/1" do
    test "returns {:ok, %Editor{}} for a valid PDF file" do
      assert {:ok, %Editor{ref: ref, source_path: path}} = Editor.open(@valid_pdf)
      assert is_reference(ref)
      assert path == @valid_pdf
    end

    test "returns {:error, reason} for a file that is not a valid PDF" do
      assert {:error, %Error{reason: :invalid_pdf}} = Editor.open(@invalid_pdf)
    end
  end

  describe "open!/1" do
    test "returns an Editor struct for a valid PDF file" do
      assert %Editor{} = Editor.open!(@valid_pdf)
    end

    test "raises for a file that is not a valid PDF" do
      assert_raise Error, fn -> Editor.open!(@invalid_pdf) end
    end
  end

  describe "from_binary/1" do
    test "returns {:ok, %Editor{}} for valid PDF bytes" do
      pdf_bytes = File.read!(@valid_pdf)
      assert {:ok, %Editor{ref: ref, source_path: nil}} = Editor.from_binary(pdf_bytes)
      assert is_reference(ref)
    end

    test "returns {:error, reason} for invalid bytes" do
      assert {:error, %Error{reason: :invalid_pdf}} = Editor.from_binary("not a pdf")
    end

    test "returns {:error, reason} for empty binary" do
      assert {:error, %Error{reason: :invalid_pdf}} = Editor.from_binary(<<>>)
    end
  end

  describe "from_binary!/1" do
    test "returns an Editor struct for valid PDF bytes" do
      pdf_bytes = File.read!(@valid_pdf)
      assert %Editor{} = Editor.from_binary!(pdf_bytes)
    end

    test "raises for invalid bytes" do
      assert_raise Error, fn -> Editor.from_binary!("not a pdf") end
    end
  end

  describe "source_path/1" do
    test "returns the original path after open/1" do
      editor = Editor.open!(@valid_pdf)
      assert Editor.source_path(editor) == @valid_pdf
    end

    test "returns nil after from_binary/1" do
      editor = Editor.from_binary!(File.read!(@valid_pdf))
      assert Editor.source_path(editor) == nil
    end
  end

  describe "to_binary/1" do
    test "returns {:ok, bytes} where bytes is a non-empty binary" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, bytes} = Editor.to_binary(editor)
      assert is_binary(bytes)
      assert byte_size(bytes) > 0
    end

    test "returned bytes are a valid PDF (round-trips into a new editor)" do
      editor = Editor.open!(@form_pdf)
      {:ok, bytes} = Editor.to_binary(editor)
      assert {:ok, %Editor{}} = Editor.from_binary(bytes)
    end

    test "form field mutations are present in the saved bytes" do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "full_name", {:text, "Jane Doe"})
      {:ok, bytes} = Editor.to_binary(editor)
      assert String.contains?(bytes, "Jane Doe")
    end

    test "to_binary/2 with compress and garbage_collect disabled still round-trips" do
      editor = Editor.open!(@form_pdf)

      assert {:ok, bytes} =
               Editor.to_binary(editor, compress: false, garbage_collect: false)

      assert byte_size(bytes) > 0
      assert {:ok, %Editor{}} = Editor.from_binary(bytes)
    end

    test "to_binary/2 with linearize: true returns a round-trippable PDF" do
      editor = Editor.open!(@form_pdf)
      assert {:ok, bytes} = Editor.to_binary(editor, linearize: true)
      assert byte_size(bytes) > 0
      assert {:ok, %Editor{}} = Editor.from_binary(bytes)
    end

    test "to_binary/2 with incremental: true returns {:error, reason}" do
      editor = Editor.open!(@form_pdf)
      assert {:error, _reason} = Editor.to_binary(editor, incremental: true)
    end

    test "to_binary/2 with a non-boolean option returns an error rather than crashing" do
      editor = Editor.open!(@form_pdf)

      # An undecodable option map is reported by the NIF as a message string,
      # so it arrives as an ordinary error struct.
      assert {:error, %Error{reason: :other}} = Editor.to_binary(editor, compress: "yes")
    end
  end

  describe "to_binary!/1" do
    test "returns a binary directly" do
      editor = Editor.open!(@form_pdf)
      assert is_binary(Editor.to_binary!(editor))
    end
  end

  describe "save/2" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "pdf_elixide_save_#{System.unique_integer([:positive])}.pdf")

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    test "writes a non-empty PDF file to the given path", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      assert :ok = Editor.save(editor, out_path)
      assert File.exists?(out_path)
      assert File.stat!(out_path).size > 0
    end

    test "the written file round-trips into a new editor", %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)
      :ok = Editor.save(editor, out_path)
      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
    end

    test "returns {:error, reason} when the target directory does not exist" do
      editor = Editor.open!(@valid_pdf)

      bogus =
        Path.join([
          "/",
          "nonexistent_pdf_elixide_dir_#{System.unique_integer([:positive])}",
          "out.pdf"
        ])

      assert {:error, _reason} = Editor.save(editor, bogus)
    end

    test "save/3 with incremental: true writes a round-trippable PDF",
         %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)
      assert :ok = Editor.save(editor, out_path, incremental: true)
      assert File.stat!(out_path).size > 0
      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
    end

    test "save/3 with compress and garbage_collect disabled still round-trips",
         %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)

      assert :ok =
               Editor.save(editor, out_path, compress: false, garbage_collect: false)

      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
    end
  end

  describe "save!/2" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "pdf_elixide_save_bang_#{System.unique_integer([:positive])}.pdf"
        )

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    test "returns :ok on success", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      assert :ok = Editor.save!(editor, out_path)
      assert File.exists?(out_path)
    end

    test "raises when the target directory does not exist" do
      editor = Editor.open!(@valid_pdf)

      bogus =
        Path.join([
          "/",
          "nonexistent_pdf_elixide_dir_#{System.unique_integer([:positive])}",
          "out.pdf"
        ])

      assert_raise Error, fn -> Editor.save!(editor, bogus) end
    end
  end

  describe "close/1 and closed?/1" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "pdf_elixide_close_#{System.unique_integer([:positive])}.pdf"
        )

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    test "closed?/1 flips once the editor is closed" do
      editor = Editor.open!(@valid_pdf)
      refute Editor.closed?(editor)

      assert :ok = Editor.close(editor)
      assert Editor.closed?(editor)
    end

    test "close/1 is idempotent" do
      editor = Editor.open!(@valid_pdf)

      assert :ok = Editor.close(editor)
      assert :ok = Editor.close(editor)
    end

    test "using a closed editor returns a :closed error", %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed, message: "Editor is closed"}} =
               Editor.to_binary(editor)

      assert {:error, %Error{reason: :closed}} = Editor.save(editor, out_path)
      assert {:error, %Error{reason: :closed}} = Form.fields(editor)

      assert {:error, %Error{reason: :closed}} =
               Form.set_value(editor, "full_name", {:text, "Ada"})

      refute File.exists?(out_path)
    end

    test "bang variants raise on a closed editor", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      error = assert_raise Error, fn -> Editor.to_binary!(editor) end
      assert error.reason == :closed

      assert_raise Error, "Editor is closed", fn -> Editor.save!(editor, out_path) end
    end

    test "source_path/1 keeps working after close" do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      assert Editor.source_path(editor) == @valid_pdf
      assert inspect(editor) == "#PdfElixide.Editor<sample.pdf>"
    end

    test "edits saved before closing are unaffected", %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)
      :ok = Form.set_value(editor, "full_name", {:text, "Ada"})
      :ok = Editor.save(editor, out_path)

      :ok = Editor.close(editor)

      reopened = Editor.open!(out_path)
      assert {:ok, fields} = Form.fields(reopened)
      assert Enum.any?(fields, &(&1.name == "full_name" and &1.value == {:text, "Ada"}))
    end
  end
end
