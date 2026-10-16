defmodule PdfElixide.LayoutOptions do
  @moduledoc false

  # Page and type measurements reach the writer as 32-bit floats, so a value
  # out of that range would become an infinity or a zero.

  @max_f32 3.402_823_466_385_288_6e38
  @min_normal_f32 1.175_494_35e-38

  @paper_sizes %{letter: {612, 792}, a4: {595, 842}, legal: {612, 1008}, a3: {842, 1190}}

  @spec paper_sizes() :: %{atom() => {pos_integer(), pos_integer()}}
  def paper_sizes, do: @paper_sizes

  # Range only; a value that is not a number is left to the caller.
  @spec margin!(atom(), term()) :: term()
  def margin!(key, value) when is_number(value) and (value < 0 or value > @max_f32) do
    raise ArgumentError,
          "invalid #{inspect(key)}, expected a non-negative number that fits a " <>
            "32-bit float: #{inspect(value)}"
  end

  def margin!(_key, value), do: value

  # Below the smallest normal f32 a positive value reaches the layout as zero.
  @spec positive!(atom(), term()) :: term()
  def positive!(key, value)
      when is_number(value) and (value < @min_normal_f32 or value > @max_f32) do
    raise ArgumentError,
          "invalid #{inspect(key)}, expected a positive number that fits a " <>
            "32-bit float: #{inspect(value)}"
  end

  def positive!(_key, value), do: value
end
