defmodule PdfElixide.BuilderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Builder
  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Editor
  alias PdfElixide.Error

  # Helvetica's ascent and descent, in thousandths of an em.
  @ascent 718
  @descent -207

  defp written(%Builder{} = builder) do
    doc = builder |> Builder.to_binary!() |> Document.from_binary!()
    on_exit(fn -> Document.close(doc) end)
    doc
  end

  defp baselines(doc, page) do
    doc
    |> Document.chars!(page)
    |> Enum.map(&Float.round(&1.bbox.y, 3))
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  # Where a line box with its top at `top` puts its baseline.
  defp baseline(top, size, line_height \\ 1.5) do
    half_leading = (size * line_height - (@ascent - @descent) * size / 1000) / 2
    top - half_leading - @ascent * size / 1000
  end

  defp lines(count), do: Enum.map_join(1..count, "\n", &"line #{&1}")

  describe "the output" do
    test "an empty description is one blank page of the default size" do
      doc = written(Builder.new())

      assert Document.page_count!(doc) == 1
      assert %{width: 612.0, height: 792.0} = Page.media_box!(Document.page!(doc, 0))
      assert Document.chars!(doc, 0) == []
    end

    test "writes the document information" do
      metadata =
        Builder.new(title: "Title", author: "Author", subject: "Subject", creator: "Creator")
        |> written()
        |> Document.metadata!()

      assert %{title: "Title", author: "Author", subject: "Subject", creator: "Creator"} =
               metadata
    end

    test "Editor.from_builder/1 opens an editor with no source path" do
      editor = Builder.new() |> Builder.paragraph("Body") |> Editor.from_builder!()
      on_exit(fn -> Editor.close(editor) end)

      assert %Editor{source_path: nil} = editor
      assert Editor.page_count!(editor) == 1
      refute Editor.modified?(editor)
    end

    @tag :tmp_dir
    test "save/3 writes the PDF", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "built.pdf")

      assert :ok = Builder.new() |> Builder.paragraph("Saved") |> Builder.save(path)
      assert Document.open!(path) |> Document.text!() =~ "Saved"
    end

    @tag :tmp_dir
    test "to_binary/2 and save/3 close the editor they open, even when saving fails",
         %{tmp_dir: tmp_dir} do
      # A pattern set before the module loads matches nothing, and a process
      # cannot trace its own calls, so a spawned process makes them.
      Code.ensure_loaded!(Editor)
      1 = :erlang.trace_pattern({Editor, :close, 1}, true, [:local])
      on_exit(fn -> :erlang.trace_pattern({Editor, :close, 1}, false, [:local]) end)

      parent = self()
      missing = Path.join([tmp_dir, "missing", "out.pdf"])

      pid =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          Builder.to_binary!(Builder.new())
          send(parent, {:saved, Builder.save(Builder.new(), missing)})
        end)

      :erlang.trace(pid, true, [:call])
      send(pid, :go)

      assert_receive {:saved, {:error, %Error{}}}
      assert_receive {:trace, ^pid, :call, {Editor, :close, [%Editor{}]}}
      assert_receive {:trace, ^pid, :call, {Editor, :close, [%Editor{}]}}
    end
  end

  describe "layout" do
    test "the first baseline sits inside a line box at the top margin" do
      doc = Builder.new() |> Builder.paragraph("Top") |> written()

      assert [first] = baselines(doc, 0)
      assert_in_delta first, baseline(792 - 72, 12), 0.001
    end

    test "lines step by one box and the last box ends at the bottom margin" do
      doc = Builder.new() |> Builder.paragraph(lines(36)) |> written()
      ys = baselines(doc, 0)

      assert length(ys) == 36

      assert ys
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> abs(a - b - 18) < 0.01 end)

      assert_in_delta List.last(ys), baseline(72 + 18, 12), 0.001
      assert Document.page_count!(doc) == 1
    end

    test "a paragraph too long for a page continues at the top of the next" do
      doc = Builder.new() |> Builder.paragraph(lines(40)) |> written()

      assert Document.page_count!(doc) == 2
      assert length(baselines(doc, 1)) == 4
      assert_in_delta hd(baselines(doc, 1)), baseline(792 - 72, 12), 0.001
    end

    test "text wraps inside the left and right margins" do
      text = String.duplicate("The quick brown fox jumps over the lazy dog. ", 30)
      doc = Builder.new() |> Builder.paragraph(text) |> written()
      chars = Document.chars!(doc, 0)

      assert length(baselines(doc, 0)) > 1
      assert Enum.all?(chars, &(&1.bbox.x >= 72 - 0.01))
      assert Enum.all?(chars, &(&1.bbox.x + &1.bbox.width <= 612 - 72 + 0.01))
    end

    test "a newline starts a new line, and an empty one leaves a blank line" do
      doc = Builder.new() |> Builder.paragraph("one\ntwo\n\nfour") |> written()
      [one, two, four] = baselines(doc, 0)

      assert_in_delta one - two, 18, 0.01
      assert_in_delta two - four, 36, 0.01
    end

    test "a word wider than the line is split without losing a character" do
      word = String.duplicate("W", 200)
      doc = Builder.new() |> Builder.paragraph(word) |> written()
      chars = Document.chars!(doc, 0)

      assert length(chars) == 200
      assert length(baselines(doc, 0)) > 1
      assert Enum.all?(chars, &(&1.bbox.x + &1.bbox.width <= 612 - 72 + 0.01))
    end

    test "lines break by the font's real widths, accented letters and punctuation included" do
      # Helvetica advances at 12 points: é 6.672, em dash 12, ' 2.292, on a
      # 468-point line.
      for {char, per_line} <- [{"é", 70}, {"—", 39}, {"'", 204}] do
        doc = Builder.new() |> Builder.paragraph(String.duplicate(char, 300)) |> written()

        counts =
          doc
          |> Document.chars!(0)
          |> Enum.group_by(&Float.round(&1.bbox.y, 3))
          |> Enum.sort_by(fn {y, _} -> -y end)
          |> Enum.map(fn {_, chars} -> length(chars) end)

        assert hd(counts) == per_line, "#{char}: #{inspect(counts)}"
        assert Enum.sum(counts) == 300
      end
    end

    test "a paragraph leaves half its font size after it" do
      doc = Builder.new() |> Builder.paragraph("a") |> Builder.paragraph("b") |> written()
      [a, b] = baselines(doc, 0)

      assert_in_delta a - b, 18 + 6, 0.01
    end

    test "the space after a paragraph is dropped when the next starts a page" do
      doc =
        Builder.new() |> Builder.paragraph(lines(36)) |> Builder.paragraph("next") |> written()

      assert Document.page_count!(doc) == 2
      assert [top] = baselines(doc, 1)
      assert_in_delta top, baseline(792 - 72, 12), 0.001
    end

    test "a paragraph's font size sets its line box" do
      doc = Builder.new() |> Builder.paragraph("Big", font_size: 24) |> written()

      assert [first] = baselines(doc, 0)
      assert_in_delta first, baseline(792 - 72, 24), 0.001
    end

    test "a document's margins, font size and line height apply to every paragraph" do
      doc =
        Builder.new(margin_top: 100, margin_left: 50, font_size: 10, line_height: 2)
        |> Builder.paragraph("one\ntwo")
        |> written()

      [one, two] = baselines(doc, 0)

      assert_in_delta one, baseline(792 - 100, 10, 2), 0.001
      assert_in_delta one - two, 20, 0.01
      assert_in_delta hd(Document.chars!(doc, 0)).bbox.x, 50, 0.01
    end
  end

  describe "page/2" do
    test "the first content starts a page, so a leading page/2 adds no blank one" do
      doc = Builder.new() |> Builder.page(:a4) |> Builder.paragraph("A4") |> written()

      assert Document.page_count!(doc) == 1
      assert %{width: 595.0, height: 842.0} = Page.media_box!(Document.page!(doc, 0))
    end

    test "without a size, the new page repeats the size before it" do
      doc =
        Builder.new()
        |> Builder.page({300, 400})
        |> Builder.paragraph("one")
        |> Builder.page()
        |> Builder.paragraph("two")
        |> written()

      assert Document.page_count!(doc) == 2

      for index <- 0..1 do
        assert %{width: 300.0, height: 400.0} = Page.media_box!(Document.page!(doc, index))
      end

      assert_in_delta hd(baselines(doc, 1)), baseline(400 - 72, 12), 0.001
    end
  end

  describe "refusals" do
    test "a character Helvetica cannot draw is refused, naming the op" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Builder.new()
               |> Builder.paragraph("fine")
               |> Builder.paragraph("Привет")
               |> Builder.to_binary()

      assert message =~ "op 1"
      assert message =~ "U+041F"
    end

    test "a control character is refused like any other undrawable one" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Builder.new() |> Builder.paragraph("bell\u0007") |> Builder.to_binary()

      assert message =~ "U+0007"
    end

    test "whitespace other than a space is laid out as one" do
      doc = Builder.new() |> Builder.paragraph("a\tb") |> written()

      assert Document.text!(doc) =~ "a b"
    end

    test "a character wider than the line is refused, naming it" do
      assert {:error, %Error{reason: :unsupported, message: message}} =
               Builder.new(page_size: {154, 300})
               |> Builder.paragraph("W")
               |> Builder.to_binary()

      assert message =~ ~s("W")
      assert message =~ "10-point line"
    end

    test "from_builder!/1 raises the refusal" do
      assert_raise Error, ~r/U\+041F/, fn ->
        Builder.new() |> Builder.paragraph("Привет") |> Editor.from_builder!()
      end
    end
  end

  describe "malformed arguments raise where they are passed" do
    test "a line taller than the content area" do
      assert_raise ArgumentError, ~r/does not fit the 648.0-point content height/, fn ->
        Builder.new() |> Builder.paragraph("x", font_size: 500)
      end
    end

    test "a page too large for the text's size to be placed precisely" do
      assert_raise ArgumentError, ~r/too large to place 12.0-point text/, fn ->
        Builder.new(page_size: {612, 1.0e9}) |> Builder.paragraph("a\nb\nc\nd")
      end

      assert %Builder{} = Builder.new(page_size: {14_400, 14_400}) |> Builder.paragraph("a")
    end

    test "the check uses the current page's size" do
      builder = Builder.new() |> Builder.page({300, 200})

      assert %Builder{} = Builder.paragraph(builder, "x", font_size: 37)

      assert_raise ArgumentError, ~r/content height/, fn ->
        Builder.paragraph(builder, "x", font_size: 38)
      end
    end

    test "margins that leave no room on the page" do
      assert_raise ArgumentError, ~r/leave no room/, fn ->
        Builder.new(margin_left: 300, margin_right: 312)
      end

      assert_raise ArgumentError, ~r/leave no room/, fn ->
        Builder.new() |> Builder.page({100, 100})
      end
    end

    test "an unknown paper size, or values of the wrong type" do
      assert_raise ArgumentError, ~r/:page_size/, fn -> Builder.new(page_size: :b5) end
      assert_raise ArgumentError, ~r/:title/, fn -> Builder.new(title: 1) end
      assert_raise ArgumentError, ~r/:font_size/, fn -> Builder.new(font_size: "12") end
      assert_raise ArgumentError, ~r/:font_size/, fn -> Builder.new(font_size: 0) end
      assert_raise ArgumentError, ~r/:margin_top/, fn -> Builder.new(margin_top: -1) end
    end

    test "paragraph text that is not a string" do
      assert_raise FunctionClauseError, fn ->
        Builder.paragraph(Builder.new(), untyped(:text))
      end
    end
  end
end
