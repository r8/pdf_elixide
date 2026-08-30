defmodule PdfElixide.EditorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @no_pages_pdf Path.join(@fixtures, "no_pages.pdf")
  @invalid_pdf Path.join(@fixtures, "invalid.bin")
  @flatten_pdf Path.join(@fixtures, "flatten.pdf")
  @rotation_pdf Path.join(@fixtures, "rotation.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")

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

  describe "version/1" do
    test "returns the source document's version as a {major, minor} tuple" do
      editor = Editor.open!(@valid_pdf)
      assert Editor.version(editor) == {1, 4}
    end

    test "agrees with the same document opened read-only" do
      editor = Editor.open!(@valid_pdf)
      doc = Document.open!(@valid_pdf)

      assert Editor.version(editor) == Document.version(doc)
    end

    test "is cached at open, so it survives close/1" do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      assert Editor.version(editor) == {1, 4}
    end
  end

  describe "page_count/1 and page_count!/1" do
    test "counts the pages of the document being edited" do
      editor = Editor.open!(@valid_pdf)

      assert {:ok, 3} = Editor.page_count(editor)
      assert Editor.page_count!(editor) == 3
    end

    test "counts the same after from_binary/1" do
      editor = Editor.from_binary!(File.read!(@valid_pdf))
      assert Editor.page_count!(editor) == 3
    end

    test "agrees with the same document opened read-only" do
      editor = Editor.open!(@valid_pdf)
      doc = Document.open!(@valid_pdf)

      assert Editor.page_count!(editor) == Document.page_count!(doc)
    end

    test "answers 0 for a document with no pages" do
      editor = Editor.open!(@no_pages_pdf)
      assert {:ok, 0} = Editor.page_count(editor)
    end

    test "is unchanged by an edit that does not touch the page tree" do
      editor = Editor.open!(@form_pdf)
      before = Editor.page_count!(editor)

      Form.put_value!(editor, "full_name", "Ada")

      assert Editor.page_count!(editor) == before
    end

    test "reports a closed editor rather than a cached number" do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.page_count(editor)
      assert_raise Error, "Editor is closed", fn -> Editor.page_count!(editor) end
    end
  end

  describe "modified?/1" do
    test "is false for a freshly opened editor" do
      refute Editor.modified?(Editor.open!(@form_pdf))
    end

    test "flips once the editor is changed" do
      editor = Editor.open!(@form_pdf)
      Form.put_value!(editor, "full_name", "Ada")

      assert Editor.modified?(editor)
    end

    test "to_binary/2 clears it, even though it writes no file" do
      editor = Editor.open!(@form_pdf)
      Form.put_value!(editor, "full_name", "Ada")

      {:ok, _bytes} = Editor.to_binary(editor)

      refute Editor.modified?(editor)
    end

    test "raises on a closed editor" do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      assert_raise Error, "Editor is closed", fn -> Editor.modified?(editor) end
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
      Form.put_value!(editor, "full_name", "Jane Doe")
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

    test "to_binary/2 with incremental: true returns {:error, reason}" do
      editor = Editor.open!(@form_pdf)
      assert {:error, _reason} = Editor.to_binary(editor, incremental: true)
    end

    test "to_binary/2 with a non-boolean option raises, naming the option" do
      editor = Editor.open!(@form_pdf)

      # The NIF reports an undecodable option map as a message string naming
      # the field; `Native.Wrap.call/1` turns that into an `ArgumentError`,
      # since a bad option is a caller bug rather than a document failure.
      assert_raise ArgumentError, ~r/:compress/, fn ->
        Editor.to_binary(editor, compress: "yes")
      end
    end

    test "to_binary/2 with an unknown option raises" do
      editor = Editor.open!(@form_pdf)

      assert_raise ArgumentError, ~r/:compres/, fn ->
        Editor.to_binary(editor, compres: true)
      end
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
      assert {:ok, ^editor} = Editor.save(editor, out_path)
      assert File.exists?(out_path)
      assert File.stat!(out_path).size > 0
    end

    test "the written file round-trips into a new editor", %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)
      Editor.save!(editor, out_path)
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
      assert {:ok, ^editor} = Editor.save(editor, out_path, incremental: true)
      assert File.stat!(out_path).size > 0
      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
    end

    test "save/3 with compress and garbage_collect disabled still round-trips",
         %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)

      assert {:ok, ^editor} =
               Editor.save(editor, out_path, compress: false, garbage_collect: false)

      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
    end

    test "the returned editor is still usable", %{out_path: out_path} do
      second_path = out_path <> ".second"
      on_exit(fn -> File.rm(second_path) end)

      editor = Editor.open!(@form_pdf)

      # Writing does not consume the editor, which is what makes returning it
      # from `save/3` safe rather than merely convenient.
      assert {:ok, editor} = Editor.save(editor, out_path)
      assert {:ok, _editor} = Editor.save(editor, second_path)

      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(second_path))
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

    test "returns the editor on success", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      assert ^editor = Editor.save!(editor, out_path)
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
      assert {:error, %Error{reason: :closed}} = Editor.page_count(editor)
      assert {:error, %Error{reason: :closed}} = Form.fields(editor)

      assert {:error, %Error{reason: :closed}} =
               Form.put_value(editor, "full_name", "Ada")

      assert {:error, %Error{reason: :closed}} = Editor.delete_page(editor, 0)
      assert {:error, %Error{reason: :closed}} = Editor.move_page(editor, 0, 0)
      assert {:error, %Error{reason: :closed}} = Editor.rotation(editor, 0)
      assert {:error, %Error{reason: :closed}} = Editor.set_rotation(editor, 0, 90)
      assert {:error, %Error{reason: :closed}} = Editor.rotate_page_by(editor, 0, 90)
      assert {:error, %Error{reason: :closed}} = Editor.rotate_all_by(editor, 90)

      refute File.exists?(out_path)
    end

    test "bang variants raise on a closed editor", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      error = assert_raise Error, fn -> Editor.to_binary!(editor) end
      assert error.reason == :closed

      assert_raise Error, "Editor is closed", fn -> Editor.save!(editor, out_path) end
      assert_raise Error, "Editor is closed", fn -> Editor.page_count!(editor) end
      assert_raise Error, "Editor is closed", fn -> Editor.rotation!(editor, 0) end
      assert_raise Error, "Editor is closed", fn -> Editor.set_rotation!(editor, 0, 90) end
      assert_raise Error, "Editor is closed", fn -> Editor.rotate_page_by!(editor, 0, 90) end
      assert_raise Error, "Editor is closed", fn -> Editor.rotate_all_by!(editor, 90) end
      assert_raise Error, "Editor is closed", fn -> Editor.delete_page!(editor, 0) end
      assert_raise Error, "Editor is closed", fn -> Editor.move_page!(editor, 0, 0) end
    end

    test "the struct-reading functions keep working after close" do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      assert Editor.source_path(editor) == @valid_pdf
      assert Editor.version(editor) == {1, 4}
      assert inspect(editor) == "#PdfElixide.Editor<sample.pdf>"
    end

    test "edits saved before closing are unaffected", %{out_path: out_path} do
      editor = Editor.open!(@form_pdf)
      Form.put_value!(editor, "full_name", "Ada")
      Editor.save!(editor, out_path)

      :ok = Editor.close(editor)

      reopened = Editor.open!(out_path)
      assert {:ok, fields} = Form.fields(reopened)
      assert Enum.any?(fields, &(&1.name == "full_name" and &1.value == "Ada"))
    end
  end

  describe "the editing pipeline" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "pdf_elixide_pipeline_#{System.unique_integer([:positive])}.pdf"
        )

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    test "open, fill, save and close compose as one expression", %{out_path: out_path} do
      assert :ok =
               @form_pdf
               |> Editor.open!()
               |> Form.put_value!("full_name", "Jane Doe")
               |> Form.put_value!("subscribe", true)
               |> Editor.save!(out_path)
               |> Editor.close()

      reopened = Document.open!(out_path)
      assert {:ok, "Jane Doe"} = Form.value(reopened, "full_name")
      assert {:ok, true} = Form.value(reopened, "subscribe")
    end

    test "the tuple half reads as one with/1", %{out_path: out_path} do
      values = %{"full_name" => "Jane Doe", "country" => ["Canada"]}

      result =
        with {:ok, editor} <- Editor.open(@form_pdf),
             {:ok, editor} <- Form.put_values(editor, values),
             {:ok, editor} <- Editor.save(editor, out_path) do
          Editor.close(editor)
        end

      assert result == :ok

      reopened = Document.open!(out_path)
      assert {:ok, "Jane Doe"} = Form.value(reopened, "full_name")
      assert {:ok, ["Canada"]} = Form.value(reopened, "country")
    end
  end

  # `sample.pdf` carries one distinguishable line per page, so the page *order*
  # is observable in the reopened document rather than only the page count.
  defp page_texts(editor) do
    doc = Document.from_binary!(Editor.to_binary!(editor))
    texts = doc |> Enum.map(&Document.Page.text!/1) |> Enum.map(&String.trim/1)
    Document.close(doc)

    texts
  end

  describe "delete_page/2" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.delete_page(editor, 1)
      assert Editor.modified?(editor)
    end

    test "drops the page, shifting the ones after it down" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)

      assert page_texts(editor) == ["Page One", "Page Three"]
    end

    test "page_count/1 answers the new count before any save" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      assert Editor.page_count!(editor) == 3

      Editor.delete_page!(editor, 0)

      assert Editor.page_count!(editor) == 2
    end

    test "deleting every page empties the editor and still writes a file" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      for _ <- 1..3, do: Editor.delete_page!(editor, 0)

      assert Editor.page_count!(editor) == 0
      assert {:ok, bytes} = Editor.to_binary(editor)
      assert byte_size(bytes) > 0
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.delete_page(editor, 3)
    end

    test "returns {:error, :out_of_range} on a document with no pages" do
      editor = Editor.open!(@no_pages_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.delete_page(editor, 0)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.delete_page(editor, -1) end
    end
  end

  describe "move_page/3" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.move_page(editor, 0, 2)
      assert Editor.modified?(editor)
    end

    test "moves a page later, leaving it at the destination index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 0, 2)

      assert page_texts(editor) == ["Page Two", "Page Three", "Page One"]
    end

    test "moves a page earlier" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 2, 0)

      assert page_texts(editor) == ["Page Three", "Page One", "Page Two"]
    end

    test "moving a page onto its own index leaves the order alone" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 1, 1)

      assert page_texts(editor) == ["Page One", "Page Two", "Page Three"]
    end

    test "leaves the page count alone" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 0, 2)

      assert Editor.page_count!(editor) == 3
    end

    test "returns {:error, :out_of_range} for a source past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.move_page(editor, 3, 0)
    end

    test "returns {:error, :out_of_range} for a destination past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.move_page(editor, 0, 3)
    end

    test "raises for a negative index in either position" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.move_page(editor, -1, 0) end
      assert_raise FunctionClauseError, fn -> Editor.move_page(editor, 0, -1) end
    end

    test "counts from what a deletion left behind" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.delete_page!(1) |> Editor.move_page!(1, 0)

      assert page_texts(editor) == ["Page Three", "Page One"]
    end
  end

  # `rotation.pdf` carries one page per branch of /Rotate resolution: 90 on the
  # leaf, 180 inherited from an intermediate /Pages node, -90 and the invalid 45.
  defp saved_rotations(editor) do
    doc = Document.from_binary!(Editor.to_binary!(editor))
    rotations = Enum.map(doc, &Document.Page.rotation!/1)
    Document.close(doc)

    rotations
  end

  defp rotations(editor) do
    for page <- 0..(Editor.page_count!(editor) - 1), do: Editor.rotation!(editor, page)
  end

  describe "rotation/2" do
    test "answers what the read side answers for the same page" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert rotations(editor) == [90, 180, 270, 0]
      assert rotations(editor) == saved_rotations(editor)
    end

    test "reflects a pending rotation before any save" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_rotation!(editor, 0, 180)

      assert {:ok, 180} = Editor.rotation(editor, 0)
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.rotation(editor, 3)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.rotation(editor, -1) end
    end
  end

  describe "set_rotation/3" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.set_rotation(editor, 0, 180)
      assert Editor.modified?(editor)
    end

    test "writes the angle into the saved document" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.set_rotation!(0, 0) |> Editor.set_rotation!(3, 270)

      assert saved_rotations(editor) == [0, 180, 270, 270]
    end

    test "is absolute rather than a delta" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_rotation!(editor, 1, 90)

      assert Editor.rotation!(editor, 1) == 90
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.set_rotation(editor, 3, 90)
    end

    test "raises for an angle that is not a quadrant" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.set_rotation(editor, 0, 45) end
      assert_raise FunctionClauseError, fn -> Editor.set_rotation(editor, 0, -90) end
      assert_raise FunctionClauseError, fn -> Editor.set_rotation(editor, 0, 360) end
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.set_rotation(editor, -1, 90) end
    end
  end

  describe "rotate_page_by/3" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.rotate_page_by(editor, 0, 90)
      assert Editor.modified?(editor)
    end

    test "adds to the angle the page already has, wrapping past 360" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.rotate_page_by!(editor, 0, 90)
      Editor.rotate_page_by!(editor, 1, 270)

      assert Editor.rotation!(editor, 0) == 180
      assert Editor.rotation!(editor, 1) == 90
    end

    test "adds to an inherited angle" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.rotate_page_by!(editor, 1, 90)

      assert Editor.rotation!(editor, 1) == 270
    end

    test "turns anticlockwise for a negative delta" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.rotate_page_by!(editor, 0, -90)

      assert Editor.rotation!(editor, 0) == 0
    end

    test "rounds a delta that is not a multiple of 90 to the nearest quadrant" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.rotate_page_by!(0, 45) |> Editor.rotate_page_by!(1, 134)

      assert Editor.rotation!(editor, 0) == 180
      assert Editor.rotation!(editor, 1) == 270
    end

    test "leaves an invalid /Rotate at zero rather than rounding it up" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.rotate_page_by!(editor, 3, 0)

      assert Editor.rotation!(editor, 3) == 0
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.rotate_page_by(editor, 3, 90)
    end

    test "accepts a delta larger than a machine integer" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.rotate_page_by!(editor, 0, 36_000_000_090)

      assert Editor.rotation!(editor, 0) == 180
    end

    test "raises for a negative page index or a non-integer delta" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by(editor, -1, 90) end
      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by(editor, 0, 90.0) end
    end
  end

  describe "rotate_all_by/2" do
    test "turns every page from its own angle" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.rotate_all_by(editor, 90)

      assert rotations(editor) == [180, 270, 0, 90]
      assert saved_rotations(editor) == [180, 270, 0, 90]
    end

    test "changes nothing on a document with no pages" do
      editor = Editor.open!(@no_pages_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.rotate_all_by(editor, 90)
      refute Editor.modified?(editor)
    end

    # `broken_page.pdf`'s /Count claims three pages where the tree holds two, so
    # page 2 clears the bounds check and then fails to resolve — the only fixture
    # where a later page's read fails after an earlier page's has succeeded.
    test "turns no page at all when a later page cannot be read" do
      editor = Editor.open!(@broken_page_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.rotate_all_by(editor, 90)

      assert Editor.rotation!(editor, 0) == 0
      refute Editor.modified?(editor)
    end

    test "accepts a delta larger than a machine integer" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.rotate_all_by!(editor, -36_000_000_090)

      assert rotations(editor) == [0, 90, 180, 270]
    end

    test "raises for a non-integer delta" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.rotate_all_by(editor, 90.0) end
    end
  end

  describe "rotation and the page operations" do
    test "a rotation follows its page through a move" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 0, 3)

      assert rotations(editor) == [180, 270, 0, 90]
      assert saved_rotations(editor) == [180, 270, 0, 90]
    end

    test "a rotation set before a move travels with the page" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.set_rotation!(0, 270) |> Editor.move_page!(0, 3)

      assert Editor.rotation!(editor, 3) == 270
      assert saved_rotations(editor) == [180, 270, 0, 270]
    end

    test "deleting a page does not shift the rotations of the survivors" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 0)

      assert rotations(editor) == [180, 270, 0]
      assert saved_rotations(editor) == [180, 270, 0]
    end

    test "rotating after a deletion turns the page that survived" do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.delete_page!(0) |> Editor.rotate_page_by!(0, 90)

      assert saved_rotations(editor) == [270, 270, 0]
    end
  end

  describe "flatten_annotations/1" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@flatten_pdf)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.flatten_annotations(editor)
      assert Editor.modified?(editor)
    end

    test "draws the annotation appearances into the page and removes them all" do
      editor = Editor.open!(@flatten_pdf)

      {:ok, flattened} = editor |> Editor.flatten_annotations!() |> Editor.to_binary()
      {:ok, doc} = Document.from_binary(flattened)

      assert Document.text!(doc, 0) =~ "FLATTENED"
      # Widgets go with the rest, so the form fields lose their widgets too.
      assert Document.annotations!(doc, 0) == []
    end

    # With no page to mark, only the bulk call can set the modified flag.
    test "marks a document with no pages modified anyway" do
      editor = Editor.open!(@no_pages_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.flatten_annotations(editor)
      assert Editor.modified?(editor)
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@flatten_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.flatten_annotations(editor)
    end
  end

  describe "flatten_annotations/2" do
    test "leaves the other pages alone" do
      editor = Editor.open!(@flatten_pdf)

      {:ok, flattened} = editor |> Editor.flatten_annotations!(0) |> Editor.to_binary()
      {:ok, doc} = Document.from_binary(flattened)

      assert Document.annotations!(doc, 0) == []
      assert length(Document.annotations!(doc, 1)) == 1
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@flatten_pdf)

      assert {:error, %Error{reason: :out_of_range}} = Editor.flatten_annotations(editor, 2)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@flatten_pdf)

      assert_raise FunctionClauseError, fn -> Editor.flatten_annotations(editor, -1) end
    end
  end

  describe "flatten_warnings/1" do
    test "is empty before a write, since flattening is deferred" do
      editor = Editor.open!(@flatten_pdf)
      Form.flatten!(editor)

      assert {:ok, []} = Editor.flatten_warnings(editor)
    end

    test "names the field that could not be given an appearance" do
      editor = Editor.open!(@flatten_pdf)
      {:ok, _} = editor |> Form.flatten!() |> Editor.to_binary()

      assert [warning] = Editor.flatten_warnings!(editor)
      assert warning =~ "orphan"
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@flatten_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.flatten_warnings(editor)
    end
  end
end
