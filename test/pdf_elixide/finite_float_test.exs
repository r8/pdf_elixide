defmodule PdfElixide.FiniteFloatTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Geometry.Rect

  @fixtures [text: "unbounded_text_matrix.pdf", image: "unbounded_image_matrix.pdf"]

  # f32::MAX read as a double, spelled as its bit pattern rather than as a
  # twenty-digit literal.
  <<f32_max::float-32>> = <<0x7F7FFFFF::32>>
  @f32_max f32_max

  @extractors ~w(chars words text_lines spans tables paths rects lines annotations structured images fonts)a

  # An Erlang float holds neither NaN nor infinity, so encoding one fails the
  # `{:ok, _}` match before the walk. What this adds is the saturation bound
  # the Rect doc promises, where a double-width field could slip past.
  defp finite?(value) when is_float(value), do: abs(value) <= @f32_max
  defp finite?(%_{} = struct), do: struct |> Map.from_struct() |> finite?()
  defp finite?(map) when is_map(map), do: map |> Map.values() |> Enum.all?(&finite?/1)
  defp finite?(list) when is_list(list), do: Enum.all?(list, &finite?/1)
  defp finite?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.all?(&finite?/1)
  defp finite?(_other), do: true

  setup do
    Map.new(@fixtures, fn {key, name} ->
      doc = Document.open!(Path.join([__DIR__, "..", "fixtures", name]))
      on_exit(fn -> Document.close(doc) end)
      {key, doc}
    end)
  end

  # The two value pins are what keep the generated walk below from passing
  # vacuously: only these fixtures produce a value the clamp has to map.
  test "the span's size arrives as the largest finite float", %{text: doc} do
    assert [%{font_size: @f32_max, bbox: %{width: @f32_max, height: @f32_max}}] =
             Document.spans!(doc, 0)
  end

  test "the image's matrix arrives as the largest finite float", %{image: doc} do
    assert [image] = Document.images!(doc)
    assert image.matrix == {@f32_max, 0.0, 0.0, @f32_max, 0.0, 0.0}

    # Upstream transforms the unit square by that same CTM, so both corners land
    # at infinity and the extents come through as `inf - inf`.
    assert image.bbox == %Rect{x: @f32_max, y: @f32_max, width: 0.0, height: 0.0}
  end

  for {key, _name} <- @fixtures, extractor <- @extractors do
    test "#{extractor} returns only finite floats on every arity (#{key})", context do
      doc = Map.fetch!(context, unquote(key))

      assert {:ok, whole} = apply(Document, unquote(extractor), [doc])
      assert {:ok, page} = apply(Document, unquote(extractor), [doc, 0])
      assert {:ok, via_page} = apply(Page, unquote(extractor), [Enum.at(doc, 0)])

      assert finite?(whole)
      assert finite?(page)
      assert finite?(via_page)
    end
  end

  test "search and text succeed too", %{text: doc} do
    assert {:ok, [_ | _] = matches} = Document.search(doc, "1")
    assert finite?(matches)
    assert {:ok, text} = Document.text(doc)
    assert is_binary(text)
  end
end
