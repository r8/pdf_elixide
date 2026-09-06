defmodule PdfElixide.EditorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.EmbeddedFile
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Form
  alias PdfElixide.Geometry.Rect

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @indirect_contents_pdf Path.join(@fixtures, "contents_indirect_array.pdf")
  @form_pdf Path.join(@fixtures, "form.pdf")
  @no_pages_pdf Path.join(@fixtures, "no_pages.pdf")
  @invalid_pdf Path.join(@fixtures, "invalid.bin")
  @flatten_pdf Path.join(@fixtures, "flatten.pdf")
  @rotation_pdf Path.join(@fixtures, "rotation.pdf")
  @broken_page_pdf Path.join(@fixtures, "broken_page.pdf")
  @attachments_pdf Path.join(@fixtures, "attachments.pdf")
  @attachments_cyclic_pdf Path.join(@fixtures, "attachments_cyclic.pdf")
  @metadata_pdf Path.join(@fixtures, "metadata.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")

  describe "open/1" do
    test "returns {:ok, %Editor{}} for a valid PDF file" do
      assert {:ok, %Editor{ref: ref, source_path: path}} = Editor.open(@valid_pdf)
      assert is_reference(ref)
      assert path == @valid_pdf
    end

    test "returns {:error, reason} for a file that is not a valid PDF" do
      assert {:error, %Error{reason: :invalid_pdf}} = Editor.open(@invalid_pdf)
    end

    # Saving one writes still-encrypted stream bytes under a `/Filter` dict and
    # reports success, so the refusal is what keeps the corruption unreachable.
    test "refuses an encrypted document rather than editing it into corruption" do
      assert {:error, %Error{reason: :encrypted, message: message}} =
               Editor.open(@encrypted_pdf)

      assert message =~ "PdfElixide.Document"
    end
  end

  describe "open!/1" do
    test "returns an Editor struct for a valid PDF file" do
      assert %Editor{} = Editor.open!(@valid_pdf)
    end

    test "raises for a file that is not a valid PDF" do
      assert_raise Error, fn -> Editor.open!(@invalid_pdf) end
    end

    test "raises for an encrypted document" do
      assert_raise Error, ~r/encrypted/, fn -> Editor.open!(@encrypted_pdf) end
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

    test "refuses encrypted bytes" do
      assert {:error, %Error{reason: :encrypted}} =
               Editor.from_binary(File.read!(@encrypted_pdf))
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

      assert {:ok, editor} = Editor.save(editor, out_path)
      assert {:ok, _editor} = Editor.save(editor, second_path)

      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(out_path))
      assert {:ok, %Editor{}} = Editor.from_binary(File.read!(second_path))
    end
  end

  describe ":encryption on a write" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "pdf_elixide_enc_#{System.unique_integer([:positive])}.pdf")

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    for algorithm <- [:aes128, :rc4_128] do
      test "#{algorithm} writes a file whose content survives the round trip",
           %{out_path: out_path} do
        editor = Editor.open!(@valid_pdf)

        Editor.save!(editor, out_path,
          encryption: [
            user_password: "secret",
            owner_password: "owner",
            algorithm: unquote(algorithm)
          ]
        )

        assert Document.encrypted?(Document.open!(out_path))

        doc = Document.open!(out_path, password: "secret")

        assert Enum.map(0..2, &String.trim(Document.text!(doc, &1))) ==
                 ["Page One", "Page Two", "Page Three"]
      end
    end

    test "the default algorithm is :aes128", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      Editor.save!(editor, out_path, encryption: [user_password: "secret"])

      # `/V 4 /R 4` is AES-128; the `/Encrypt` dictionary is written unencrypted,
      # so it can be read out of the raw bytes.
      bytes = File.read!(out_path)
      assert bytes =~ "/V 4"
      assert bytes =~ "/R 4"
    end

    test "a wrong password is refused", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      Editor.save!(editor, out_path, encryption: [user_password: "secret"])

      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(out_path, password: "wrong")
    end

    test "an empty user password opens without one but still carries the flags",
         %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      Editor.save!(editor, out_path, encryption: [permissions: [copy: false]])

      doc = Document.open!(out_path)
      assert Document.encrypted?(doc)
      assert String.trim(Document.text!(doc, 0)) == "Page One"
      refute Document.permissions!(doc).copy
    end

    test "the flags read back the way they were written", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)

      Editor.save!(editor, out_path,
        encryption: [
          user_password: "secret",
          permissions: [print_low_res: false, print_high_res: false, copy: false]
        ]
      )

      doc = Document.open!(out_path, password: "secret")

      assert %Document.Permissions{
               print_low_res: false,
               print_high_res: false,
               copy: false,
               modify: true,
               annotate: true,
               fill_forms: true,
               accessibility: true,
               assemble: true
             } = Document.permissions!(doc)
    end

    test "to_binary/2 encrypts too" do
      editor = Editor.open!(@valid_pdf)
      bytes = Editor.to_binary!(editor, encryption: [user_password: "secret"])

      assert {:error, %Error{reason: :wrong_password}} =
               Document.from_binary(bytes, password: "wrong")

      doc = Document.from_binary!(bytes, password: "secret")
      assert String.trim(Document.text!(doc, 0)) == "Page One"
    end

    test "an unencrypted save leaves no permission dictionary", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      Editor.save!(editor, out_path)

      doc = Document.open!(out_path)
      refute Document.encrypted?(doc)
      assert Document.permissions!(doc) == nil
    end

    test ":aes256 raises, naming the algorithm" do
      editor = Editor.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:aes256/, fn ->
        Editor.to_binary(editor, encryption: [algorithm: :aes256])
      end
    end

    test ":rc4_40 raises, naming the algorithm" do
      editor = Editor.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:rc4_40/, fn ->
        Editor.to_binary(editor, encryption: [algorithm: :rc4_40])
      end
    end

    test "incremental: true with :encryption raises rather than writing plaintext",
         %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:encryption/, fn ->
        Editor.save(editor, out_path, incremental: true, encryption: [user_password: "secret"])
      end

      refute File.exists?(out_path)
    end

    test "incremental: true on its own is still accepted", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      assert {:ok, ^editor} = Editor.save(editor, out_path, incremental: true)
    end

    test "the owner password opens the document too", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)

      Editor.save!(editor, out_path,
        encryption: [user_password: "user-pw", owner_password: "owner-pw"]
      )

      doc = Document.open!(out_path, password: "owner-pw")
      assert String.trim(Document.text!(doc, 0)) == "Page One"
    end

    test "one editor alternates encrypted and unencrypted writes", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)
      plain = out_path <> ".plain"
      second = out_path <> ".second"
      on_exit(fn -> Enum.each([plain, second], &File.rm/1) end)

      Editor.save!(editor, out_path, encryption: [user_password: "first"])
      Editor.save!(editor, plain)
      Editor.save!(editor, second, encryption: [user_password: "second"])

      refute Document.encrypted?(Document.open!(plain))
      assert String.trim(Document.text!(Document.open!(plain), 0)) == "Page One"

      assert String.trim(Document.text!(Document.open!(out_path, password: "first"), 0)) ==
               "Page One"

      assert String.trim(Document.text!(Document.open!(second, password: "second"), 0)) ==
               "Page One"

      assert {:error, %Error{reason: :wrong_password}} =
               Document.open(out_path, password: "second")
    end

    # The non-ASCII filename exercises the encrypted UTF-16BE `/UF` string.
    test "an attachment survives an encrypted save", %{out_path: out_path} do
      editor = Editor.open!(@valid_pdf)

      editor
      |> Editor.embed_file!("résumé.txt", "body")
      |> Editor.save!(out_path, encryption: [user_password: "secret"])

      doc = Document.open!(out_path, password: "secret")

      assert [%EmbeddedFile{name: "résumé.txt", data: "body"}] = Document.embedded_files!(doc)
    end

    # Disable compression and check a plaintext control so absence of these
    # bytes demonstrates encryption rather than deflate.
    test "metadata is encrypted along with everything else" do
      editor = Editor.open!(@metadata_pdf)

      plain = Editor.to_binary!(editor, compress: false)
      assert plain =~ "xmpmeta"
      assert plain =~ "Test Title"

      encrypted =
        Editor.to_binary!(editor, compress: false, encryption: [user_password: "secret"])

      refute encrypted =~ "xmpmeta"
      refute encrypted =~ "Test Title"

      assert Document.encrypted?(Document.from_binary!(encrypted))
      assert {:ok, _} = Document.from_binary(encrypted, password: "secret")
    end

    test "a wrong-typed value inside :encryption raises, naming :encryption" do
      editor = Editor.open!(@valid_pdf)

      assert_raise ArgumentError, ~r/:encryption/, fn ->
        Editor.to_binary(editor, encryption: [user_password: 1])
      end

      assert_raise ArgumentError, ~r/:encryption/, fn ->
        Editor.to_binary(editor, encryption: [permissions: [copy: "yes"]])
      end
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

  @erase_rect %Rect{x: 72.0, y: 700.0, width: 200.0, height: 40.0}

  defp saved_whiteouts(editor) do
    doc = Document.from_binary!(Editor.to_binary!(editor))

    pages =
      Enum.map(doc, fn page ->
        rects = page |> Document.Page.rects!() |> Enum.map(&{&1.bbox, &1.fill_color})
        {String.trim(Document.Page.text!(page)), rects}
      end)

    Document.close(doc)

    pages
  end

  describe "erase_region/3" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.erase_region(editor, 0, @erase_rect)
      assert Editor.modified?(editor)
    end

    test "paints a white rectangle over the region and leaves the text beneath it" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.erase_region!(editor, 0, @erase_rect)

      white = %PdfElixide.Color.RGB{r: 1.0, g: 1.0, b: 1.0}

      assert saved_whiteouts(editor) == [
               {"Page One", [{@erase_rect, white}]},
               {"Page Two", []},
               {"Page Three", []}
             ]
    end

    test "normalizes reversed corners" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.erase_region!(editor, 0, %Rect{x: 272.0, y: 740.0, width: -200.0, height: -40.0})

      assert [{_, [{@erase_rect, _}]} | _] = saved_whiteouts(editor)
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.erase_region(editor, 3, @erase_rect)
    end

    # The fixture's `/Contents` refers to an array object rather than a stream.
    test "returns {:error, :unsupported} for a page whose content streams are an indirect array" do
      editor = Editor.open!(@indirect_contents_pdf)
      on_exit(fn -> Editor.close(editor) end)

      plain = Document.from_binary!(Editor.to_binary!(editor))
      on_exit(fn -> Document.close(plain) end)
      assert Document.text!(plain, 0) =~ "Indirect"

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.erase_region(editor, 0, @erase_rect)

      assert message =~ "indirect array"
      refute Editor.modified?(editor)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.erase_region(editor, -1, @erase_rect) end
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@valid_pdf)
      Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.erase_region(editor, 0, @erase_rect)
    end
  end

  describe "erase_regions/3" do
    test "paints every rectangle in the list" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      other = %Rect{x: 72.0, y: 600.0, width: 100.0, height: 20.0}
      Editor.erase_regions!(editor, 0, [@erase_rect, other])

      assert [{"Page One", rects} | _] = saved_whiteouts(editor)
      assert Enum.map(rects, &elem(&1, 0)) == [@erase_rect, other]
    end

    test "raises for an empty list" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/at least one region/, fn ->
        Editor.erase_regions(editor, 0, [])
      end

      refute Editor.modified?(editor)
    end

    test "raises for a wrong-typed field, naming it" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/Could not decode field :x/, fn ->
        Editor.erase_regions(editor, 0, [%Rect{x: "72", y: 700.0, width: 200.0, height: 40.0}])
      end
    end

    # In the first two only the far corner overflows; each field fits on its own.
    test "raises for a region whose corner overflows a 32-bit float" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/corners must fit a 32-bit float/, fn ->
        Editor.erase_regions(editor, 0, [%Rect{x: 2.0e38, y: 0.0, width: 2.0e38, height: 10.0}])
      end

      assert_raise ArgumentError, ~r/corners must fit a 32-bit float/, fn ->
        Editor.erase_region(editor, 0, %Rect{x: 0.0, y: -2.0e38, width: 10.0, height: -2.0e38})
      end

      assert_raise ArgumentError, ~r/corners must fit a 32-bit float/, fn ->
        Editor.erase_regions(editor, 0, [%Rect{x: 1.0e300, y: 0.0, width: 10.0, height: 10.0}])
      end

      refute Editor.modified?(editor)
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} =
               Editor.erase_regions(editor, 3, [@erase_rect])
    end
  end

  describe "clear_erase_regions/2" do
    test "drops the pending regions so the written page is untouched" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.erase_region!(0, @erase_rect) |> Editor.clear_erase_regions!(0)

      assert [{"Page One", []} | _] = saved_whiteouts(editor)
    end

    test "leaves the other pages' regions alone" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor
      |> Editor.erase_region!(0, @erase_rect)
      |> Editor.erase_region!(1, @erase_rect)
      |> Editor.clear_erase_regions!(0)

      assert [{"Page One", []}, {"Page Two", [_]}, {"Page Three", []}] = saved_whiteouts(editor)
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.clear_erase_regions(editor, 3)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.clear_erase_regions(editor, -1) end
    end
  end

  describe "erased regions and the page operations" do
    test "a region follows its page through a move" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.erase_region!(0, @erase_rect) |> Editor.move_page!(0, 2)

      assert [{"Page Two", []}, {"Page Three", []}, {"Page One", [_]}] = saved_whiteouts(editor)
    end

    test "erasing after a deletion paints the page that survived" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.delete_page!(0) |> Editor.erase_region!(0, @erase_rect)

      assert [{"Page Two", [_]}, {"Page Three", []}] = saved_whiteouts(editor)
    end
  end

  describe "erased regions and flattening" do
    test "covers a flattened annotation once the flattened document is reopened" do
      flattened = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(flattened) end)

      bytes = flattened |> Editor.flatten_annotations!() |> Editor.to_binary!()

      editor = Editor.from_binary!(bytes)
      on_exit(fn -> Editor.close(editor) end)

      Editor.erase_region!(editor, 0, %Rect{x: 0.0, y: 0.0, width: 612.0, height: 792.0})

      assert editor |> Editor.to_binary!(compress: false) |> PdfElixide.ContentOrder.page0() ==
               [:original, :flattened, :whiteout]
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

  defp attached(editor) do
    doc = Document.from_binary!(Editor.to_binary!(editor))
    files = Document.embedded_files!(doc)
    Document.close(doc)

    files
  end

  describe "embed_file/4" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      refute Editor.modified?(editor)

      assert {:ok, ^editor} = Editor.embed_file(editor, "data.csv", "a,b\n")
      assert Editor.modified?(editor)
    end

    test "writes the file into the saved document" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "data.csv", "a,b\n1,2\n",
        description: "Chart data",
        relationship: :data
      )

      assert [file] = attached(editor)
      assert file.name == "data.csv"
      assert file.data == "a,b\n1,2\n"
      assert file.description == "Chart data"
      assert file.relationship == :data
      assert file.size == 8
    end

    test "carries the file into every write, not only the first" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "data.csv", "a,b\n")

      assert [%{name: "data.csv"}] = attached(editor)
      assert [%{name: "data.csv"}] = attached(editor)
    end

    test "a refused incremental write leaves the modified flag alone" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "data.csv", "a,b\n")
      Editor.to_binary!(editor)
      refute Editor.modified?(editor)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.to_binary(editor, incremental: true)
      refute Editor.modified?(editor)
    end

    @tag :tmp_dir
    test "survives a save to a file, garbage collection included", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(tmp_dir, "attached.pdf")

      editor
      |> Editor.embed_file!("notes.txt", "kept")
      |> Editor.save!(path, garbage_collect: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert [%{name: "notes.txt", data: "kept"}] = Document.embedded_files!(doc)
    end

    test "round-trips a name outside ASCII" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "résumé.txt", "body")

      assert [%{name: "résumé.txt"}] = attached(editor)
    end

    test "attaches several files in one session" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor
      |> Editor.embed_file!("a.txt", "first")
      |> Editor.embed_file!("b.txt", "second")

      assert [%{name: "a.txt", data: "first"}, %{name: "b.txt", data: "second"}] =
               attached(editor)
    end

    test "refuses a document that already has a name tree" do
      editor = Editor.open!(@attachments_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported} = error} =
               Editor.embed_file(editor, "added.txt", "added")

      assert error.message =~ "EmbeddedFiles"
      refute Editor.modified?(editor)
    end

    test "raises for a name that is empty or not a string" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.embed_file(editor, "", "x") end
      assert_raise FunctionClauseError, fn -> Editor.embed_file(editor, :name, "x") end
      assert_raise ArgumentError, fn -> Editor.embed_file(editor, <<0xFF>>, "x") end
    end

    test "raises for an invalid option value" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/:relationship/, fn ->
        Editor.embed_file(editor, "a.txt", "x", relationship: :attachment)
      end

      assert_raise ArgumentError, ~r/:description/, fn ->
        Editor.embed_file(editor, "a.txt", "x", description: 1)
      end
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@valid_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.embed_file(editor, "a.txt", "x")
    end
  end

  describe "embedded_files/1" do
    test "reports an attachment before it is written" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, []} = Editor.embedded_files(editor)

      Editor.embed_file!(editor, "pending.txt", "body", description: "Note", relationship: :data)

      assert [
               %EmbeddedFile{
                 name: "pending.txt",
                 data: "body",
                 description: "Note",
                 relationship: :data,
                 size: nil,
                 checksum: nil,
                 created: nil,
                 modified: nil
               }
             ] = Editor.embedded_files!(editor)

      Editor.to_binary!(editor)

      assert [%EmbeddedFile{size: nil, checksum: nil, created: nil, modified: nil}] =
               Editor.embedded_files!(editor)
    end

    test "reports a pending attachment where a write will place it" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor
      |> Editor.embed_file!("z.txt", "last")
      |> Editor.embed_file!("a.txt", "first")

      assert ["a.txt", "z.txt"] = editor |> Editor.embedded_files!() |> Enum.map(& &1.name)
      assert ["a.txt", "z.txt"] = editor |> attached() |> Enum.map(& &1.name)
    end

    test "reports what the edited document already carried" do
      editor = Editor.open!(@attachments_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert ["data.csv", "notes.txt", "résumé.txt"] =
               editor |> Editor.embedded_files!() |> Enum.map(& &1.name)
    end

    test "refuses a name tree whose /Kids loops back" do
      editor = Editor.open!(@attachments_cyclic_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.embedded_files(editor)
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@attachments_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.embedded_files(editor)
    end
  end
end
