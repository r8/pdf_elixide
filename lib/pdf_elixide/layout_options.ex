defmodule PdfElixide.LayoutOptions do
  @moduledoc false

  alias PdfElixide.Color.RGB
  alias PdfElixide.Geometry.Rect

  # Page and type measurements reach the writer as 32-bit floats, so a value
  # out of that range would become an infinity or a zero. Numbers come back as
  # floats: native decoding reads an integer only within 64 bits. A label is an
  # option's key (an atom, shown as `:key`) or an argument's name (a string).

  @max_f32 3.402_823_466_385_288_6e38
  @min_normal_f32 1.175_494_35e-38

  @paper_sizes %{letter: {612, 792}, a4: {595, 842}, legal: {612, 1008}, a3: {842, 1190}}

  @spec paper_sizes() :: %{atom() => {pos_integer(), pos_integer()}}
  def paper_sizes, do: @paper_sizes

  @type label :: atom() | String.t()

  # Range only; a value that is not a number is left to the caller.
  @spec margin!(label(), term()) :: term()
  def margin!(label, value) when is_number(value) and (value < 0 or value > @max_f32) do
    raise ArgumentError,
          "invalid #{label(label)}, expected a non-negative number that fits a " <>
            "32-bit float: #{inspect(value)}"
  end

  def margin!(_label, value) when is_number(value), do: value * 1.0
  def margin!(_label, value), do: value

  # Below the smallest normal f32 a positive value reaches the layout as zero.
  @spec positive!(label(), term()) :: term()
  def positive!(label, value)
      when is_number(value) and (value < @min_normal_f32 or value > @max_f32) do
    raise ArgumentError,
          "invalid #{label(label)}, expected a positive number that fits a " <>
            "32-bit float: #{inspect(value)}"
  end

  def positive!(_label, value) when is_number(value), do: value * 1.0
  def positive!(_label, value), do: value

  # Range only; a point of another shape is left to the caller.
  @spec point!(label(), term()) :: term()
  def point!(label, {x, y} = point)
      when is_number(x) and is_number(y) and (abs(x) > @max_f32 or abs(y) > @max_f32) do
    raise ArgumentError,
          "invalid #{label(label)}, expected coordinates that fit a 32-bit float: " <>
            "#{inspect(point)}"
  end

  def point!(_key, point), do: point

  # Dimensions and corners must each fit f32.
  @spec rect!(label(), term()) :: term()
  def rect!(label, %Rect{x: x, y: y, width: width, height: height} = rect)
      when is_number(x) and is_number(y) and is_number(width) and is_number(height) do
    if Enum.any?([x, y, x + width, y + height], &(abs(&1) > @max_f32)) do
      raise ArgumentError,
            "invalid #{label(label)} #{inspect(rect)}: its corners must fit a 32-bit float"
    end

    if Enum.any?([width, height], &(abs(&1) > @max_f32)) do
      raise ArgumentError,
            "invalid #{label(label)} #{inspect(rect)}: its width and height must fit a " <>
              "32-bit float"
    end

    %Rect{x: x * 1.0, y: y * 1.0, width: width * 1.0, height: height * 1.0}
  end

  def rect!(_label, rect), do: rect

  # The writer clamps a component into range rather than reporting it, so the
  # range is checked here. Anything but an `RGB` struct is left to the caller.
  @spec rgb!(label(), term()) :: term()
  def rgb!(label, %RGB{r: r, g: g, b: b} = color) do
    unless Enum.all?([r, g, b], &(is_number(&1) and &1 >= 0 and &1 <= 1)) do
      raise ArgumentError,
            "invalid #{label(label)} #{inspect(color)}: each component must be a number " <>
              "between 0.0 and 1.0"
    end

    color
  end

  def rgb!(_label, color), do: color

  defp label(key) when is_atom(key), do: inspect(key)
  defp label(name) when is_binary(name), do: name
end
