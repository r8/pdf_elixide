defmodule PdfElixide.Geometry.Rect do
  @moduledoc """
  An axis-aligned rectangle in PDF user-space coordinates.

  PDF user space has a bottom-left origin with y increasing upward, so the
  origin `{x, y}` is the **bottom-left** corner (the minimum x/y); the top edge
  is `y + height` and the right edge is `x + width`. `width` and `height` are
  always non-negative.

  ## Rotated pages

  `to_display_frame/3` and `to_user_space/3` move rectangles between raw user
  space and the displayed frame. See "Rotated pages and extracted geometry" in
  `PdfElixide.Document` for which extractor boxes need conversion.

  One case cannot be inverted: a `/MediaBox` written with reversed corners is
  normalized by `PdfElixide.Document.Page.media_box/1`, but the extractors map
  about the original corners.
  """
  @enforce_keys [:x, :y, :width, :height]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          x: float(),
          y: float(),
          width: float(),
          height: float()
        }

  @doc """
  Maps a rectangle in raw, unrotated user space into the displayed frame of a
  page turned by `rotation`.

  Pass the page's `PdfElixide.Document.Page.rotation/1` and raw, unswapped
  `PdfElixide.Document.Page.media_box/1`. The result is normalized,
  and `to_user_space/3` is the inverse. Only `0`, `90`, `180` and `270` are
  accepted; another rotation raises `FunctionClauseError`.

      iex> box = %PdfElixide.Geometry.Rect{x: 10.0, y: 20.0, width: 612.0, height: 792.0}
      iex> rect = %PdfElixide.Geometry.Rect{x: 82.0, y: 740.0, width: 100.0, height: 24.0}
      iex> PdfElixide.Geometry.Rect.to_display_frame(rect, 90, box)
      %PdfElixide.Geometry.Rect{x: 730.0, y: 460.0, width: 24.0, height: 100.0}

  """
  @spec to_display_frame(t(), PdfElixide.Document.Page.rotation(), t()) :: t()
  def to_display_frame(%__MODULE__{} = rect, rotation, %__MODULE__{} = media_box)
      when rotation in [0, 90, 180, 270] do
    transform(rect, rotation, media_box)
  end

  @doc """
  Maps a rectangle in the displayed frame of a page turned by `rotation` back
  into raw, unrotated user space.

  This is the inverse of `to_display_frame/3` and takes the same raw media box.
  Convert only boxes known to be in the displayed frame; the `PdfElixide.Document`
  geometry section explains how to identify them.
  """
  @spec to_user_space(t(), PdfElixide.Document.Page.rotation(), t()) :: t()
  def to_user_space(%__MODULE__{} = rect, rotation, %__MODULE__{} = media_box)
      when rotation in [0, 90, 180, 270] do
    # Undoing a turn is the opposite turn applied to the displayed page, whose
    # width and height are the raw box's swapped only for 90 and 270.
    transform(rect, rem(360 - rotation, 360), displayed_box(media_box, rotation))
  end

  defp displayed_box(%__MODULE__{width: pw, height: ph} = box, rotation)
       when rotation in [90, 270],
       do: %__MODULE__{box | width: ph, height: pw}

  defp displayed_box(box, _rotation), do: box

  defp transform(
         %__MODULE__{x: x, y: y, width: w, height: h},
         rotation,
         %__MODULE__{x: llx, y: lly, width: pw, height: ph}
       ) do
    {ax, ay} = map(x - llx, y - lly, rotation, pw, ph)
    {bx, by} = map(x - llx + w, y - lly + h, rotation, pw, ph)

    %__MODULE__{
      x: llx + min(ax, bx),
      y: lly + min(ay, by),
      width: abs(ax - bx),
      height: abs(ay - by)
    }
  end

  # The clockwise display rotation of a point relative to the box origin,
  # ISO 32000-1:2008 §8.3.3.
  defp map(x, y, 0, _pw, _ph), do: {x, y}
  defp map(x, y, 90, pw, _ph), do: {y, pw - x}
  defp map(x, y, 180, pw, ph), do: {pw - x, ph - y}
  defp map(x, y, 270, _pw, ph), do: {ph - y, x}
end
