defmodule PdfElixide.Document.Path do
  @moduledoc """
  A vector graphics path — a line, curve, rectangle, or filled shape — extracted
  from a PDF page, with its zero-based page index and bounding box.

  The `:operations` field holds the path's drawing commands as a list of flat
  tagged tuples, in stream order:

    * `{:move_to, x, y}` — start a new subpath at `(x, y)`
    * `{:line_to, x, y}` — straight line to `(x, y)`
    * `{:curve_to, c1x, c1y, c2x, c2y, ex, ey}` — cubic Bézier curve (the two
      control points and the endpoint)
    * `{:rectangle, x, y, width, height}` — a complete rectangle subpath
    * `:close_path` — close the current subpath

  A path may be stroked, filled, or both: `:stroke_color` and `:fill_color` are
  each a `PdfElixide.Color` or `nil`. All colors are resolved to DeviceRGB.
  """
  alias PdfElixide.Color
  alias PdfElixide.Geometry.Rect

  @typedoc "A single drawing command in a path's `:operations` list."
  @type operation ::
          {:move_to, float(), float()}
          | {:line_to, float(), float()}
          | {:curve_to, float(), float(), float(), float(), float(), float()}
          | {:rectangle, float(), float(), float(), float()}
          | :close_path

  @enforce_keys [
    :page,
    :bbox,
    :operations,
    :stroke_color,
    :fill_color,
    :stroke_width,
    :line_cap,
    :line_join,
    :dash_pattern,
    :layer
  ]

  defstruct [
    :page,
    :bbox,
    :operations,
    :stroke_color,
    :fill_color,
    :stroke_width,
    :line_cap,
    :line_join,
    :dash_pattern,
    :layer
  ]

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          bbox: Rect.t(),
          operations: [operation()],
          stroke_color: Color.t() | nil,
          fill_color: Color.t() | nil,
          stroke_width: float(),
          line_cap: :butt | :round | :square,
          line_join: :miter | :round | :bevel,
          dash_pattern: {[float()], float()} | nil,
          layer: String.t() | nil
        }

  @doc false
  # Builds a `Path` from the raw map returned by the NIF. Every field already
  # arrives in its final shape (bbox and colors as structs, operations as tagged
  # tuples, cap/join as atoms), so this is a straight pass-through.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        bbox: bbox,
        operations: operations,
        stroke_color: stroke_color,
        fill_color: fill_color,
        stroke_width: stroke_width,
        line_cap: line_cap,
        line_join: line_join,
        dash_pattern: dash_pattern,
        layer: layer
      }) do
    %__MODULE__{
      page: page,
      bbox: bbox,
      operations: operations,
      stroke_color: stroke_color,
      fill_color: fill_color,
      stroke_width: stroke_width,
      line_cap: line_cap,
      line_join: line_join,
      dash_pattern: dash_pattern,
      layer: layer
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document.Path{page: page, operations: operations}, _opts) do
      concat([
        "#PdfElixide.Document.Path<p",
        to_string(page),
        " ",
        to_string(length(operations)),
        " ops>"
      ])
    end
  end
end
