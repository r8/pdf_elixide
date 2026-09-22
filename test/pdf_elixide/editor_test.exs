defmodule PdfElixide.EditorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import PdfElixide.Untyped

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
  @redact_pdf Path.join(@fixtures, "redact.pdf")
  @redact_indirect_pdf Path.join(@fixtures, "redact_indirect_contents.pdf")
  @redact_unreadable_contents_pdf Path.join(@fixtures, "redact_unreadable_contents.pdf")
  @redact_unreadable_annotated_pdf Path.join(@fixtures, "redact_unreadable_annotated.pdf")
  @redact_unknown_font_pdf Path.join(@fixtures, "redact_unknown_font.pdf")
  @sanitize_pdf Path.join(@fixtures, "sanitize.pdf")
  @redact_partial_pdf Path.join(@fixtures, "redact_partial.pdf")
  @redact_actualtext_pdf Path.join(@fixtures, "redact_actualtext.pdf")
  @sanitize_indirect_info_pdf Path.join(@fixtures, "sanitize_indirect_info.pdf")
  @sanitize_objstm_pdf Path.join(@fixtures, "sanitize_objstm.pdf")
  @redact_qq_text_state_pdf Path.join(@fixtures, "redact_qq_text_state.pdf")
  @metadata_encodings_pdf Path.join(@fixtures, "metadata_encodings.pdf")
  @encrypted_pdf Path.join(@fixtures, "encrypted.pdf")
  # Its page count is unreadable until the password is applied.
  @encrypted_objstm_pdf Path.join(@fixtures, "encrypted_objstm.pdf")
  # Encrypted, but with its XMP left unencrypted — the one shape a rewrite
  # cannot carry. Its `dc:title` is "Test Title".
  @encrypted_cleartext_metadata_pdf Path.join(@fixtures, "encrypted_cleartext_metadata.pdf")
  # The same shape, with the flag written as a reference rather than inline.
  @encrypted_indirect_metadata_flag_pdf Path.join(
                                          @fixtures,
                                          "encrypted_indirect_metadata_flag.pdf"
                                        )
  # The same shape again, with the catalog entry written as `null`.
  @encrypted_null_metadata_pdf Path.join(@fixtures, "encrypted_null_metadata.pdf")
  # The one encrypted fixture carrying a form field and appearance streams.
  @encrypted_flatten_pdf Path.join(@fixtures, "encrypted_flatten.pdf")
  # AES-128 revision 4, and a user password with no UTF-8 spelling.
  @encrypted_latin1_pdf Path.join(@fixtures, "encrypted_latin1.pdf")
  @media_box_pdf Path.join(@fixtures, "media_box.pdf")
  @crop_box_pdf Path.join(@fixtures, "crop_box.pdf")

  describe "open/1" do
    test "returns {:ok, %Editor{}} for a valid PDF file" do
      assert {:ok, %Editor{ref: ref, source_path: path}} = Editor.open(@valid_pdf)
      assert is_reference(ref)
      assert path == @valid_pdf
    end

    test "returns {:error, reason} for a file that is not a valid PDF" do
      assert {:error, %Error{reason: :invalid_pdf}} = Editor.open(@invalid_pdf)
    end

    test "an encrypted document without its password names the option" do
      assert {:error, %Error{reason: :encrypted, message: message}} =
               Editor.open(@encrypted_pdf)

      assert message =~ ":password"
    end
  end

  describe "open!/1" do
    test "returns an Editor struct for a valid PDF file" do
      assert %Editor{} = Editor.open!(@valid_pdf)
    end

    test "raises for a file that is not a valid PDF" do
      assert_raise Error, fn -> Editor.open!(@invalid_pdf) end
    end

    test "raises for an encrypted document opened without its password" do
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

    test "refuses encrypted bytes without a password" do
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
      assert {:ok, doc} = Document.from_binary(encrypted, password: "secret")
      assert Document.metadata!(doc).title == "Test Title"
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

  describe ":password on the editor" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "pdf_elixide_src_#{System.unique_integer([:positive])}.pdf")

      on_exit(fn -> File.rm(path) end)
      {:ok, out_path: path}
    end

    for {name, fixture, password} <- [
          {:readable_count, @encrypted_pdf, "secret"},
          {:object_streams, @encrypted_objstm_pdf, "secret"},
          {:aes128_latin1, @encrypted_latin1_pdf, "caf" <> <<0xE9>>}
        ] do
      @fixture fixture
      @password password

      test "#{name}: the password opens the source and its content survives a rewrite" do
        editor = Editor.open!(@fixture, password: @password)
        bytes = Editor.to_binary!(editor)
        doc = Document.from_binary!(bytes)

        refute Document.encrypted?(doc)

        assert Enum.map(0..2, &String.trim(Document.text!(doc, &1))) ==
                 ["Page One", "Page Two", "Page Three"]
      end

      test "#{name}: a wrong password is refused" do
        assert {:error, %Error{reason: :wrong_password}} =
                 Editor.open(@fixture, password: "wrong")
      end

      test "#{name}: from_binary/2 takes the password too" do
        editor = Editor.from_binary!(File.read!(@fixture), password: @password)

        assert String.trim(Document.text!(Document.from_binary!(Editor.to_binary!(editor)), 0)) ==
                 "Page One"
      end

      test "#{name}: re-keying carries the content to the new password", %{out_path: out_path} do
        @fixture
        |> Editor.open!(password: @password)
        |> Editor.save!(out_path, encryption: [user_password: "second"])

        assert {:error, %Error{reason: :wrong_password}} =
                 Document.open(out_path, password: @password)

        doc = Document.open!(out_path, password: "second")
        assert String.trim(Document.text!(doc, 0)) == "Page One"
      end

      test "#{name}: an incremental save is refused however the editor was built",
           %{out_path: out_path} do
        for editor <- [
              Editor.open!(@fixture, password: @password),
              Editor.from_binary!(File.read!(@fixture), password: @password)
            ] do
          assert {:error, %Error{reason: :unsupported, message: message}} =
                   Editor.save(editor, out_path, incremental: true)

          assert message =~ "encrypted"
          refute File.exists?(out_path)
        end
      end

      test "#{name}: a pending edit does not change which reason the refusal gives",
           %{out_path: out_path} do
        editor = Editor.open!(@fixture, password: @password)
        assert {:ok, ^editor} = Editor.delete_page(editor, 0)

        assert {:error, %Error{reason: :unsupported, message: message}} =
                 Editor.save(editor, out_path, incremental: true)

        assert message =~ "encrypted"
        refute message =~ "page deletions"
      end

      test "#{name}: the operations that read a source stream are refused" do
        editor = Editor.open!(@fixture, password: @password)

        rect = %Rect{x: 65.0, y: 690.0, width: 185.0, height: 35.0}

        for call <- [
              fn -> Editor.add_redaction(editor, 0, rect) end,
              fn -> Editor.apply_redactions(editor) end,
              fn -> Editor.flatten_annotations(editor) end,
              fn -> Editor.flatten_annotations(editor, 0) end,
              fn -> Form.flatten(editor) end,
              fn -> Form.flatten(editor, 0) end
            ] do
          assert {:error, %Error{reason: :unsupported, message: message}} = call.()
          assert message =~ "encrypted"
        end
      end

      test "#{name}: a refused pass leaves the editor usable" do
        editor = Editor.open!(@fixture, password: @password)

        assert {:error, %Error{reason: :unsupported}} = Editor.apply_redactions(editor)

        doc = editor |> Editor.to_binary!() |> Document.from_binary!()
        assert String.trim(Document.text!(doc, 0)) == "Page One"
      end

      test "#{name}: marking, metadata and page structure still work" do
        editor = Editor.open!(@fixture, password: @password)

        assert {:ok, ^editor} = Editor.mark_redactions(editor)
        assert {:ok, ^editor} = Editor.set_title(editor, "Still Editable")
        assert {:ok, ^editor} = Editor.rotate_page_by(editor, 0, 90)
        assert Editor.metadata!(editor).title == "Still Editable"

        doc = editor |> Editor.to_binary!() |> Document.from_binary!()
        assert Document.metadata!(doc).title == "Still Editable"
      end
    end

    test "an edit made through the password reaches the output", %{out_path: out_path} do
      @encrypted_pdf
      |> Editor.open!(password: "secret")
      |> Editor.set_title!("Decrypted Title")
      |> Editor.save!(out_path)

      doc = Document.open!(out_path)
      assert Document.metadata!(doc).title == "Decrypted Title"
      assert String.trim(Document.text!(doc, 0)) == "Page One"
    end

    test "an unencrypted path-opened editor still saves incrementally", %{out_path: out_path} do
      plain = Editor.open!(@valid_pdf)

      assert Editor.source_path(plain) == @valid_pdf
      assert {:ok, ^plain} = Editor.save(plain, out_path, incremental: true)
    end

    test "a rewrite that would drop unencrypted metadata is refused", %{out_path: out_path} do
      editor = Editor.open!(@encrypted_cleartext_metadata_pdf, password: "secret")

      doc = Document.open!(@encrypted_cleartext_metadata_pdf, password: "secret")
      assert {:ok, %{title: "Test Title"}} = Document.xmp_metadata(doc)
      :ok = Document.close(doc)

      assert {:error, %Error{reason: :unsupported, message: message}} = Editor.to_binary(editor)
      assert message =~ "metadata"

      assert {:error, %Error{reason: :unsupported}} = Editor.save(editor, out_path)
      refute File.exists?(out_path)
    end

    # The rewrite refusal must not pre-empt this one: an incremental update
    # appends, so the metadata is not at risk and sanitizing would not help.
    test "an incremental save of the same source is refused for being encrypted",
         %{out_path: out_path} do
      editor = Editor.open!(@encrypted_cleartext_metadata_pdf, password: "secret")

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, out_path, incremental: true)

      assert message =~ "cannot be saved incrementally"
      refute message =~ "metadata"
      refute File.exists?(out_path)
    end

    test "the refusal survives an indirect /EncryptMetadata" do
      editor = Editor.open!(@encrypted_indirect_metadata_flag_pdf, password: "secret")

      assert {:error, %Error{reason: :unsupported, message: message}} = Editor.to_binary(editor)
      assert message =~ "metadata"
    end

    test "a null /Metadata entry is not metadata to preserve" do
      editor = Editor.open!(@encrypted_null_metadata_pdf, password: "secret")

      assert {:ok, bytes} = Editor.to_binary(editor)
      out = Document.from_binary!(bytes)
      assert Document.page_count!(out) == 3

      # Upstream's reader is null-blind too, so both sides answer alike rather
      # than `{:ok, nil}`; the equality is what survives that being fixed.
      src = Document.open!(@encrypted_null_metadata_pdf, password: "secret")
      assert Document.xmp_metadata(out) == Document.xmp_metadata(src)
      assert Document.metadata!(src).title == "Test Title"
      assert Document.metadata!(out).title == "Test Title"
      :ok = Document.close(src)
    end

    test "scrubbing the metadata first lets the rewrite through" do
      editor = Editor.open!(@encrypted_cleartext_metadata_pdf, password: "secret")

      assert {:ok, %PdfElixide.SanitizeReport{}} = Editor.sanitize(editor, scrub_metadata: true)

      doc = editor |> Editor.to_binary!() |> Document.from_binary!()
      assert {:ok, nil} = Document.xmp_metadata(doc)
      assert Document.page_count!(doc) == 3
    end

    test "an encrypted document whose metadata is encrypted too still rewrites" do
      editor = Editor.open!(@encrypted_pdf, password: "secret")

      assert {:ok, bytes} = Editor.to_binary(editor)
      refute Document.encrypted?(Document.from_binary!(bytes))
    end

    test "a string written before the document was encrypted reads back decrypted" do
      editor = Editor.open!(@encrypted_flatten_pdf, password: "secret")

      assert Form.value!(editor, "full_name") == "John Doe"
      assert [%Form.Field.Text{name: "full_name"}] = Form.fields!(editor)
    end

    test "an unknown option raises, naming the key" do
      assert_raise ArgumentError, ~r/:passwrod/, fn ->
        Editor.open(@valid_pdf, passwrod: "secret")
      end
    end

    test "password: nil is a no-op on an unencrypted document" do
      assert {:ok, %Editor{}} = Editor.open(@valid_pdf, password: nil)
    end

    test "a password on an unencrypted document is inert" do
      editor = Editor.open!(@valid_pdf, password: "ignored")

      assert Editor.source_path(editor) == @valid_pdf
      assert Editor.page_count!(editor) == 3
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

    test "raises for a delta that is not a multiple of 90" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by(editor, 0, 45) end
      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by(editor, 0, 134) end
      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by!(editor, 0, -45) end
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
      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by(editor, 0, untyped(90.0)) end
      assert_raise FunctionClauseError, fn -> Editor.rotate_page_by!(editor, 0, untyped(90.0)) end
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

    test "raises for a non-integer delta or one that is not a multiple of 90" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.rotate_all_by(editor, untyped(90.0)) end
      assert_raise FunctionClauseError, fn -> Editor.rotate_all_by(editor, 45) end
      assert_raise FunctionClauseError, fn -> Editor.rotate_all_by!(editor, 134) end
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

  @letter %Rect{x: +0.0, y: +0.0, width: 612.0, height: 792.0}
  @small_box %Rect{x: +0.0, y: +0.0, width: 100.0, height: 50.0}
  @all_sides [left: 10, right: 10, top: 10, bottom: 10]

  # A malformed crop box reports its reason so the whole document stays listable.
  defp saved_boxes(editor) do
    doc = Document.from_binary!(Editor.to_binary!(editor))
    boxes = Enum.map(doc, &{Document.Page.media_box!(&1), saved_crop(&1)})
    Document.close(doc)

    boxes
  end

  defp saved_crop(page) do
    case Document.Page.crop_box(page) do
      {:ok, rect} -> rect
      {:error, %Error{reason: reason}} -> reason
    end
  end

  defp boxes(editor) do
    for page <- 0..(Editor.page_count!(editor) - 1) do
      {Editor.media_box!(editor, page), Editor.crop_box!(editor, page)}
    end
  end

  describe "media_box/2" do
    test "answers what the read side answers for the same page" do
      editor = Editor.open!(@media_box_pdf)
      on_exit(fn -> Editor.close(editor) end)
      doc = Document.open!(@media_box_pdf)
      on_exit(fn -> Document.close(doc) end)

      for page <- 0..4 do
        assert Editor.media_box!(editor, page) ==
                 Document.Page.media_box!(Document.page!(doc, page))
      end

      assert %Rect{width: 300.0, height: 500.0} = Editor.media_box!(editor, 2)
    end

    test "reports a page with no /MediaBox above it as :invalid_pdf, not Letter" do
      editor = Editor.open!(@media_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.media_box(editor, 5)
    end

    test "reflects a pending box before any save" do
      editor = Editor.open!(@media_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 5, @small_box)

      assert Editor.media_box!(editor, 5) == @small_box
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.media_box(editor, 3)
      assert_raise Error, fn -> Editor.media_box!(editor, 3) end
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.media_box(editor, -1) end
    end
  end

  describe "crop_box/2" do
    test "answers what the read side answers for the same page" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)
      doc = Document.open!(@crop_box_pdf)
      on_exit(fn -> Document.close(doc) end)

      for page <- [0, 1, 2, 3, 4, 6, 7] do
        assert Editor.crop_box!(editor, page) ==
                 Document.Page.crop_box!(Document.page!(doc, page))
      end

      assert %Rect{x: 50.0, y: 50.0, width: 250.0, height: 350.0} = Editor.crop_box!(editor, 1)
      assert Editor.crop_box!(editor, 2) == %Rect{x: 0.0, y: 0.0, width: 100.0, height: 100.0}
      assert Editor.crop_box!(editor, 4) == nil
      assert Editor.crop_box!(editor, 7) == nil
    end

    test "reports a malformed /CropBox as :invalid_pdf" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.crop_box(editor, 5)
    end

    test "reflects a pending box before any save" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_crop_box!(editor, 4, @small_box)

      assert Editor.crop_box!(editor, 4) == @small_box
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.crop_box(editor, 3)
    end
  end

  describe "set_media_box/3" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      refute Editor.modified?(editor)
      assert {:ok, ^editor} = Editor.set_media_box(editor, 0, @small_box)
      assert Editor.modified?(editor)
    end

    test "writes the box into the saved document" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 1, @small_box)

      assert saved_boxes(editor) == [{@letter, nil}, {@small_box, nil}, {@letter, nil}]
    end

    test "gives a page with no /MediaBox one that reads back after a save" do
      editor = Editor.open!(@media_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 5, @small_box)

      assert saved_boxes(editor) |> Enum.at(5) == {@small_box, nil}
    end

    test "normalizes reversed corners and reports the box as it will be written" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 0, %Rect{x: 100.0, y: 50.0, width: -100.0, height: -50.0})

      assert Editor.media_box!(editor, 0) == @small_box
      assert saved_boxes(editor) |> hd() == {@small_box, nil}
    end

    test "leaves an existing /CropBox alone" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 0, @small_box)

      crop = %Rect{x: 10.0, y: 20.0, width: 200.0, height: 300.0}
      assert Editor.crop_box!(editor, 0) == crop
      assert saved_boxes(editor) |> hd() == {@small_box, crop}
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.set_media_box(editor, 3, @small_box)
      refute Editor.modified?(editor)
    end

    test "raises for a box whose corner overflows a 32-bit float" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/32-bit float/, fn ->
        Editor.set_media_box(editor, 0, %Rect{x: 2.0e38, y: 0.0, width: 2.0e38, height: 10.0})
      end

      refute Editor.modified?(editor)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.set_media_box(editor, -1, @small_box) end
    end
  end

  describe "set_crop_box/3" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.set_crop_box(editor, 0, @small_box)
      assert Editor.modified?(editor)
    end

    test "writes the box into the saved document without touching the media box" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_crop_box!(editor, 2, @small_box)

      assert saved_boxes(editor) == [{@letter, nil}, {@letter, nil}, {@letter, @small_box}]
    end

    test "replaces an inherited crop box on the page alone" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_crop_box!(editor, 1, @small_box)

      assert Editor.crop_box!(editor, 1) == @small_box
      assert saved_boxes(editor) |> Enum.at(1) == {@letter, @small_box}
    end

    test "is not checked against the media box" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      outside = %Rect{x: 1000.0, y: 1000.0, width: 10.0, height: 10.0}
      Editor.set_crop_box!(editor, 0, outside)

      assert saved_boxes(editor) |> hd() == {@letter, outside}
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.set_crop_box(editor, 3, @small_box)
    end

    test "raises for a box whose corner overflows a 32-bit float" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/32-bit float/, fn ->
        Editor.set_crop_box(editor, 0, %Rect{x: 0.0, y: -2.0e38, width: 10.0, height: -2.0e38})
      end
    end
  end

  describe "crop_margins/2" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.crop_margins(editor, @all_sides)
      assert Editor.modified?(editor)
    end

    test "insets every page's media box, inherited and reversed ones included" do
      editor = Editor.open!(@media_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor
      |> Editor.set_media_box!(5, %Rect{x: 0.0, y: 0.0, width: 200.0, height: 100.0})
      |> Editor.crop_margins!(left: 10, right: 20, top: 30, bottom: 40)

      assert Enum.map(saved_boxes(editor), &elem(&1, 1)) == [
               %Rect{x: 20.0, y: 60.0, width: 582.0, height: 722.0},
               %Rect{x: 10.0, y: 40.0, width: 582.0, height: 722.0},
               %Rect{x: 10.0, y: 40.0, width: 270.0, height: 430.0},
               %Rect{x: 10.0, y: 40.0, width: 270.0, height: 330.0},
               %Rect{x: 10.0, y: 40.0, width: 270.0, height: 330.0},
               %Rect{x: 10.0, y: 40.0, width: 170.0, height: 30.0}
             ]
    end

    test "defaults an omitted side to zero" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.crop_margins!(editor, left: 100)

      assert Editor.crop_box!(editor, 0) == %Rect{x: 100.0, y: 0.0, width: 512.0, height: 792.0}
      assert Editor.crop_box!(Editor.crop_margins!(editor, []), 0) == @letter
    end

    test "replaces the crop box a page already has" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.crop_margins!(editor, @all_sides)

      inset = %Rect{x: 10.0, y: 10.0, width: 592.0, height: 772.0}
      assert Enum.map(boxes(editor), &elem(&1, 1)) == List.duplicate(inset, 8)
    end

    test "changes nothing on a document with no pages" do
      editor = Editor.open!(@no_pages_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.crop_margins(editor, @all_sides)
      refute Editor.modified?(editor)
    end

    test "crops no page at all when one page's media box cannot be read" do
      editor = Editor.open!(@broken_page_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.crop_margins(editor, @all_sides)
      assert Editor.crop_box!(editor, 0) == nil
      refute Editor.modified?(editor)
    end

    test "crops no page at all when the margins leave one page with no area" do
      editor = Editor.open!(@media_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 5, @small_box)
      Editor.to_binary!(editor)
      refute Editor.modified?(editor)

      assert {:error, %Error{reason: :other, message: message}} =
               Editor.crop_margins(editor, left: 50, right: 50)

      assert message =~ "page 5"
      assert Editor.crop_box!(editor, 0) == nil
      refute Editor.modified?(editor)
    end

    test "raises for an unknown key, a negative margin, an oversized one or a non-number" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/:lef/, fn -> Editor.crop_margins(editor, lef: 1) end
      assert_raise ArgumentError, ~r/:top/, fn -> Editor.crop_margins(editor, top: -1) end
      assert_raise ArgumentError, ~r/:right/, fn -> Editor.crop_margins(editor, right: 1.0e39) end
      assert_raise ArgumentError, ~r/:bottom/, fn -> Editor.crop_margins(editor, bottom: "1") end
      refute Editor.modified?(editor)
    end
  end

  describe "page boxes and the page operations" do
    test "a crop box follows its page through a move" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 0, 6)

      leaf = %Rect{x: 10.0, y: 20.0, width: 200.0, height: 300.0}
      assert Editor.crop_box!(editor, 6) == leaf
      assert saved_boxes(editor) |> Enum.at(6) == {@letter, leaf}
    end

    test "a box set before a move travels with the page" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.set_media_box!(0, @small_box) |> Editor.move_page!(0, 2)

      assert Editor.media_box!(editor, 2) == @small_box
      assert saved_boxes(editor) == [{@letter, nil}, {@letter, nil}, {@small_box, nil}]
    end

    test "deleting a page does not shift the boxes of the survivors" do
      editor = Editor.open!(@crop_box_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 0)

      inherited = %Rect{x: 50.0, y: 50.0, width: 250.0, height: 350.0}
      assert Editor.crop_box!(editor, 0) == inherited
      assert Editor.crop_box!(editor, 3) == nil
      assert saved_boxes(editor) |> hd() == {@letter, inherited}
    end

    test "setting a box after a deletion changes the page that survived" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.delete_page!(0) |> Editor.set_crop_box!(0, @small_box)

      assert saved_boxes(editor) == [{@letter, @small_box}, {@letter, nil}]
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
        Editor.erase_regions(editor, 0, untyped([]))
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

  @redact_rect %Rect{x: 95.0, y: 695.0, width: 105.0, height: 30.0}
  @quad_rect %Rect{x: 300.0, y: 400.0, width: 100.0, height: 100.0}
  @red %PdfElixide.Color.RGB{r: 1.0, g: 0.0, b: 0.0}
  @black %PdfElixide.Color.RGB{r: 0.0, g: 0.0, b: 0.0}

  defp written(editor), do: Document.from_binary!(Editor.to_binary!(editor))

  defp page_text(editor, index) do
    doc = written(editor)
    text = doc |> Document.text!(index) |> String.trim()
    Document.close(doc)
    text
  end

  describe "mark_redactions/2" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      refute Editor.modified?(editor)
      assert {:ok, ^editor} = Editor.mark_redactions(editor, 0)
      assert Editor.modified?(editor)
    end

    test "paints each redaction annotation in its own interior color" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)

      doc = written(editor)
      rects = doc |> Document.rects!(0) |> Enum.map(&{&1.bbox, &1.fill_color})
      Document.close(doc)

      # The second annotation declares no /IC, so it falls back to black.
      assert rects == [{@redact_rect, @red}, {@quad_rect, @black}]
    end

    test "leaves the covered text extractable" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)

      assert page_text(editor, 0) == "Secret\n\n\nKept"
    end

    test "removes every annotation from the page, not only the redactions" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      doc = Document.open!(@redact_pdf)

      assert doc |> Document.annotations!(0) |> Enum.map(& &1.subtype) == [
               :redact,
               :redact,
               :link
             ]

      Document.close(doc)

      Editor.mark_redactions!(editor, 0)

      written = written(editor)
      assert Document.annotations!(written, 0) == []
      Document.close(written)
    end

    test "leaves an unmarked page alone" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)

      doc = written(editor)
      assert Document.rects!(doc, 1) == []
      Document.close(doc)
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.mark_redactions(editor, 2)
    end

    test "raises for a negative page index" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.mark_redactions(editor, -1) end
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@redact_pdf)
      Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.mark_redactions(editor, 0)
    end

    test "returns {:error, :unsupported} for an indirect content array it would splice" do
      editor = Editor.open!(@redact_indirect_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # The control: the page must still read, or the refusal proves nothing.
      plain = Document.open!(@redact_indirect_pdf)
      assert Document.text!(plain, 0) =~ "Indirect"
      Document.close(plain)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.mark_redactions(editor, 0)

      assert message =~ "indirect array"
      refute Editor.modified?(editor)
    end

    test "allows an indirect content array on a page with no redaction annotations" do
      editor = Editor.open!(@indirect_contents_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.mark_redactions(editor, 0)
    end

    # The annotation is what puts the page in the destructive set with a region
    # to apply, so the mark refuses every indirect /Contents the pass cannot
    # decode, not only the array the cosmetic splice would nest.
    test "returns {:error, :unsupported} for an indirect /Contents that is not a stream" do
      editor = Editor.open!(@redact_unreadable_annotated_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.mark_redactions(editor, 0)

      assert message =~ "not a content stream"
      refute Editor.modified?(editor)

      # The refusal is the only thing standing between the mark and a pass that
      # errors with both refusal flags already armed.
      assert {:ok, %PdfElixide.RedactionReport{regions: 0}} = Editor.apply_redactions(editor)
    end

    # A page carrying no redaction annotation produces no overlay and contributes
    # no region, so the mark stays harmless whatever its /Contents — the guard
    # must not become blanket.
    test "allows an indirect /Contents that is not a stream with no annotations" do
      editor = Editor.open!(@redact_unreadable_contents_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.mark_redactions(editor, 0)
      assert {:ok, %PdfElixide.RedactionReport{regions: 0}} = Editor.apply_redactions(editor)
    end
  end

  describe "mark_redactions/1" do
    test "marks every page" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.mark_redactions(editor)

      assert Editor.marked_for_redaction?(editor, 0)
      assert Editor.marked_for_redaction?(editor, 1)
    end

    test "marks the page that survived a deletion" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # Upstream's bulk call marks raw output indices, so without the binding's
      # per-page loop the surviving source page is left unmarked.
      editor |> Editor.delete_page!(0) |> Editor.mark_redactions!()

      assert Editor.marked_for_redaction?(editor, 0)
    end

    test "refuses every page when one would splice an indirect content array" do
      editor = Editor.open!(@redact_indirect_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported}} = Editor.mark_redactions(editor)
      refute Editor.modified?(editor)
    end
  end

  describe "unmark_redactions/2" do
    test "leaves the next write painting nothing" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.mark_redactions!(0) |> Editor.unmark_redactions!(0)

      doc = written(editor)
      assert Document.rects!(doc, 0) == []
      Document.close(doc)
    end

    test "leaves modified?/1 as it was" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.unmark_redactions(editor, 0)
      refute Editor.modified?(editor)
    end

    test "does not withdraw a region added with add_redaction/3" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor
      |> Editor.add_redaction!(1, %Rect{x: 95.0, y: 695.0, width: 155.0, height: 30.0})
      |> Editor.unmark_redactions!(1)

      assert %{glyphs_removed: removed} = Editor.apply_redactions!(editor)
      assert removed > 0
      assert page_text(editor, 1) == ""
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.unmark_redactions(editor, 2)
    end
  end

  describe "marked_for_redaction?/2" do
    test "answers before and after a mark" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      refute Editor.marked_for_redaction?(editor, 0)
      Editor.mark_redactions!(editor, 0)
      assert Editor.marked_for_redaction?(editor, 0)
      refute Editor.marked_for_redaction?(editor, 1)
    end

    test "raises :out_of_range for a page past the end" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise Error, fn -> Editor.marked_for_redaction?(editor, 2) end
    end
  end

  describe "redaction_count/2" do
    test "counts one region per redaction annotation, quadrilaterals included" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # The second annotation declares two /QuadPoints quads and still counts
      # once; see the drift test for why.
      assert Editor.redaction_count!(editor, 0) == 2
      assert Editor.redaction_count!(editor, 1) == 0
    end

    test "rises with each queued region" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.add_redaction!(editor, 1, @redact_rect)

      assert Editor.redaction_count!(editor, 1) == 1
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} = Editor.redaction_count(editor, 2)
    end
  end

  describe "add_redaction/3,4" do
    test "returns the same editor and marks it modified" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.add_redaction(editor, 1, @redact_rect)
      assert Editor.modified?(editor)
    end

    test "changes nothing without a destructive apply" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.add_redaction!(editor, 1, @redact_rect, @red)

      doc = written(editor)
      assert Document.rects!(doc, 1) == []
      assert String.trim(Document.text!(doc, 1)) == "Second"
      Document.close(doc)
    end

    test "normalizes reversed corners" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      reversed = %Rect{x: 250.0, y: 725.0, width: -155.0, height: -30.0}
      Editor.add_redaction!(editor, 1, reversed)

      assert %{glyphs_removed: removed} = Editor.apply_redactions!(editor)
      assert removed > 0
    end

    test "raises for a region whose corner overflows a 32-bit float" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      overflowing = %Rect{x: 2.0e38, y: 0.0, width: 2.0e38, height: 10.0}

      assert_raise ArgumentError, ~r/32-bit float/, fn ->
        Editor.add_redaction(editor, 1, overflowing)
      end

      refute Editor.modified?(editor)
    end

    test "raises for a wrong-typed rectangle field, naming it" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/Could not decode field :x/, fn ->
        Editor.add_redaction(editor, 1, %Rect{x: "95", y: 695.0, width: 10.0, height: 10.0})
      end
    end

    test "raises for a fill that is not an RGB color" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn ->
        Editor.add_redaction(editor, 1, @redact_rect, untyped({1.0, 0.0, 0.0}))
      end
    end

    test "returns {:error, :out_of_range} for a page past the end" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :out_of_range}} =
               Editor.add_redaction(editor, 2, @redact_rect)
    end

    test "marks the page, so a write paints its own redaction annotations" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # Page 0 carries `/Redact` annotations; page 1, used above, carries none,
      # which is why that test sees a write change nothing.
      Editor.add_redaction!(editor, 0, @quad_rect, @red)

      assert Editor.marked_for_redaction?(editor, 0)

      doc = written(editor)
      # The page's own annotation rectangles, not the queued one.
      assert doc |> Document.rects!(0) |> Enum.map(& &1.bbox) == [@redact_rect, @quad_rect]
      assert Document.annotations!(doc, 0) == []
      Document.close(doc)
    end

    test "returns {:error, :unsupported} for an indirect content array it would splice" do
      editor = Editor.open!(@redact_indirect_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.add_redaction(editor, 0, @redact_rect)

      assert message =~ "indirect array"
      refute Editor.modified?(editor)
    end

    # Stricter than the mark, which `mark_redactions/2` still allows on this
    # fixture, because a region cannot be withdrawn once added.
    test "returns {:error, :unsupported} for an indirect content array with no annotations" do
      editor = Editor.open!(@indirect_contents_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.add_redaction(editor, 0, @redact_rect)

      assert message =~ "indirect array"
      refute Editor.modified?(editor)
    end

    # An array is not the only /Contents the pass cannot decode: the entry is
    # matched unresolved, so every indirect non-stream object fails.
    test "returns {:error, :unsupported} for an indirect /Contents that is not a stream" do
      editor = Editor.open!(@redact_unreadable_contents_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.add_redaction(editor, 0, @redact_rect)

      assert message =~ "not a content stream"
      refute Editor.modified?(editor)
    end

    test "raises for a fill component outside 0.0..1.0" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/fill/, fn ->
        Editor.add_redaction(editor, 1, @redact_rect, %PdfElixide.Color.RGB{
          r: 2.0,
          g: 0.0,
          b: 0.0
        })
      end

      refute Editor.modified?(editor)
      assert {:ok, ^editor} = Editor.add_redaction(editor, 1, @redact_rect, @red)
    end
  end

  describe "apply_redactions/1,2" do
    test "removes the covered text from the written bytes and keeps the rest" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)

      assert %PdfElixide.RedactionReport{
               regions: 2,
               glyphs_removed: removed,
               bytes_removed: bytes
             } =
               Editor.apply_redactions!(editor)

      assert removed > 0
      assert bytes > 0

      written = Editor.to_binary!(editor)
      assert :binary.match(written, "Secret") == :nomatch
      assert :binary.match(written, "Kept") != :nomatch

      doc = Document.from_binary!(written)
      assert String.trim(Document.text!(doc, 0)) == "Kept"
      Document.close(doc)
    end

    # Page 0 carries a `/Link` beside its two `/Redact` annotations, so the wipe
    # is visible as more than the redactions disappearing.
    test "removes every annotation from a page it redacted" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      Editor.apply_redactions!(editor)

      doc = written(editor)
      assert Document.annotations!(doc, 0) == []
      Document.close(doc)
    end

    test "does nothing when no page is marked or queued" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # A /Redact annotation is not a mark: without one of the two the pass has
      # an empty page set and the report is all zeros.
      assert Editor.apply_redactions!(editor) == %PdfElixide.RedactionReport{
               regions: 0,
               glyphs_removed: 0,
               bytes_removed: 0
             }

      assert page_text(editor, 0) == "Secret\n\n\nKept"
    end

    test "leaves the cleared area blank with draw_default_overlay: false" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.add_redaction!(editor, 1, @redact_rect)
      Editor.apply_redactions!(editor, draw_default_overlay: false)

      doc = written(editor)
      assert Document.rects!(doc, 1) == []
      Document.close(doc)
    end

    test "draws :default_fill over a region that declares no colour" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.add_redaction!(editor, 1, @redact_rect)
      Editor.apply_redactions!(editor, default_fill: @red)

      doc = written(editor)
      assert doc |> Document.rects!(1) |> Enum.map(& &1.fill_color) == [@red]
      Document.close(doc)
    end

    test "returns {:error, :unsupported} for a font whose glyphs cannot be measured" do
      editor = Editor.open!(@redact_unknown_font_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)

      # The message is upstream's and says "composite" for an undefined font
      # too, so it is not what this pins.
      assert {:error, %Error{reason: :unsupported}} = Editor.apply_redactions(editor)
      assert page_text(editor, 0) == "Unknown"
    end

    test "raises for a negative :edge_padding" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/:edge_padding/, fn ->
        Editor.apply_redactions(editor, edge_padding: -1.0)
      end
    end

    test "raises for a :default_fill component outside 0.0..1.0" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, ~r/:default_fill/, fn ->
        Editor.apply_redactions(editor,
          default_fill: %PdfElixide.Color.RGB{r: 2.0, g: 0.0, b: 0.0}
        )
      end
    end

    test "raises for an unknown option" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, fn -> Editor.apply_redactions(editor, scrub: true) end
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@redact_pdf)
      Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.apply_redactions(editor)
    end

    test "refuses a second pass rather than rebuild the pages from the source" do
      editor = Editor.open!(@redact_actualtext_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      assert %{glyphs_removed: removed} = Editor.apply_redactions!(editor, edge_padding: 150.0)
      assert removed > 0

      # The padding was wide enough to take `Kept` too. A second pass rebuilds
      # the page from the unredacted source, so a narrower one would hand it back.
      assert :binary.match(Editor.to_binary!(editor), "Kept") == :nomatch

      assert {:error, %Error{reason: :unsupported}} = Editor.apply_redactions(editor)
      assert :binary.match(Editor.to_binary!(editor), "Kept") == :nomatch
    end

    test "refuses a second pass after a sanitize, which is not itself a pass" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)
      Editor.mark_redactions!(editor, 0)

      assert %{glyphs_removed: removed} = Editor.apply_redactions!(editor)
      assert removed > 0
      assert {:error, %Error{reason: :unsupported}} = Editor.apply_redactions(editor)
    end

    test "leaves the /ActualText of the glyphs it removed in the content stream" do
      editor = Editor.open!(@redact_actualtext_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      assert %{glyphs_removed: removed} = Editor.apply_redactions!(editor)
      assert removed > 0

      written = Editor.to_binary!(editor)
      assert :binary.match(written, "Shown") == :nomatch
      assert :binary.match(written, "PRIVATE SECRET") != :nomatch
    end

    test "leaves the pages before a refused one already redacted" do
      editor = Editor.open!(@redact_partial_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor)

      assert {:error, %Error{reason: :unsupported}} = Editor.apply_redactions(editor)

      # Upstream walks source pages ascending and commits each before the next
      # one errors, so the refusal is not the all-or-nothing it reads as.
      doc = written(editor)
      assert Document.text!(doc, 0) |> String.trim() == ""
      assert Document.text!(doc, 1) |> String.trim() == "Late"
      Document.close(doc)
    end
  end

  describe "sanitize/1,2" do
    test "strips metadata, JavaScript and embedded files" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert [%EmbeddedFile{name: "note.txt"}] = Editor.embedded_files!(editor)

      assert %PdfElixide.SanitizeReport{roots_removed: roots, bytes_removed: bytes} =
               Editor.sanitize!(editor)

      assert roots > 0
      assert bytes > 0

      written = Editor.to_binary!(editor)
      assert :binary.match(written, "Sanitize me") == :nomatch
      assert :binary.match(written, "app.alert") == :nomatch
      assert :binary.match(written, "note.txt") == :nomatch

      doc = Document.from_binary!(written)
      assert %{title: nil, author: nil} = Document.metadata!(doc)
      assert Document.embedded_files!(doc) == []
      Document.close(doc)
    end

    test "reports the scrub through metadata/1" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert %{title: "Sanitize me"} = Editor.metadata!(editor)
      Editor.sanitize!(editor)
      assert %{title: nil, author: nil} = Editor.metadata!(editor)
    end

    test "keeps the /Info dictionary with scrub_metadata: false" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor, scrub_metadata: false)

      assert %{title: "Sanitize me"} = Editor.metadata!(editor)
      assert :binary.match(Editor.to_binary!(editor), "Sanitize me") != :nomatch
    end

    # `:roots_removed` counts catalog entries only, and `metadata_encodings.pdf`
    # has an /Info and none of them, so a real scrub reports zero here.
    test "reports no roots for a document whose only secret is its /Info" do
      editor = Editor.open!(@metadata_encodings_pdf)
      on_exit(fn -> Editor.close(editor) end)

      refute Editor.metadata!(editor).title == nil

      assert %PdfElixide.SanitizeReport{roots_removed: 0, bytes_removed: bytes} =
               Editor.sanitize!(editor)

      assert bytes > 0
      assert %{title: nil, author: nil} = Editor.metadata!(editor)
      assert %{title: nil} = editor |> written() |> Document.metadata!()
    end

    test "refuses a document whose /Info holds an indirect value" do
      editor = Editor.open!(@sanitize_indirect_info_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # The indirect /Title is what upstream would leave behind in its own
      # object while reporting a scrub.
      assert %{title: "INDIRECT SECRET"} = Editor.metadata!(editor)

      assert {:error, %Error{reason: :unsupported}} = Editor.sanitize(editor)

      # Nothing changed: the refusal is before the call.
      assert %{title: "INDIRECT SECRET"} = Editor.metadata!(editor)
      assert :binary.match(Editor.to_binary!(editor), "INDIRECT SECRET") != :nomatch
    end

    test "sanitizes a document with an indirect /Info when not scrubbing metadata" do
      editor = Editor.open!(@sanitize_indirect_info_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert %PdfElixide.SanitizeReport{} = Editor.sanitize!(editor, scrub_metadata: false)
      assert %{title: "INDIRECT SECRET"} = Editor.metadata!(editor)
    end

    test "removes no page content" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)

      assert page_text(editor, 0) == "Body"
    end

    # `sanitize.pdf` already has a `/Names`, and `embed_file/3` refuses to
    # rebuild one; `sample.pdf` has none, so the attachment is queueable.
    test "discards an attachment queued but not yet written" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "secret.txt", "PRIVATE ATTACHMENT")
      Editor.sanitize!(editor)

      assert Editor.embedded_files!(editor) == []

      bytes = Editor.to_binary!(editor)
      assert :binary.match(bytes, "secret.txt") == :nomatch
      assert :binary.match(bytes, "PRIVATE ATTACHMENT") == :nomatch
    end

    test "stops listing the source's attachments once they are removed" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert [%EmbeddedFile{name: "note.txt"}] = Editor.embedded_files!(editor)
      Editor.sanitize!(editor)

      assert Editor.embedded_files!(editor) == []
    end

    test "keeps listing the source's attachments with remove_embedded_files: false" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor, remove_embedded_files: false)

      assert [%EmbeddedFile{name: "note.txt"}] = Editor.embedded_files!(editor)
    end

    test "keeps a queued attachment when not asked to remove embedded files" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "secret.txt", "PRIVATE ATTACHMENT")
      Editor.sanitize!(editor, remove_embedded_files: false)

      assert [%EmbeddedFile{name: "secret.txt"}] = Editor.embedded_files!(editor)
      assert :binary.match(Editor.to_binary!(editor), "PRIVATE ATTACHMENT") != :nomatch
    end

    test "raises for an option sanitizing does not read" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise ArgumentError, fn -> Editor.sanitize(editor, edge_padding: 1.0) end
    end
  end

  describe "a pending edit and an incremental save" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, path: Path.join(tmp_dir, "incremental.pdf")}
    end

    defp refuses(editor, path) do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, path, incremental: true)

      refute File.exists?(path)
      message
    end

    @tag :tmp_dir
    test "refuses a page deletion", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)

      assert refuses(editor, path) =~ "page deletions"
    end

    @tag :tmp_dir
    test "refuses a page move", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.move_page!(editor, 0, 2)
      message = refuses(editor, path)

      assert message =~ "page moves"
      refute message =~ "page deletions"
    end

    @tag :tmp_dir
    test "allows a move that was undone", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.move_page!(0, 2) |> Editor.move_page!(2, 0)

      assert {:ok, ^editor} = Editor.save(editor, path, incremental: true)
    end

    # Deleting the last page leaves survivors' source and output indices equal.
    @tag :tmp_dir
    test "refuses the deletion of the last page, and does not call it a move", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 2)
      message = refuses(editor, path)

      assert message =~ "page deletions"
      refute message =~ "page moves"
    end

    @tag :tmp_dir
    test "refuses a page rotation", %{path: path} do
      editor = Editor.open!(@rotation_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_rotation!(editor, 0, 90)

      assert refuses(editor, path) =~ "page rotations"
    end

    @tag :tmp_dir
    test "refuses a media box", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_media_box!(editor, 0, %Rect{x: 0.0, y: 0.0, width: 100.0, height: 50.0})

      assert refuses(editor, path) =~ "page media boxes"
    end

    @tag :tmp_dir
    test "refuses a crop box", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.crop_margins!(editor, left: 36.0, right: 36.0, top: 36.0, bottom: 36.0)

      assert refuses(editor, path) =~ "page crop boxes"
    end

    @tag :tmp_dir
    test "refuses an erased region, and clearing it lifts the refusal", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.erase_region!(editor, 0, %Rect{x: 0.0, y: 0.0, width: 100.0, height: 50.0})
      assert refuses(editor, path) =~ "erased regions"

      Editor.clear_erase_regions!(editor, 0)
      assert {:ok, ^editor} = Editor.save(editor, path, incremental: true)
    end

    @tag :tmp_dir
    test "clearing one page's regions leaves another page's refusal", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      region = %Rect{x: 0.0, y: 0.0, width: 100.0, height: 50.0}
      editor |> Editor.erase_region!(0, region) |> Editor.erase_region!(1, region)

      Editor.clear_erase_regions!(editor, 1)

      assert refuses(editor, path) =~ "erased regions"
    end

    @tag :tmp_dir
    test "refuses a redaction mark, and unmarking lifts the refusal", %{path: path} do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      assert refuses(editor, path) =~ "redaction marks"

      Editor.unmark_redactions!(editor, 0)
      assert {:ok, ^editor} = Editor.save(editor, path, incremental: true)
    end

    # Page 1 has no /Redact annotation; marking it still counts.
    @tag :tmp_dir
    test "unmarking one page leaves another page's refusal", %{path: path} do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.mark_redactions!(0) |> Editor.mark_redactions!(1)
      Editor.unmark_redactions!(editor, 1)

      assert refuses(editor, path) =~ "redaction marks"
    end

    @tag :tmp_dir
    test "refuses a queued redaction region, and unmarking does not lift it", %{path: path} do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.add_redaction!(editor, 0, %Rect{x: 0.0, y: 0.0, width: 100.0, height: 50.0})

      message = refuses(editor, path)
      assert message =~ "queued redaction regions"
      assert message =~ "redaction marks"

      Editor.unmark_redactions!(editor, 0)
      message = refuses(editor, path)

      assert message =~ "queued redaction regions"
      refute message =~ "redaction marks"
    end

    @tag :tmp_dir
    test "refuses an annotation flatten mark", %{path: path} do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.flatten_annotations!(editor)

      assert refuses(editor, path) =~ "annotation flatten marks"
    end

    @tag :tmp_dir
    test "refuses a form flatten mark", %{path: path} do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.flatten!(editor)

      assert refuses(editor, path) =~ "form flatten marks"
    end

    @tag :tmp_dir
    test "refuses a per-page annotation flatten mark", %{path: path} do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.flatten_annotations!(editor, 0)

      assert refuses(editor, path) =~ "annotation flatten marks"
    end

    @tag :tmp_dir
    test "refuses a per-page form flatten mark", %{path: path} do
      editor = Editor.open!(@flatten_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.flatten!(editor, 0)

      assert refuses(editor, path) =~ "form flatten marks"
    end

    @tag :tmp_dir
    test "refuses a whole-document redaction mark", %{path: path} do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor)

      assert refuses(editor, path) =~ "redaction marks"
    end

    # With no pages to mark, only the AcroForm flag records this flatten.
    @tag :tmp_dir
    test "refuses a form flatten that marked no page", %{path: path} do
      editor = Editor.open!(@no_pages_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.flatten!(editor)

      assert refuses(editor, path) =~ "form flatten marks"
    end

    @tag :tmp_dir
    test "refuses a pending attachment", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "data.csv", "a,b\n")

      assert refuses(editor, path) =~ "attachments"
    end

    @tag :tmp_dir
    test "names every pending category at once", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor
      |> Editor.delete_page!(1)
      |> Editor.rotate_all_by!(90)
      |> Editor.embed_file!("data.csv", "a,b\n")

      message = refuses(editor, path)

      assert message =~ "page deletions"
      assert message =~ "page rotations"
      assert message =~ "attachments"
    end

    @tag :tmp_dir
    test "a full rewrite in between does not lift the refusal", %{path: path, tmp_dir: tmp_dir} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)
      Editor.save!(editor, Path.join(tmp_dir, "full.pdf"))

      assert refuses(editor, path) =~ "page deletions"
    end

    # A full rewrite drains upstream's attachment list, but not the mirror.
    @tag :tmp_dir
    test "a full rewrite does not lift it for an attachment either", %{
      path: path,
      tmp_dir: tmp_dir
    } do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.embed_file!(editor, "data.csv", "a,b\n")
      Editor.save!(editor, Path.join(tmp_dir, "full.pdf"))

      assert refuses(editor, path) =~ "attachments"
    end

    @tag :tmp_dir
    test "to_binary/2 still answers :invalid_pdf" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)

      assert {:error, %Error{reason: :invalid_pdf}} = Editor.to_binary(editor, incremental: true)
    end

    @tag :tmp_dir
    test "an untouched editor still saves incrementally", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.save(editor, path, incremental: true)
    end

    @tag :tmp_dir
    test "a form field fill still saves incrementally", %{path: path} do
      editor = Editor.open!(@form_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", "Ada")

      assert {:ok, ^editor} = Editor.save(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert %{value: "Ada"} = doc |> Form.fields!() |> Enum.find(&(&1.name == "full_name"))
    end

    @tag :tmp_dir
    test "refuses a binary-sourced editor holding nothing at all", %{path: path} do
      editor = Editor.from_binary!(File.read!(@valid_pdf))
      on_exit(fn -> Editor.close(editor) end)

      assert refuses(editor, path) =~ "built from a binary"
    end

    @tag :tmp_dir
    test "refuses a binary-sourced editor after a form fill", %{path: path} do
      editor = Editor.from_binary!(File.read!(@form_pdf))
      on_exit(fn -> Editor.close(editor) end)

      Form.put_value!(editor, "full_name", "Ada")

      assert refuses(editor, path) =~ "built from a binary"
    end

    @tag :tmp_dir
    test "names the missing source rather than the pending edits", %{path: path} do
      editor = Editor.from_binary!(File.read!(@valid_pdf))
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)
      message = refuses(editor, path)

      assert message =~ "built from a binary"
      refute message =~ "page deletions"
    end

    @tag :tmp_dir
    test "a refused save leaves the modified flag where it was", %{path: path} do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.delete_page!(editor, 1)
      before = Editor.modified?(editor)

      refuses(editor, path)

      assert Editor.modified?(editor) == before
    end

    @tag :tmp_dir
    test "a metadata edit still saves incrementally", %{path: path} do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_title!(editor, "Updated")

      assert {:ok, ^editor} = Editor.save(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert %Document.Metadata{title: "Updated"} = Document.metadata!(doc)
    end
  end

  describe "a destructive pass and an incremental save" do
    @tag :tmp_dir
    test "refuses the save rather than write the unredacted original", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      Editor.apply_redactions!(editor)

      path = Path.join(tmp_dir, "incremental.pdf")

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, path, incremental: true)

      assert message =~ "incremental"
      refute File.exists?(path)

      # The control: a full rewrite does carry the removal.
      full = Path.join(tmp_dir, "full.pdf")
      Editor.save!(editor, full)
      assert :binary.match(File.read!(full), "Secret") == :nomatch
    end

    @tag :tmp_dir
    test "outranks the binary-source refusal", %{tmp_dir: tmp_dir} do
      editor = Editor.from_binary!(File.read!(@redact_pdf))
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      Editor.apply_redactions!(editor)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, Path.join(tmp_dir, "incremental.pdf"), incremental: true)

      assert message =~ "destructive redaction"
      refute message =~ "built from a binary"
    end

    @tag :tmp_dir
    test "refuses it after a sanitization too", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)

      assert {:error, %Error{reason: :unsupported}} =
               Editor.save(editor, Path.join(tmp_dir, "incremental.pdf"), incremental: true)
    end

    @tag :tmp_dir
    test "refuses it after a pass that failed partway", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@redact_partial_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor)
      assert {:error, %Error{reason: :unsupported}} = Editor.apply_redactions(editor)

      # The refusal has to survive the failure: page 0 was rewritten before
      # page 1 errored, so an incremental save would write the original back.
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, Path.join(tmp_dir, "incremental.pdf"), incremental: true)

      assert message =~ "incremental"
    end

    @tag :tmp_dir
    test "refuses a bare mark on different grounds", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      path = Path.join(tmp_dir, "marked.pdf")

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, path, incremental: true)

      assert message =~ "redaction marks"
      refute message =~ "destructive redaction"
      refute File.exists?(path)
    end
  end

  describe "a page whose text state a q/Q restores" do
    # Only the tail of the word: at the 24pt it is drawn in, the region covers
    # the last letters; at the 1pt a q/Q left behind, the whole run collapses to
    # the origin and misses it.
    @qq_tail %PdfElixide.Geometry.Rect{x: 145.0, y: 695.0, width: 40.0, height: 35.0}

    test "is refused rather than measured with the discarded state" do
      editor = Editor.open!(@redact_qq_text_state_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.add_redaction!(editor, 0, @qq_tail)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.apply_redactions(editor)

      assert message =~ "Page 0"
      assert message =~ "q/Q"

      # Nothing was armed, so the refusal is repeatable and reports the same
      # reason rather than the one-pass rule.
      assert {:error, %Error{reason: :unsupported, message: ^message}} =
               Editor.apply_redactions(editor)

      assert page_text(editor, 0) == "Secret"
    end

    test "a page re-setting the font after the restore is measured and applied" do
      editor = Editor.open!(@redact_qq_text_state_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # Page 1 carries the same q/Q and a `Tf` after it. The guard compares the
      # two readings rather than matching the pattern, which is the whole reason
      # this page is not refused with page 0.
      Editor.add_redaction!(editor, 1, @qq_tail)

      assert {:ok, %PdfElixide.RedactionReport{glyphs_removed: 4}} =
               Editor.apply_redactions(editor)

      assert page_text(editor, 1) == "Con"
    end

    test "is refused when a discarded leading moves the line, TD's included" do
      # Page 2 sets the leading with a `TD` inside the block and page 3 with a
      # `TL`, then puts the parameters back in agreement — neither shows up as a
      # parameter difference at the show, only as a position one.
      for {page, word} <- [{2, "Ledger"}, {3, "Baseline"}] do
        editor = Editor.open!(@redact_qq_text_state_pdf)
        on_exit(fn -> Editor.close(editor) end)

        source = Document.open!(@redact_qq_text_state_pdf)
        on_exit(fn -> Document.close(source) end)
        [%{text: ^word} = shown] = Document.words!(source, page)

        # The region a caller would queue: the word's own reported box.
        Editor.add_redaction!(editor, page, shown.bbox)

        assert {:error, %Error{reason: :unsupported, message: message}} =
                 Editor.apply_redactions(editor)

        assert message =~ "Page #{page}"
      end
    end

    test "an ordinary page is not refused" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      assert {:ok, %PdfElixide.RedactionReport{}} = Editor.apply_redactions(editor)
    end

    test "a mark on such a page is still allowed, the cosmetic overlay measuring nothing" do
      editor = Editor.open!(@redact_qq_text_state_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.mark_redactions(editor, 0)
    end

    # The fixture carries no /Annots at all, so every page is marked with
    # nothing to redact and the divergence is unreachable — the common shape
    # under `mark_redactions/1`, which the guard must not refuse.
    test "a marked page with no region to apply is not refused" do
      editor = Editor.open!(@redact_qq_text_state_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor)

      assert {:ok, %PdfElixide.RedactionReport{glyphs_removed: 0, regions: 0}} =
               Editor.apply_redactions(editor)

      # The pass really did reach the diverging page and decline to measure it,
      # rather than the mark having gone missing.
      assert Editor.marked_for_redaction?(editor, 0)
      assert page_text(editor, 0) == "Secret"
    end

    # The other side of the same line: a region on that page puts it back in
    # reach of the defect, so the refusal must return.
    test "a queued region on such a page is still refused" do
      editor = Editor.open!(@redact_qq_text_state_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor)
      Editor.add_redaction!(editor, 0, @qq_tail)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.apply_redactions(editor)

      assert message =~ "Page 0"
    end
  end

  describe "a sanitization and a save that does not collect" do
    @tag :tmp_dir
    test "refuses the save rather than copy the scrubbed objects back out", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@sanitize_objstm_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)
      path = Path.join(tmp_dir, "uncollected.pdf")

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.save(editor, path, garbage_collect: false)

      assert message =~ "garbage_collect"
      refute File.exists?(path)

      # The control: collecting is what carries the scrub, and the fixture
      # keeps its /Info inside an object stream, so this is the shape the
      # refusal protects.
      collected = Path.join(tmp_dir, "collected.pdf")
      Editor.save!(editor, collected, compress: false)
      assert :binary.match(File.read!(collected), "OBJSTMTITLE") == :nomatch
    end

    test "refuses to_binary/2 the same way" do
      editor = Editor.open!(@sanitize_objstm_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)

      assert {:error, %Error{reason: :unsupported}} =
               Editor.to_binary(editor, garbage_collect: false)
    end

    test "outranks to_binary/2's refusal of an incremental request" do
      editor = Editor.open!(@sanitize_objstm_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)

      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.to_binary(editor, incremental: true, garbage_collect: false)

      assert message =~ "garbage_collect"
    end

    test "allows it before one" do
      editor = Editor.open!(@sanitize_objstm_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, bytes} = Editor.to_binary(editor, garbage_collect: false)
      assert byte_size(bytes) > 0
    end

    test "allows it after a destructive redaction, which drops by id either way" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.mark_redactions!(editor, 0)
      Editor.apply_redactions!(editor)

      assert {:ok, bytes} = Editor.to_binary(editor, garbage_collect: false, compress: false)
      assert :binary.match(bytes, "Secret") == :nomatch
    end
  end

  describe "redaction and the page operations" do
    test "a mark follows its page through a move" do
      editor = Editor.open!(@redact_pdf)
      on_exit(fn -> Editor.close(editor) end)

      editor |> Editor.mark_redactions!(0) |> Editor.move_page!(0, 1)

      doc = written(editor)
      assert Document.rects!(doc, 0) == []

      assert doc |> Document.rects!(1) |> Enum.map(&{&1.bbox, &1.fill_color}) ==
               [{@redact_rect, @red}, {@quad_rect, @black}]

      Document.close(doc)
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

    # `attachments.pdf` above has an indirect `/Names`; this one is direct, which
    # is the shape the scrubbed-entry filtering walks.
    test "refuses a direct name tree, naming every entry" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:error, %Error{reason: :unsupported} = error} =
               Editor.embed_file(editor, "added.txt", "added")

      assert error.message =~ "EmbeddedFiles"
      assert error.message =~ "JavaScript"
    end

    test "attaches to a document whose name tree a sanitize emptied" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor)
      assert {:ok, ^editor} = Editor.embed_file(editor, "clean.txt", "CLEAN")

      bytes = Editor.to_binary!(editor)

      assert [%EmbeddedFile{name: "clean.txt", data: "CLEAN"}] =
               bytes |> Document.from_binary!() |> Document.embedded_files!()

      # The rebuild must not resurrect what the sanitize removed: it merges into
      # the scrubbed catalog, not the source's.
      assert :binary.match(bytes, "note.txt") == :nomatch
      assert :binary.match(bytes, "app.alert") == :nomatch
    end

    test "still refuses when the sanitize left an entry in the name tree" do
      editor = Editor.open!(@sanitize_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.sanitize!(editor, remove_javascript: false)

      assert {:error, %Error{reason: :unsupported} = error} =
               Editor.embed_file(editor, "clean.txt", "CLEAN")

      assert error.message =~ "JavaScript"
      refute error.message =~ "EmbeddedFiles"
    end

    test "raises for a name that is empty or not a string" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert_raise FunctionClauseError, fn -> Editor.embed_file(editor, "", "x") end
      assert_raise FunctionClauseError, fn -> Editor.embed_file(editor, untyped(:name), "x") end
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

  describe "metadata/1" do
    test "reads the source's /Info before any edit" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)
      doc = Document.open!(@metadata_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert {:ok, %Document.Metadata{trapped: "True"} = metadata} = Editor.metadata(editor)
      assert metadata == Document.metadata!(doc)
    end

    test "reflects a pending setter and keeps the source's /Trapped" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_title!(editor, "Pending")

      assert %Document.Metadata{title: "Pending", author: "Jane Doe", trapped: "True"} =
               Editor.metadata!(editor)
    end

    test "returns {:error, :closed} for a closed editor" do
      editor = Editor.open!(@metadata_pdf)
      :ok = Editor.close(editor)

      assert {:error, %Error{reason: :closed}} = Editor.metadata(editor)
      assert_raise Error, fn -> Editor.metadata!(editor) end
    end
  end

  describe "the text setters" do
    for field <- ~w(title author subject keywords creator producer)a do
      @field field

      test "set_#{field}/2 returns the same editor and marks it modified" do
        editor = Editor.open!(@valid_pdf)
        on_exit(fn -> Editor.close(editor) end)

        refute Editor.modified?(editor)
        assert {:ok, ^editor} = set_info(editor, @field, "value")
        assert Editor.modified?(editor)
        assert Map.fetch!(Editor.metadata!(editor), @field) == "value"
      end

      test "set_#{field}!/2 writes non-ASCII text that reads back unchanged" do
        editor = Editor.open!(@valid_pdf)
        on_exit(fn -> Editor.close(editor) end)

        bytes = editor |> set_info!(@field, "Título 🙂") |> Editor.to_binary!()

        assert bytes =~ "EFBBBF"
        assert Map.fetch!(saved_metadata(bytes), @field) == "Título 🙂"
      end

      test "set_#{field}/2 raises ArgumentError naming the key for a non-string" do
        editor = Editor.open!(@valid_pdf)
        on_exit(fn -> Editor.close(editor) end)

        assert_raise ArgumentError, ~r/:#{@field}/, fn -> set_info(editor, @field, 42) end
        assert_raise ArgumentError, ~r/:#{@field}/, fn -> set_info(editor, @field, <<0xFF>>) end
      end

      test "set_#{field}!/2 raises for a closed editor" do
        editor = Editor.open!(@valid_pdf)
        :ok = Editor.close(editor)

        assert {:error, %Error{reason: :closed}} = set_info(editor, @field, "value")
        assert_raise Error, fn -> set_info!(editor, @field, "value") end
      end
    end

    test "nil removes an entry the source had and the rest survive" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)

      metadata = editor |> Editor.set_author!(nil) |> Editor.to_binary!() |> saved_metadata()

      assert %Document.Metadata{
               title: "Test Title",
               author: nil,
               subject: "Testing",
               keywords: "alpha, beta",
               creator: "pdf_elixide test",
               producer: "pdf_elixide",
               creation_date: "D:20240115120000Z"
             } = metadata
    end

    test "a whitespace-only value reads back as nil on both handles" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_subject!(editor, "   ")

      assert Editor.metadata!(editor).subject == nil
      assert (editor |> Editor.to_binary!() |> saved_metadata()).subject == nil
    end
  end

  describe "set_creation_date/2 and set_mod_date/2" do
    test "formats a UTC DateTime as a PDF date, dropping fractional seconds" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      assert {:ok, ^editor} = Editor.set_creation_date(editor, ~U[2024-01-15 12:00:00.123Z])
      Editor.set_mod_date!(editor, ~U[2024-02-29 23:59:59Z])

      assert %Document.Metadata{
               creation_date: "D:20240115120000Z",
               mod_date: "D:20240229235959Z"
             } = editor |> Editor.to_binary!() |> saved_metadata()
    end

    test "writes a non-zero offset as +HH'mm'" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      # No time zone database is available, so build the offsets by hand.
      utc = ~U[2024-01-15 12:00:00Z]
      east = %{utc | utc_offset: 19_800, time_zone: "Asia/Kolkata", zone_abbr: "IST"}
      west = %{utc | utc_offset: -18_000, time_zone: "America/New_York", zone_abbr: "EST"}

      editor |> Editor.set_creation_date!(east) |> Editor.set_mod_date!(west)

      assert %Document.Metadata{
               creation_date: "D:20240115120000+05'30'",
               mod_date: "D:20240115120000-05'00'"
             } = Editor.metadata!(editor)
    end

    test "writes a sub-minute offset in UTC, keeping the instant" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      utc = ~U[2024-01-15 12:00:00Z]
      # Amsterdam local mean time, +00:19:32, which no PDF offset can spell.
      lmt = %{utc | utc_offset: 1_172, time_zone: "Europe/Amsterdam", zone_abbr: "LMT"}

      Editor.set_creation_date!(editor, lmt)

      assert Editor.metadata!(editor).creation_date == "D:20240115114028Z"
    end

    test "passes a well-formed PDF date string through unchanged" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_creation_date!(editor, "D:20240115120000+02'00'")
      Editor.set_mod_date!(editor, "D:2024")

      assert %Document.Metadata{
               creation_date: "D:20240115120000+02'00'",
               mod_date: "D:2024"
             } = editor |> Editor.to_binary!() |> saved_metadata()
    end

    test "raises ArgumentError naming the key for anything else" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      for bad <- [
            "2024-01-15",
            "D:20240231000000Z",
            "D:20240115120000Zжж",
            "D:20240115120000Zgarbage",
            "D:20240115120000+03'00'x",
            42,
            ~D[2024-01-15]
          ] do
        assert_raise ArgumentError, ~r/:creation_date/, fn ->
          Editor.set_creation_date(editor, bad)
        end

        assert_raise ArgumentError, ~r/:mod_date/, fn -> Editor.set_mod_date!(editor, bad) end
      end

      refute Editor.modified?(editor)
    end

    test "nil removes the entry" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)

      Editor.set_creation_date!(editor, nil)

      assert Editor.metadata!(editor).creation_date == nil
      assert (editor |> Editor.to_binary!() |> saved_metadata()).creation_date == nil
    end
  end

  describe "document information on a full write" do
    test "carries the source's entries across an untouched rewrite, except /Trapped" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)
      doc = Document.open!(@metadata_pdf)
      on_exit(fn -> Document.close(doc) end)

      bytes = Editor.to_binary!(editor)

      refute Editor.modified?(editor)
      assert saved_metadata(bytes) == %{Document.metadata!(doc) | trapped: nil}
    end

    test "re-encodes every text-string encoding the source used" do
      editor = Editor.open!(@metadata_encodings_pdf)
      on_exit(fn -> Editor.close(editor) end)
      doc = Document.open!(@metadata_encodings_pdf)
      on_exit(fn -> Document.close(doc) end)

      assert %Document.Metadata{title: "Título 🙂", trapped: "Unknown"} =
               source = Document.metadata!(doc)

      assert editor |> Editor.to_binary!() |> saved_metadata() == %{source | trapped: nil}
    end

    test "writes no /Info for a document that had none" do
      editor = Editor.open!(@valid_pdf)
      on_exit(fn -> Editor.close(editor) end)

      bytes = Editor.to_binary!(editor)

      refute bytes =~ "/Info"
      refute Editor.modified?(editor)
    end

    test "a second write carries the same entries" do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)

      first = editor |> Editor.set_title!("Twice") |> Editor.to_binary!() |> saved_metadata()

      assert first.title == "Twice"
      assert editor |> Editor.to_binary!() |> saved_metadata() == first
    end

    @tag :tmp_dir
    test "an untouched incremental save carries the entries too", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(tmp_dir, "incremental_untouched_info.pdf")

      Editor.save!(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert %Document.Metadata{title: "Test Title", author: "Jane Doe", trapped: nil} =
               Document.metadata!(doc)
    end

    @tag :tmp_dir
    test "an incremental save after a full write repeats the dictionary", %{tmp_dir: tmp_dir} do
      editor = Editor.open!(@metadata_pdf)
      on_exit(fn -> Editor.close(editor) end)
      path = Path.join(tmp_dir, "repeated_info.pdf")

      Editor.to_binary!(editor)
      Editor.save!(editor, path, incremental: true)

      doc = Document.open!(path)
      on_exit(fn -> Document.close(doc) end)

      assert %Document.Metadata{title: "Test Title", trapped: nil} = Document.metadata!(doc)
    end
  end

  defp set_info(editor, field, value), do: apply(Editor, :"set_#{field}", [editor, value])
  defp set_info!(editor, field, value), do: apply(Editor, :"set_#{field}!", [editor, value])

  defp saved_metadata(bytes) do
    doc = Document.from_binary!(bytes)
    metadata = Document.metadata!(doc)
    Document.close(doc)

    metadata
  end
end
