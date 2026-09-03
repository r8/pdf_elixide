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

  `:matrix` is the transformation the image was drawn under (`t:matrix/0`). For
  an image the page paints directly, `:bbox` is that matrix applied to the unit
  square and squared up to the axes — so for a rotated or skewed image the box is
  looser than the placement — and `:rotation_degrees` is the angle the matrix
  turns through. An image painted inside a Form XObject is the exception, and
  `t:matrix/0` says how the three disagree there.

  `data/1`, `to_binary/2` and `save/3` take the handle's lock shared and
  `close/1` takes it exclusively, so encoding one image from several processes
  runs in parallel; see the [Concurrency](guides/concurrency.md) guide.

  ## Which images are extracted

  **An image is left out of the list rather than reported as an error** when
  it is under 8 pixels wide or tall, or when its stored encoding cannot be
  decoded. Flate, LZW, run-length, CCITT fax, JPEG and JPEG 2000
  (`/JPXDecode`) decode; JBIG2 does not, nor does a JPEG 2000 codestream whose
  component count is anything but 1, 3 or 4. A JPEG 2000 image arrives as
  `:raw` pixels whose `pixel_format` comes from its codestream rather than
  from the colour space the PDF declares for it.

  `PdfElixide.Document.images/1` and `PdfElixide.Document.images/2` return
  `{:ok, list}` either way, so a page whose only picture was skipped is
  indistinguishable from a page with none — nothing is raised and nothing is
  logged.

  **JPEG 2000 transparency is the one case that comes back wrong rather than
  missing.** The alpha channel declared through `/SMaskInData` is ignored, so
  a four-component codestream carrying RGB plus alpha is reported as `:cmyk`,
  and `to_binary/2` and `save/3` *succeed* with wrong colours instead of
  failing. To spot one, compare `:color_space` against `data/1`'s
  `pixel_format`: a `:device_rgb` image whose pixels are `:cmyk` is one. (An
  `:indexed` image reports `:rgb` pixels too, but correctly — its palette
  really is expanded to RGB.)

  A page that cannot be reached, or whose `/Resources` cannot be resolved,
  does return `{:error, t:PdfElixide.Error.t/0}`. A page whose content stream
  fails to parse does not: it returns `{:ok, []}`, like a page with no images.
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
    :rotation_degrees,
    :matrix
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

  @typedoc """
  The transformation in effect where the image is painted, `{a, b, c, d, e, f}`.

  Every `cm` operator in scope multiplied together, not the operands of any one
  of them: a page drawing under `2 0 0 2 10 10 cm` and then `3 0 0 3 1 1 cm`
  reports their product, `{6.0, 0.0, 0.0, 6.0, 12.0, 12.0}`.

  The image occupies the unit square mapped through it, so
  `{w, 0.0, 0.0, h, x, y}` is an unrotated image `w` by `h` points with its
  bottom-left corner at `(x, y)`. An image drawn under no transformation reports
  the identity `{1.0, 0.0, 0.0, 1.0, 0.0, 0.0}`; it is never `nil`.

  ## What it does not include

  The matrix is in default PDF user space, so a page's rotation is not folded
  into it — read `PdfElixide.Document.Page.rotation/1` to place the image as a
  viewer displays it.

  **An image painted inside a Form XObject reports the transformation of the
  form's own frame, not of the page.** The form's `/Matrix` and the `cm`
  operators inside it are included; the `cm` that preceded the form's own
  painting is not. `:bbox` does include it, so for such an image `:matrix` and
  `:bbox` describe different frames and `:rotation_degrees` is the angle within
  the form. `:bbox` is the one to trust for where the image lands on the page.
  """
  @type matrix :: {float(), float(), float(), float(), float(), float()}

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
          rotation_degrees: integer(),
          matrix: matrix()
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
        rotation_degrees: rotation_degrees,
        matrix: matrix
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
      rotation_degrees: rotation_degrees,
      matrix: matrix
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

  Returns the bytes rather than writing them, so no path is involved; use
  `save/3` to write a file.
  """
  @spec to_binary(t(), image_opts()) :: {:ok, binary()} | {:error, Error.t()}
  def to_binary(%__MODULE__{ref: ref}, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, @image_opts_keys)
    format = validate_format!(Keyword.get(opts, :format, :png))
    Wrap.call(fn -> Native.image_to_binary(ref, format) end)
  end

  @doc """
  Same as `to_binary/2` but returns the binary directly, raising on error.

  Returns the bytes rather than writing them, so no path is involved; use
  `save!/3` to write a file.
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

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
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

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
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
  Releases the image's pixel data without waiting for garbage collection.

  The bytes behind `:ref` are normally freed when the BEAM garbage-collects the
  handle; `close/1` frees them now, which is worth doing when walking many large
  images. Calling it is optional and idempotent. It takes the handle's lock
  exclusively, so it waits for an in-flight `data/1`, `to_binary/2` or `save/3`
  on the same image and releases the data as soon as the handle is idle, not
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

  defp validate_format!(format) when format in [:png, :jpeg], do: format

  defp validate_format!(other) do
    raise ArgumentError, "unsupported image format #{inspect(other)}, expected :png or :jpeg"
  end

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
