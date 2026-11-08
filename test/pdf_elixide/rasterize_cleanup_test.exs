defmodule PdfElixide.RasterizeCleanupTest do
  @moduledoc false
  # Run alone: every rasterize call on the node shares the directory under test.
  use ExUnit.Case, async: false

  alias PdfElixide.Document
  alias PdfElixide.Error

  @degenerate_box_pdf Elixir.Path.join([__DIR__, "..", "fixtures", "degenerate_box.pdf"])
  @sample_pdf Elixir.Path.join([__DIR__, "..", "fixtures", "sample.pdf"])
  @windows match?({:win32, _}, :os.type())

  # Privileged runners can bypass the permissions used by the refusal test.
  @modes_bind not @windows and
                (fn ->
                   dir = Elixir.Path.join(System.tmp_dir!(), "pdf_elixide_modes_#{:os.getpid()}")
                   File.mkdir_p!(dir)
                   File.chmod!(dir, 0o500)
                   denied = File.touch(Elixir.Path.join(dir, "probe")) == {:error, :eacces}
                   File.chmod!(dir, 0o700)
                   File.rm_rf!(dir)
                   denied
                 end).()

  defp flatten_dir do
    Elixir.Path.join(System.tmp_dir!(), "pdf_oxide_flatten_#{:os.getpid()}")
  end

  test "a rasterize that fails part-way leaves no page images behind" do
    doc = Document.open!(@degenerate_box_pdf)
    on_exit(fn -> Document.close(doc) end)

    # The zero-area page fails after page 0 is written; a preflight refusal
    # would pass the cleanup assertion without creating the directory.
    assert {:error, %Error{reason: :invalid_pdf}} = Document.rasterize(doc, dpi: 18)

    refute File.exists?(flatten_dir())
  end

  describe "an existing staging path" do
    @describetag skip: @windows and "these setups need Unix links and permissions"

    setup do
      doc = Document.open!(@sample_pdf)
      elsewhere = Elixir.Path.join(System.tmp_dir!(), "pdf_elixide_elsewhere_#{:os.getpid()}")

      on_exit(fn ->
        Document.close(doc)
        File.chmod(flatten_dir(), 0o700)
        File.rm_rf(flatten_dir())
        File.rm_rf(elsewhere)
      end)

      %{doc: doc, elsewhere: elsewhere}
    end

    test "a link is replaced rather than followed", %{doc: doc, elsewhere: elsewhere} do
      File.mkdir_p!(elsewhere)
      File.ln_s!(elsewhere, flatten_dir())

      assert {:ok, _flat} = Document.rasterize(doc, dpi: 18)

      assert File.ls!(elsewhere) == []
      assert {:error, :enoent} = File.lstat(flatten_dir())
    end

    @tag skip: not @modes_bind and "the runner is not bound by Unix mode bits"
    test "one that cannot be removed is refused, and left as found", %{doc: doc} do
      File.mkdir_p!(flatten_dir())
      File.write!(Elixir.Path.join(flatten_dir(), "page_0.png"), "theirs")
      File.chmod!(flatten_dir(), 0o500)

      assert {:error, %Error{reason: :io, message: message}} = Document.rasterize(doc, dpi: 18)
      assert message =~ "cannot prepare the private directory"

      assert File.read!(Elixir.Path.join(flatten_dir(), "page_0.png")) == "theirs"
    end
  end
end
