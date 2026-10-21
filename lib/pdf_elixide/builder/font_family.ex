defmodule PdfElixide.Builder.FontFamily do
  @moduledoc """
  A font family to embed in a document built with `PdfElixide.Builder`.

  Bind one to a variable and pass it wherever the builder takes a `:font`:

      noto =
        PdfElixide.Builder.FontFamily.new(
          regular: File.read!("NotoSans-Regular.ttf"),
          bold: File.read!("NotoSans-Bold.ttf")
        )

      PdfElixide.Builder.new(font: noto)
      |> PdfElixide.Builder.paragraph(["Звіт ", {"готовий", bold: true}])
      |> PdfElixide.Builder.save!("report.pdf")

  Pass single-face TrueType (`.ttf`) or OpenType (`.otf`) font bytes.
  Only `:regular` is required. Missing styles are refused at build time;
  bold italic requires its own `:bold_italic` face.

  Invalid fonts and font collections (`.ttc`) are refused at build time as
  `{:error, %PdfElixide.Error{reason: :unsupported}}`.
  """

  @enforce_keys [:id, :regular, :bold, :italic, :bold_italic]
  defstruct @enforce_keys

  @typedoc """
  A font family.

  Its fields are internal: build one with `new/1` rather than constructing or
  reading the struct directly.
  """
  @type t :: %__MODULE__{
          id: reference(),
          regular: binary(),
          bold: binary() | nil,
          italic: binary() | nil,
          bold_italic: binary() | nil
        }

  @typedoc """
  Options accepted by `new/1`: `:regular`, `:bold`, `:italic` and
  `:bold_italic`, each the bytes of one font. `:regular` is required; the
  others default to `nil`, meaning the family has no such face.

  An unknown key, a missing `:regular`, or a face that is not a binary raises
  `ArgumentError` naming the key.
  """
  @type new_opts :: [
          regular: binary(),
          bold: binary() | nil,
          italic: binary() | nil,
          bold_italic: binary() | nil
        ]

  @new_opts_keys [:regular, :bold, :italic, :bold_italic]

  @doc """
  Builds a font family from the bytes of its faces.

  See `t:new_opts/0` for the options.
  """
  @spec new(new_opts()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @new_opts_keys)

    regular =
      case Keyword.get(opts, :regular) do
        nil ->
          raise ArgumentError,
                "invalid :regular, a font family needs a regular face, so it cannot be missing"

        face ->
          face!(:regular, face)
      end

    %__MODULE__{
      id: make_ref(),
      regular: regular,
      bold: face!(:bold, Keyword.get(opts, :bold)),
      italic: face!(:italic, Keyword.get(opts, :italic)),
      bold_italic: face!(:bold_italic, Keyword.get(opts, :bold_italic))
    }
  end

  defp face!(_key, nil), do: nil
  defp face!(_key, bytes) when is_binary(bytes), do: bytes

  defp face!(key, other) do
    raise ArgumentError,
          "invalid #{inspect(key)}, expected the bytes of a font: #{inspect(other)}"
  end

  defimpl Inspect do
    def inspect(family, _opts) do
      faces =
        for key <- [:regular, :bold, :italic, :bold_italic],
            bytes = Map.fetch!(family, key),
            bytes != nil,
            do: "#{key}: #{byte_size(bytes)} bytes"

      "#PdfElixide.Builder.FontFamily<#{Enum.join(faces, ", ")}>"
    end
  end
end
