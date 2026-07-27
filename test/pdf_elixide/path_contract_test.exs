defmodule PdfElixide.PathContractTest do
  @moduledoc """
  The file-path contract, in one place.

  Every path this library accepts crosses into a NIF that decodes it as a Rust
  `String`, so a path that is not valid UTF-8 fails at argument decode — an
  `ArgumentError`, the caller-bug half of the split `PdfElixide.Error`
  documents, never an `%Error{reason: :io}`. Nothing about that is enforced in
  Elixir: it is a property of Rustler's decoder, which is exactly why it needs
  pinning rather than trusting. The "File paths" section of `PdfElixide` is what
  these tests hold to account.

  The two failure *routes* are deliberately both covered, because they produce
  different messages. A path passed as its own argument raises `:badarg`, which
  Elixir normalizes to a bare `ArgumentError` naming nothing; `:image_output_dir`
  is a `NifMap` field instead, so it arrives through
  `PdfElixide.Native.Wrap.call/1`'s "Could not decode field" clause and *does*
  name the key. Losing that second one would be a silent downgrade in
  diagnosability, so its message is asserted, not just its type.

  Also pinned here: the constraint is UTF-8 and not ASCII (a non-ASCII path that
  is valid UTF-8 opens fine), and the documented gap between the `Path.t()` specs
  and the `is_binary/1` guards beneath them (a charlist raises
  `FunctionClauseError`).
  """
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")

  # A lone 0xFF byte is not valid UTF-8 in any position, so this is a binary no
  # `String` decode can accept — and a perfectly legal filename on Linux.
  @bad_path <<0xFF>>

  describe "a path that is not valid UTF-8" do
    test "Document.open/2 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Document.open(@bad_path) end
    end

    test "Document.open!/2 raises ArgumentError, not a PdfElixide.Error" do
      assert_raise ArgumentError, fn -> Document.open!(@bad_path) end
    end

    test "Editor.open/1 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Editor.open(@bad_path) end
    end

    test "Editor.open!/1 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Editor.open!(@bad_path) end
    end

    test "Editor.save/3 raises ArgumentError" do
      editor = Editor.open!(@valid_pdf)
      assert_raise ArgumentError, fn -> Editor.save(editor, @bad_path) end
    end

    test "Editor.save!/3 raises ArgumentError" do
      editor = Editor.open!(@valid_pdf)
      assert_raise ArgumentError, fn -> Editor.save!(editor, @bad_path) end
    end

    test "Image.save/3 raises ArgumentError" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)

      # `:format` is given explicitly so the failure is the NIF's path decode
      # rather than `Path.extname/1` on a raw-byte binary.
      assert_raise ArgumentError, fn ->
        Document.Image.save(image, @bad_path, format: :png)
      end
    end
  end

  describe "an :image_output_dir that is not valid UTF-8" do
    setup do
      %{doc: Document.open!(@valid_pdf)}
    end

    test "to_markdown/2 raises ArgumentError naming the key", %{doc: doc} do
      assert_raise ArgumentError, ~r/:image_output_dir/, fn ->
        Document.to_markdown(doc,
          include_images: true,
          embed_images: false,
          image_output_dir: @bad_path
        )
      end
    end

    test "to_html/2 raises ArgumentError naming the key", %{doc: doc} do
      assert_raise ArgumentError, ~r/:image_output_dir/, fn ->
        Document.to_html(doc,
          include_images: true,
          embed_images: false,
          image_output_dir: @bad_path
        )
      end
    end
  end

  describe "the constraint is UTF-8, not ASCII" do
    @describetag :tmp_dir

    test "a non-ASCII path opens", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "café.pdf")
      File.cp!(@valid_pdf, path)

      assert {:ok, doc} = Document.open(path)
      assert doc.page_count == 3
    end

    test "a non-ASCII path is written to", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sortie-café.pdf")

      assert :ok = Editor.open!(@valid_pdf) |> Editor.save(path)
      assert File.exists?(path)
    end
  end

  describe "only the binary form of Path.t() is accepted" do
    test "Document.open/2 rejects a charlist" do
      assert_raise FunctionClauseError, fn -> Document.open(~c"sample.pdf") end
    end

    test "Editor.open/1 rejects a charlist" do
      assert_raise FunctionClauseError, fn -> Editor.open(~c"sample.pdf") end
    end
  end
end
