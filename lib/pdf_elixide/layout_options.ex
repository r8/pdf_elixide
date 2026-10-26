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
  @spec non_negative!(label(), term()) :: term()
  def non_negative!(label, value) when is_number(value) and (value < 0 or value > @max_f32) do
    raise ArgumentError,
          "invalid #{label(label)}, expected a non-negative number that fits a " <>
            "32-bit float: #{inspect(value)}"
  end

  def non_negative!(_label, value) when is_number(value), do: value * 1.0
  def non_negative!(_label, value), do: value

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

  def point!(_label, {x, y}) when is_number(x) and is_number(y), do: {x * 1.0, y * 1.0}
  def point!(_label, point), do: point

  @spec fits_f32?(number()) :: boolean()
  def fits_f32?(value), do: abs(value) <= @max_f32

  # Keep a center plus an extent safely within the readable integer range.
  @max_written 1.0e18

  @spec max_written() :: float()
  def max_written, do: @max_written

  @spec writable?(number()) :: boolean()
  def writable?(value), do: abs(value) <= @max_written

  # Dimensions and corners must each fit f32.
  @spec rect!(label(), term()) :: term()
  def rect!(label, %Rect{x: x, y: y, width: width, height: height} = rect)
      when is_number(x) and is_number(y) and is_number(width) and is_number(height) do
    if Enum.any?([x, y, x + width, y + height], &(abs(&1) > @max_f32)) do
      raise ArgumentError,
            "invalid #{label(label)}, expected corners that fit a 32-bit float: " <>
              inspect(rect)
    end

    if Enum.any?([width, height], &(abs(&1) > @max_f32)) do
      raise ArgumentError,
            "invalid #{label(label)}, expected a width and height that fit a " <>
              "32-bit float: #{inspect(rect)}"
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
            "invalid #{label(label)}, expected components from 0.0 to 1.0: #{inspect(color)}"
    end

    color
  end

  def rgb!(_label, color), do: color

  # Text reaches the writer as a Rust string. A value that is not a binary is
  # left to the caller.
  @spec utf8!(label(), term()) :: term()
  def utf8!(label, value) when is_binary(value) do
    if not String.valid?(value) do
      raise ArgumentError,
            "invalid #{label(label)}, expected a UTF-8 string: #{inspect(value)}"
    end

    value
  end

  def utf8!(_label, value), do: value

  # A PDF text string whose characters all fit one byte is written byte for
  # byte, so one starting with a byte-order mark's bytes would be read back in
  # another encoding.
  @byte_order_marks ["þÿ", "ÿþ", "ï»¿"]

  @spec text_string!(label(), term()) :: term()
  def text_string!(label, value) when is_binary(value) do
    value = utf8!(label, value)

    if String.starts_with?(value, @byte_order_marks) do
      raise ArgumentError,
            "invalid #{label(label)}, text starting with #{inspect(@byte_order_marks)} is " <>
              "read back as a byte-order mark, so it cannot be written as given: " <>
              inspect(value)
    end

    value
  end

  def text_string!(_label, value), do: value

  # Form field text, bookmark titles and page label prefixes are written one
  # byte per character where they can be, and PDFDocEncoding gives these bytes
  # other characters, or none.
  @spec field_text!(label(), term(), String.t()) :: term()
  def field_text!(label, value, holder \\ "a form field")

  def field_text!(label, value, holder) when is_binary(value) do
    chars = label |> text_string!(value) |> String.to_charlist()

    case Enum.find(chars, &misread?/1) do
      nil ->
        :ok

      char ->
        raise ArgumentError,
              "invalid #{label(label)}, #{holder} cannot hold " <>
                "#{escape(char)}: a PDF reader decodes it as a different " <>
                "character; use a plain space for a nonbreaking space and leave out soft " <>
                "hyphens and control characters: #{inspect(value)}"
    end

    # Readers take one-byte text that happens to be valid UTF-8 for UTF-8.
    with true <- Enum.all?(chars, &(&1 <= 0xFF)) and Enum.any?(chars, &(&1 >= 0x80)),
         bytes = :erlang.list_to_binary(chars),
         true <- String.valid?(bytes) do
      raise ArgumentError,
            "invalid #{label(label)}, #{holder} cannot hold #{inspect(value)}: " <>
              "written one byte per character, it reads back as #{inspect(bytes)}"
    end

    value
  end

  def field_text!(_label, value, _holder), do: value

  # Every misread character is invisible or blank, and `inspect/1` escapes
  # them only in recent Elixir versions.
  defp escape(char), do: ~s("\\u#{char |> Integer.to_string(16) |> String.pad_leading(4, "0")}")

  defp misread?(char) when char in [?\t, ?\n, ?\r], do: false
  defp misread?(char), do: char < 0x20 or char in 0x7F..0xA0 or char == 0xAD

  @spec to_f32(number()) :: float()
  def to_f32(value) do
    <<rounded::float-32>> = <<value * 1.0::float-32>>
    rounded
  end

  # The printable characters WinAnsiEncoding has a code for: ASCII, Latin-1
  # and the 27 Windows-1252 additions in 0x80-0x9F.
  @win_ansi_extras ~c"€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ"

  # Text a form field draws with its WinAnsi font.
  @spec win_ansi!(label(), term()) :: term()
  def win_ansi!(label, value) when is_binary(value) do
    case label
         |> field_text!(value)
         |> String.to_charlist()
         |> Enum.find(&(not win_ansi?(&1))) do
      nil ->
        value

      char ->
        raise ArgumentError,
              "invalid #{label(label)}, a form field draws its text in a font that has " <>
                "only printable Windows-1252 characters, and #{inspect(<<char::utf8>>)} " <>
                "is not one: #{inspect(value)}"
    end
  end

  def win_ansi!(_label, value), do: value

  defp win_ansi?(char) when char in 0x20..0x7E or char in 0xA0..0xFF, do: true
  defp win_ansi?(char), do: char in @win_ansi_extras

  defp label(key) when is_atom(key), do: inspect(key)
  defp label(name) when is_binary(name), do: name
end
