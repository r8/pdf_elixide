defmodule PdfElixide.Document.Image do
  @moduledoc """
  A raster image (photo, logo, scanned picture) extracted from a PDF page, with
  its zero-based page index, on-page bounding box, and dimensions.

  The pixel data is not carried on the struct; instead `:ref` is a handle to the
  underlying image, and you encode it on demand with `to_binary/2` (bytes) or
  `save/3` (to a file), choosing `:png` or `:jpeg`:

      {:ok, png} = PdfElixide.Document.Image.to_binary(image)              # PNG bytes
      {:ok, jpg} = PdfElixide.Document.Image.to_binary(image, format: :jpeg)
      :ok = PdfElixide.Document.Image.save(image, "out.png")              # format inferred
      :ok = PdfElixide.Document.Image.save(image, "out.jpg", format: :jpeg)

  `:format` reports how the image was *stored* in the PDF — `:jpeg` (a JPEG blob)
  or `:raw` (decoded pixels) — which tells you whether a JPEG encode is lossless:
  for a `:jpeg` source the original bytes are passed through untouched (except
  CMYK JPEGs, which must be re-encoded to RGB), while a `:raw` source is always
  encoded fresh. The `:color_space` and `:bits_per_component` fields describe the
  image as it was stored.

  For the raw stored bytes (rather than an encoded PNG/JPEG), use `data/1`, which
  returns `{:jpeg, bytes}` (the original JPEG blob) or `{:raw, bytes,
  pixel_format}` (bare pixels — not a standalone file; pair them with `:width`,
  `:height`, and `:color_space`, or reach for `to_binary/2` when you want an
  encoded image).

  `data/1`, `to_binary/2` and `save/3` take the handle's lock shared and
  `close/1` takes it exclusively, so encoding one image from several processes
  runs in parallel; see the [Concurrency](guides/concurrency.md) guide.
  """
  alias PdfElixide.Document.Image
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [
    :page,
    :bbox,
    :width,
    :height,
    :format,
    :ref,
    :color_space,
    :bits_per_component,
    :rotation_degrees
  ]

  defstruct @enforce_keys

  @typedoc """
  The stored color space, resolved to an atom. `:icc_based` covers any
  ICC-profile-based space (the component count is dropped).
  """
  @type color_space ::
          :device_rgb
          | :device_gray
          | :device_cmyk
          | :indexed
          | :cal_gray
          | :cal_rgb
          | :lab
          | :icc_based
          | :separation
          | :device_n
          | :pattern

  @typedoc """
  Options for `to_binary/2` and `save/3`.

  An unknown key, or a `:format` other than `:png` or `:jpeg`, raises
  `ArgumentError` naming the offending key; see the "Errors versus exceptions"
  section of `PdfElixide.Error`.
  """
  @type image_opts :: [format: :png | :jpeg]

  @image_opts_keys [:format]

  @typedoc "The layout of raw (uncompressed) pixel data from `data/1`."
  @type pixel_format :: :rgb | :grayscale | :cmyk

  @typedoc """
  The raw stored bytes of an image, from `data/1`: either the original JPEG blob
  or bare decoded pixels with their layout.
  """
  @type raw_data :: {:jpeg, binary()} | {:raw, binary(), pixel_format()}

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          bbox: Rect.t() | nil,
          width: non_neg_integer(),
          height: non_neg_integer(),
          format: :jpeg | :raw,
          ref: reference(),
          color_space: color_space(),
          bits_per_component: non_neg_integer(),
          rotation_degrees: integer()
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        bbox: bbox,
        width: width,
        height: height,
        format: format,
        resource: ref,
        color_space: color_space,
        bits_per_component: bits_per_component,
        rotation_degrees: rotation_degrees
      }) do
    %__MODULE__{
      page: page,
      bbox: bbox,
      width: width,
      height: height,
      format: format,
      ref: ref,
      color_space: color_space,
      bits_per_component: bits_per_component,
      rotation_degrees: rotation_degrees
    }
  end

  @doc """
  Returns the image's raw stored bytes.

  Gives `{:jpeg, bytes}` for a JPEG-stored image (the original DCTDecode blob) or
  `{:raw, bytes, pixel_format}` for one stored as decoded pixels, where
  `pixel_format` is `:rgb`, `:grayscale`, or `:cmyk`. The `:raw` bytes are bare
  pixels, not a standalone image file — use `to_binary/2` when you need an encoded
  PNG or JPEG.
  """
  @spec data(t()) :: {:ok, raw_data()} | {:error, Error.t()}
  def data(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.image_data(ref) end)
  end

  @doc """
  Same as `data/1` but returns the raw data directly, raising on error.
  """
  @spec data!(t()) :: raw_data()
  def data!(%__MODULE__{} = image) do
    data(image) |> Wrap.unwrap!()
  end

  @doc """
  Encodes the image to a binary in the requested format.

  `opts[:format]` is `:png` (the default) or `:jpeg`. For a `:jpeg` source image
  the original bytes are returned untouched (zero loss), except CMYK JPEGs which
  are re-encoded to RGB.

  That pass-through copies the stored blob once, straight into the returned
  binary; the PNG and re-encoding paths hold the encoded image and the binary at
  the same time, so they peak at roughly twice the output size.
  """
  @spec to_binary(t(), image_opts()) :: {:ok, binary()} | {:error, Error.t()}
  def to_binary(%__MODULE__{ref: ref}, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, @image_opts_keys)
    format = validate_format!(Keyword.get(opts, :format, :png))
    Wrap.call(fn -> Native.image_to_binary(ref, format) end)
  end

  @doc """
  Same as `to_binary/2` but returns the binary directly, raising on error.
  """
  @spec to_binary!(t(), image_opts()) :: binary()
  def to_binary!(%__MODULE__{} = image, opts \\ []) when is_list(opts) do
    to_binary(image, opts) |> Wrap.unwrap!()
  end

  @doc """
  Writes the image to a file at the given path.

  The output format is taken from `opts[:format]` when given, otherwise inferred
  from the path extension (`.png` → PNG, `.jpg`/`.jpeg` → JPEG). An unknown
  extension with no `:format` option raises `ArgumentError`.

  The path must be a valid-UTF-8 binary — see the "File paths" section of
  `PdfElixide`.
  """
  @spec save(t(), Path.t(), image_opts()) :: :ok | {:error, Error.t()}
  def save(%__MODULE__{ref: ref}, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    format = save_format!(opts, path)

    case Wrap.call(fn -> Native.image_save(ref, path, format) end) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Same as `save/3` but raises on error.
  """
  @spec save!(t(), Path.t(), image_opts()) :: :ok
  def save!(%__MODULE__{} = image, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    # Local `case` rather than `Wrap.unwrap!/1`: `save/3` answers a bare `:ok`,
    # not `{:ok, value}`, so there is no payload to unwrap.
    case save(image, path, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Releases the image's pixel data immediately.

  The bytes behind `:ref` are normally freed when the BEAM garbage-collects the
  handle; `close/1` frees them now, which is worth doing when walking many large
  images. Calling it is optional and idempotent. It takes the handle's lock
  exclusively, so it waits for an in-flight `data/1`, `to_binary/2` or `save/3`
  on the same image — *immediately* means as soon as the handle is idle, not
  preemptively.

  Afterwards `data/1`, `to_binary/2`, and `save/3` return
  `{:error, %PdfElixide.Error{reason: :closed}}` (bang variants raise it); the
  metadata fields on the struct keep working. An image's lifetime is independent
  of the document it came from — closing either one leaves the other usable.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{ref: ref}), do: Native.image_close(ref)

  @doc """
  Returns whether the image has been released with `close/1`.
  """
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{ref: ref}), do: Native.image_closed(ref)

  # Validates an explicit :format option, returning the atom or raising.
  #
  # The `:png` default of `to_binary/2` has no builder to pin — it is a bare
  # atom argument, not a `NifMap` field, so it is absent from
  # `option_defaults_test.exs`. `document_test.exs`'s "defaults to PNG bytes"
  # magic-byte assertion is what holds it, and `save/3`'s extension inference
  # below is pinned there too; both are load-bearing.
  defp validate_format!(format) when format in [:png, :jpeg], do: format

  defp validate_format!(other) do
    raise ArgumentError, "unsupported image format #{inspect(other)}, expected :png or :jpeg"
  end

  # For save/3: the explicit :format wins, otherwise infer from the extension.
  defp save_format!(opts, path) do
    case opts |> Keyword.validate!(@image_opts_keys) |> Keyword.fetch(:format) do
      {:ok, format} -> validate_format!(format)
      :error -> format_from_ext!(path)
    end
  end

  defp format_from_ext!(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" ->
        :png

      ext when ext in [".jpg", ".jpeg"] ->
        :jpeg

      other ->
        raise ArgumentError,
              "cannot infer image format from #{inspect(other)}; pass format: :png | :jpeg"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(
          %Image{page: page, width: width, height: height, format: format},
          _opts
        ) do
      concat([
        "#PdfElixide.Document.Image<p",
        to_string(page),
        " ",
        to_string(width),
        "x",
        to_string(height),
        " ",
        to_string(format),
        ">"
      ])
    end
  end
end
