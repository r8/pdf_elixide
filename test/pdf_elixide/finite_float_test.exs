defmodule PdfElixide.FiniteFloatTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias PdfElixide.Document
  alias PdfElixide.Document.Page

  @fixture Path.join([__DIR__, "..", "fixtures", "unbounded_text_matrix.pdf"])

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
    doc = Document.open!(@fixture)
    on_exit(fn -> Document.close(doc) end)
    %{doc: doc}
  end

  # The fixture is the only document producing a value the clamp has to map,
  # so this is the assertion that keeps every test below from passing
  # vacuously.
  test "the span's size arrives as the largest finite float", %{doc: doc} do
    assert [%{font_size: @f32_max, bbox: %{width: @f32_max, height: @f32_max}}] =
             Document.spans!(doc, 0)
  end

  for name <- @extractors do
    test "#{name} returns only finite floats on every arity", %{doc: doc} do
      assert {:ok, whole} = apply(Document, unquote(name), [doc])
      assert {:ok, page} = apply(Document, unquote(name), [doc, 0])
      assert {:ok, via_page} = apply(Page, unquote(name), [Enum.at(doc, 0)])

      assert finite?(whole)
      assert finite?(page)
      assert finite?(via_page)
    end
  end

  test "search and text succeed too", %{doc: doc} do
    assert {:ok, [_ | _] = matches} = Document.search(doc, "1")
    assert finite?(matches)
    assert {:ok, text} = Document.text(doc)
    assert is_binary(text)
  end
end
