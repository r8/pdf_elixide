defmodule PdfElixide.Geometry.RectTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import PdfElixide.Untyped

  alias PdfElixide.Document
  alias PdfElixide.Document.Page
  alias PdfElixide.Geometry.Rect

  @rotation_pdf Path.join([__DIR__, "..", "..", "fixtures", "rotation.pdf"])

  # A media box off the origin, so a mapping that forgot the offset is caught.
  @box %Rect{x: 10.0, y: 20.0, width: 612.0, height: 792.0}
  @rect %Rect{x: 82.0, y: 740.0, width: 100.0, height: 24.0}

  @displayed %{
    0 => @rect,
    90 => %Rect{x: 730.0, y: 460.0, width: 24.0, height: 100.0},
    180 => %Rect{x: 450.0, y: 68.0, width: 100.0, height: 24.0},
    270 => %Rect{x: 58.0, y: 92.0, width: 24.0, height: 100.0}
  }

  describe "to_display_frame/3" do
    test "0 is the identity" do
      assert Rect.to_display_frame(@rect, 0, @box) == @rect
    end

    for rotation <- [90, 180, 270] do
      test "turns a rectangle by #{rotation} degrees about the media box" do
        assert Rect.to_display_frame(@rect, unquote(rotation), @box) ==
                 @displayed[unquote(rotation)]
      end
    end

    test "normalizes a reversed rectangle at every rotation" do
      reversed = %Rect{x: 182.0, y: 764.0, width: -100.0, height: -24.0}

      for rotation <- [0, 90, 180, 270] do
        assert Rect.to_display_frame(reversed, rotation, @box) == @displayed[rotation]
      end
    end

    test "rejects a rotation that is not a multiple of 90" do
      assert_raise FunctionClauseError, fn ->
        Rect.to_display_frame(@rect, untyped(45), @box)
      end
    end
  end

  describe "to_user_space/3" do
    for rotation <- [0, 90, 180, 270] do
      test "undoes a #{rotation}-degree turn" do
        assert Rect.to_user_space(@displayed[unquote(rotation)], unquote(rotation), @box) ==
                 @rect
      end
    end

    test "rejects a rotation that is not a multiple of 90" do
      assert_raise FunctionClauseError, fn ->
        Rect.to_user_space(@rect, untyped(45), @box)
      end
    end
  end

  describe "the two are inverses" do
    # The coordinates are dyadic, so both compositions are exact.
    for rotation <- [0, 90, 180, 270] do
      test "in both orders at #{rotation} degrees" do
        rotation = unquote(rotation)

        assert @rect
               |> Rect.to_display_frame(rotation, @box)
               |> Rect.to_user_space(rotation, @box) == @rect

        assert @displayed[rotation]
               |> Rect.to_user_space(rotation, @box)
               |> Rect.to_display_frame(rotation, @box) == @displayed[rotation]
      end
    end
  end

  describe "against a rotated page" do
    # Upstream computes the displayed box in f32 and the helper in f64.
    @delta 0.001

    test "a search match on a 180-degree page maps back onto the span it covers" do
      doc = Document.open!(@rotation_pdf)
      page = Document.page!(doc, 1)
      assert Page.rotation!(page) == 180
      box = Page.media_box!(page)

      assert [span] = Document.spans!(doc, 1)
      assert [match] = Document.search!(doc, span.text, 1)
      refute match.bbox == span.bbox

      assert_same(Rect.to_user_space(match.bbox, 180, box), span.bbox)
      assert_same(Rect.to_display_frame(span.bbox, 180, box), match.bbox)
    end
  end

  defp assert_same(%Rect{} = left, %Rect{} = right) do
    for key <- [:x, :y, :width, :height] do
      assert_in_delta Map.fetch!(left, key), Map.fetch!(right, key), @delta
    end
  end
end
