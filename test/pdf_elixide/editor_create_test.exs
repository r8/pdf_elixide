defmodule PdfElixide.EditorCreateTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect

  defp written(%Editor{} = editor) do
    doc = editor |> Editor.to_binary!() |> Document.from_binary!()
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp lines(count), do: Enum.map_join(1..count, "\n", &"line #{&1}")

  describe "from_markdown/2" do
    test "returns an editor with no source path, like from_binary/2" do
      editor = Editor.from_markdown!("# Title\n\nBody")

      assert %Editor{source_path: nil, version: {1, _}} = editor
      assert Editor.page_count!(editor) == 1
      refute Editor.modified?(editor)
    end

    test "lays out headings, emphasis, bullets and quotes as text" do
      text =
        "# Title\n\nSome **bold** and *italic* text.\n\n- item\n\n> quoted"
        |> Editor.from_markdown!()
        |> written()
        |> Document.text!()

      assert text =~ "Title"
      assert text =~ "Some bold and italic text."
      assert text =~ "• item"
      assert text =~ "quoted"
      refute text =~ "**"
    end

    test "scales headings from :font_size" do
      chars =
        "# Big\n\nsmall"
        |> Editor.from_markdown!(font_size: 10)
        |> written()
        |> Document.chars!(0)

      sizes = Map.new(chars, &{&1.text, &1.font_size})
      assert sizes["B"] == 20.0
      assert sizes["s"] == 10.0
    end

    test "writes :title, :author and :subject" do
      editor = Editor.from_markdown!("Body", title: "T", author: "A", subject: "S")

      assert %{title: "T", author: "A", subject: "S"} = Editor.metadata!(editor)

      assert %{title: "T", author: "A", subject: "S"} =
               editor |> written() |> Document.metadata!()
    end

    test "paginates when the bottom margin is reached" do
      editor = Editor.from_markdown!(lines(200))

      assert Editor.page_count!(editor) > 1
      assert editor |> written() |> Document.text!() =~ "line 200"
    end

    test "embeds a font for text outside Windows-1252" do
      assert "Привет, κόσμε" |> Editor.from_markdown!() |> written() |> Document.text!() =~
               "Привет, κόσμε"
    end

    test "sets code in a font that shows ? outside Windows-1252" do
      text = "```\nкод\n```" |> Editor.from_markdown!() |> written() |> Document.text!()

      assert text =~ "???"
    end

    test "survives an encrypted write" do
      bytes =
        "Secret"
        |> Editor.from_markdown!()
        |> Editor.to_binary!(encryption: [user_password: "pw"])

      doc = Document.from_binary!(bytes, password: "pw")
      on_exit(fn -> Document.close(doc) end)
      assert Document.encrypted?(doc)
      assert Document.text!(doc) =~ "Secret"
    end

    test "refuses an incremental save" do
      path = Path.join(System.tmp_dir!(), "create-#{System.unique_integer([:positive])}.pdf")
      on_exit(fn -> File.rm(path) end)

      assert {:error, %Error{reason: :unsupported}} =
               "x" |> Editor.from_markdown!() |> Editor.save(path, incremental: true)

      refute File.exists?(path)
    end

    test "accepts empty content as one blank page" do
      assert "" |> Editor.from_markdown!() |> Editor.page_count!() == 1
    end
  end

  describe "from_html/2" do
    test "lays out the recognised tags as text" do
      text =
        "<h1>Title</h1><p>Some <b>bold</b> and <em>italic</em>.</p><ul><li>item</li></ul>"
        |> Editor.from_html!()
        |> written()
        |> Document.text!()

      assert text =~ "Title"
      assert text =~ "Some bold and italic"
      assert text =~ "• item"
      refute text =~ "<"
    end

    test "sets a bare heading larger than body text" do
      sizes =
        "<h1>Big</h1><p>small</p>"
        |> Editor.from_html!()
        |> written()
        |> Document.chars!(0)
        |> Map.new(&{&1.text, &1.font_size})

      assert sizes["B"] == 24.0
      assert sizes["s"] == 12.0
    end
  end

  describe "from_plain_text/2" do
    test "keeps each line and interprets no markup" do
      text =
        "# not a heading\n**not bold**\n\n<b>not a tag</b>"
        |> Editor.from_plain_text!()
        |> written()
        |> Document.text!()

      assert text =~ "# not a heading"
      assert text =~ "**not bold**"
      assert text =~ "<b>not a tag</b>"
    end

    test "sets every line at 12 points" do
      chars = "Hello" |> Editor.from_plain_text!() |> written() |> Document.chars!(0)

      assert Enum.all?(chars, &(&1.font_size == 12.0))
    end

    test "writes :title and :author" do
      editor = Editor.from_plain_text!("Body", title: "T", author: "A")

      assert %{title: "T", author: "A"} = editor |> written() |> Document.metadata!()
    end

    test "renders Windows-1252 characters beyond ASCII" do
      text = "café — “quoted” €5" |> Editor.from_plain_text!() |> written() |> Document.text!()

      assert text =~ "café — “quoted” €5"
    end

    test "refuses a character outside Windows-1252, naming it" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.from_plain_text("ok\nПривет")

      assert message =~ "'П' (U+041F)"
      assert message =~ "from_markdown/2"
    end

    test "refuses a mathematical letter rather than setting its plain form" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Editor.from_plain_text("𝑥 + 𝟗")

      assert message =~ "U+1D465"
    end

    test "paginates when the bottom margin is reached" do
      assert lines(200) |> Editor.from_plain_text!() |> Editor.page_count!() > 1
    end

    test "breaks the page across a page-long run of blank lines" do
      doc = ("a" <> String.duplicate("\n", 36) <> "b") |> Editor.from_plain_text!() |> written()

      assert Document.page_count!(doc) == 2
      assert Document.text!(doc, 0) =~ "a"
      refute Document.text!(doc, 0) =~ "b"
      assert Document.text!(doc, 1) =~ "b"
    end

    test "adds no page for trailing blank lines" do
      assert ("a" <> String.duplicate("\n", 100))
             |> Editor.from_plain_text!()
             |> Editor.page_count!() ==
               1
    end
  end

  describe ":page_size" do
    test "sets each named size in points" do
      for {size, width, height} <- [
            {:letter, 612.0, 792.0},
            {:a4, 595.0, 842.0},
            {:legal, 612.0, 1008.0},
            {:a3, 842.0, 1190.0}
          ] do
        editor = Editor.from_plain_text!("x", page_size: size)

        assert Editor.media_box!(editor, 0) == %Rect{x: 0.0, y: 0.0, width: width, height: height}
      end
    end

    test "takes a custom {width, height}" do
      editor = Editor.from_markdown!("x", page_size: {300, 400.5})

      assert Editor.media_box!(editor, 0) == %Rect{x: 0.0, y: 0.0, width: 300.0, height: 400.5}
    end
  end

  describe "margins" do
    test "place the first line below the top and after the left margin" do
      [char | _] =
        "Hello"
        |> Editor.from_plain_text!(margin_top: 100, margin_left: 50)
        |> written()
        |> Document.chars!(0)

      {x, y} = char.origin
      assert_in_delta x, 50.0, 0.01
      assert y < 792.0 - 100.0
    end
  end

  describe "argument errors" do
    test "content that is not UTF-8 raises" do
      assert_raise ArgumentError, fn -> Editor.from_markdown(<<0xFF>>) end
      assert_raise ArgumentError, fn -> Editor.from_plain_text(<<0xFF>>) end
    end

    test "content that is not a binary raises" do
      assert_raise FunctionClauseError, fn -> Editor.from_html(untyped(~c"<p>x</p>")) end
    end

    test "an unknown paper size raises naming :page_size" do
      assert_raise ArgumentError, ~r/:page_size/, fn ->
        Editor.from_markdown("x", page_size: :b5)
      end
    end

    test "a non-positive dimension, font size or line height raises naming it" do
      for {key, value} <- [
            page_size: {0, 100},
            page_size: {100, -1},
            page_size: {1.0e-50, 100},
            font_size: 0,
            font_size: 1.0e-50,
            line_height: -1.0,
            line_height: 1.0e-50
          ] do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn ->
          Editor.from_markdown("x", [{key, value}])
        end
      end
    end

    test "a negative margin raises naming it" do
      assert_raise ArgumentError, ~r/:margin_left/, fn ->
        Editor.from_plain_text("x", margin_left: -1)
      end
    end

    test "a left margin as wide as the page raises" do
      assert_raise ArgumentError, ~r/:margin_left.*no room/, fn ->
        Editor.from_markdown("x", margin_left: 612)
      end
    end

    test "a left margin that equals the page width as a 32-bit float raises" do
      assert_raise ArgumentError, ~r/:margin_left.*no room/, fn ->
        Editor.from_plain_text("x", page_size: {612.00003, 792}, margin_left: 612.00002)
      end
    end

    test "a page too short for two of the tallest lines raises" do
      for opts <- [
            [margin_top: 400, margin_bottom: 392],
            [page_size: {200, 200}, margin_top: 100, margin_bottom: 100],
            [margin_top: 380, margin_bottom: 400],
            [font_size: 400],
            [line_height: 30]
          ] do
        assert_raise ArgumentError, ~r/fewer than two lines/, fn ->
          Editor.from_markdown("x", opts)
        end
      end

      assert_raise ArgumentError, ~r/fewer than two lines/, fn ->
        Editor.from_plain_text("x", margin_top: 380, margin_bottom: 400)
      end
    end

    test "a page with room for two lines only after f64 rounding raises" do
      assert_raise ArgumentError, ~r/fewer than two lines/, fn ->
        Editor.from_plain_text("a\nb\nc",
          margin_top: 0.3,
          margin_bottom: 778.02,
          line_height: 0.57
        )
      end
    end

    test "a tall page with room for two lines only before 32-bit rounding raises" do
      assert_raise ArgumentError, ~r/fewer than two lines/, fn ->
        Editor.from_plain_text("a\nb\nc\nd",
          page_size: {612, 769_994.1875},
          margin_top: 67_201.234375,
          margin_bottom: 702_778.375,
          line_height: 0.6069159507751465
        )
      end
    end

    test "lines too close together to place on the page raise" do
      assert_raise ArgumentError, ~r/cannot be placed/, fn ->
        Editor.from_plain_text("a\nb", line_height: 1.0e-6)
      end

      for opts <- [[font_size: 1.0e-5], [page_size: {612, 1.0e9}]] do
        assert_raise ArgumentError, ~r/cannot be placed/, fn ->
          Editor.from_markdown("a\nb", opts)
        end
      end
    end

    test "small text on an ordinary page is still placed line by line" do
      ys =
        "a\nb\nc"
        |> Editor.from_markdown!(font_size: 1, line_height: 0.5)
        |> written()
        |> Document.chars!(0)
        |> Enum.map(&elem(&1.origin, 1))

      assert length(Enum.uniq(ys)) == 3
    end

    test "plain text needs room for two 12-point lines, not two headings" do
      opts = [margin_top: 380, margin_bottom: 350]

      assert_raise ArgumentError, ~r/fewer than two lines/, fn ->
        Editor.from_markdown("x", opts)
      end

      doc = lines(10) |> Editor.from_plain_text!(opts) |> written()

      assert Document.page_count!(doc) > 1

      for page <- 0..(Document.page_count!(doc) - 1) do
        ys = doc |> Document.text_lines!(page) |> Enum.map(& &1.bbox.y)
        assert ys == Enum.uniq(ys)
      end
    end

    test "a value of the wrong type raises naming the key" do
      assert_raise ArgumentError, ~r/:title/, fn -> Editor.from_markdown("x", title: 1) end
    end
  end
end
