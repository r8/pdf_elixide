defmodule PdfElixide.PathContractTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @valid_pdf Path.join(@fixtures, "sample.pdf")
  @image_pdf Path.join(@fixtures, "image.pdf")

  # A lone 0xFF byte is not valid UTF-8 in any position, so this is a filename
  # no `String` decode could accept — and a perfectly legal one on Linux.
  @bad_name <<0xFF>> <> ".pdf"
  @missing_path Path.join(System.tmp_dir!(), "pdf_elixide_absent_" <> @bad_name)

  # The platform, because `fs_path.rs` decodes a path differently on Windows —
  # which holds whatever the filesystem would accept, and is why the probe below
  # cannot answer this on its own.
  @windows match?({:win32, _}, :os.type())

  # Evaluated once at compile time: whether a byte-named path can round-trip
  # through *this library* here. Two independent reasons it cannot, and the
  # platform is folded in ahead of the filesystem probe rather than checked
  # beside it — on Windows the probe answers `true`, since the VM translates the
  # stray byte into a legal NTFS name and writes it, while the NIF is handed the
  # raw binary and requires UTF-8. macOS fails the probe instead: APFS rejects
  # the name outright. Keeping it one expression also keeps the probe off the
  # platform that would answer it misleadingly.
  @byte_names_round_trip not @windows and
                           (fn ->
                              probe =
                                Path.join(System.tmp_dir!(), "pdf_elixide_probe_" <> <<0xFF>>)

                              storable = File.write(probe, "probe") == :ok
                              File.rm(probe)
                              storable
                            end).()

  describe "a path with no UTF-8 spelling, on Unix" do
    @describetag skip: @windows and "Windows rejects a byte path before opening it"

    test "Document.open/2 reports a filesystem error, not an ArgumentError" do
      assert {:error, %Error{reason: :io}} = Document.open(@missing_path)
    end

    test "Document.open!/2 raises a PdfElixide.Error, not an ArgumentError" do
      assert_raise Error, fn -> Document.open!(@missing_path) end
    end

    test "Editor.open/1 reports a filesystem error" do
      assert {:error, %Error{reason: :io}} = Editor.open(@missing_path)
    end

    test "Editor.open!/1 raises a PdfElixide.Error" do
      assert_raise Error, fn -> Editor.open!(@missing_path) end
    end
  end

  describe "a path with no UTF-8 spelling, on Windows" do
    @describetag skip: not @windows and "only Windows rejects a byte path"

    # The executable half of the claim `PdfElixide`'s "File paths" section and
    # `fs_path.rs` otherwise make only in prose. It is an `ArgumentError` rather
    # than an `%Error{}` because the rejection happens at argument decode, which
    # makes it a caller bug in the sense `PdfElixide.Error` documents.
    test "Document.open/2 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Document.open(@missing_path) end
    end

    test "Document.open!/2 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Document.open!(@missing_path) end
    end

    test "Editor.open/1 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Editor.open(@missing_path) end
    end

    test "Editor.open!/1 raises ArgumentError" do
      assert_raise ArgumentError, fn -> Editor.open!(@missing_path) end
    end
  end

  describe "a byte-named file round-trips" do
    @describetag :tmp_dir
    @describetag skip:
                   not @byte_names_round_trip and
                     "this host cannot round-trip a byte-named path"

    test "Document.open/2 reads one", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, @bad_name)
      File.cp!(@valid_pdf, path)

      assert {:ok, doc} = Document.open(path)
      assert doc.page_count == 3
      assert Document.source_path(doc) == path
    end

    test "Editor.open/1 reads one", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, @bad_name)
      File.cp!(@valid_pdf, path)

      assert {:ok, editor} = Editor.open(path)
      assert Editor.source_path(editor) == path
    end

    test "Editor.save/3 writes one, and it reopens", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "out-" <> @bad_name)

      assert {:ok, %Editor{}} = Editor.open!(@valid_pdf) |> Editor.save(path)
      assert File.exists?(path)
      assert {:ok, doc} = Document.open(path)
      assert doc.page_count == 3
    end

    test "Image.save/3 writes one", %{tmp_dir: tmp_dir} do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)
      path = Path.join(tmp_dir, <<0xFF>> <> ".png")

      # `:format` is given explicitly rather than inferred, so a change in
      # `Path.extname/1` on a raw-byte binary cannot quietly become the reason
      # this passes or fails.
      assert :ok = Document.Image.save(image, path, format: :png)
      assert File.exists?(path)
    end
  end

  describe "inspecting a handle opened from a byte-named file" do
    # Needs no such file to exist: `Inspect` reads the struct field. Validity is
    # the whole bar, and it is exactly the condition `IO.puts/1` checks — it
    # raises `:no_translation` on a binary with no UTF-8 spelling, so an
    # unescaped basename here would turn a log line or an IEx prompt into a
    # crash.
    test "Document renders a printable result" do
      doc = %Document{ref: make_ref(), version: {1, 4}, page_count: 3, source_path: @bad_name}

      assert String.valid?(inspect(doc))
    end

    test "Editor renders a printable result" do
      editor = %Editor{ref: make_ref(), version: {1, 4}, source_path: @bad_name}

      assert String.valid?(inspect(editor))
    end

    test "a valid-UTF-8 path still renders as a bare basename" do
      doc = %Document{ref: make_ref(), version: {1, 4}, page_count: 3, source_path: "a/b.pdf"}

      assert inspect(doc) == "#PdfElixide.Document<b.pdf v1.4>"
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
          image_output_dir: <<0xFF>>
        )
      end
    end

    test "to_html/2 raises ArgumentError naming the key", %{doc: doc} do
      assert_raise ArgumentError, ~r/:image_output_dir/, fn ->
        Document.to_html(doc,
          include_images: true,
          embed_images: false,
          image_output_dir: <<0xFF>>
        )
      end
    end
  end

  describe "a non-ASCII path" do
    @describetag :tmp_dir

    test "opens", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "café.pdf")
      File.cp!(@valid_pdf, path)

      assert {:ok, doc} = Document.open(path)
      assert doc.page_count == 3
    end

    test "is written to", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sortie-café.pdf")

      assert {:ok, %Editor{}} = Editor.open!(@valid_pdf) |> Editor.save(path)
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

    test "Editor.save/3 rejects a charlist" do
      editor = Editor.open!(@valid_pdf)
      assert_raise FunctionClauseError, fn -> Editor.save(editor, ~c"out.pdf") end
    end

    test "Image.save/3 rejects a charlist" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)

      assert_raise FunctionClauseError, fn ->
        Document.Image.save(image, ~c"out.png", format: :png)
      end
    end

    test "Image.save!/3 rejects a charlist" do
      [image | _] = Document.open!(@image_pdf) |> Document.images!(0)

      assert_raise FunctionClauseError, fn ->
        Document.Image.save!(image, ~c"out.png", format: :png)
      end
    end
  end
end
