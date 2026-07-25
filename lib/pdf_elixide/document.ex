defmodule PdfElixide.Document do
  @moduledoc """
  Read-only representation of a PDF document.
  """

  alias PdfElixide.Document.Annotation
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Font
  alias PdfElixide.Document.Image
  alias PdfElixide.Document.Metadata
  alias PdfElixide.Document.OutlineItem
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.Path
  alias PdfElixide.Document.Permissions
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Document.XmpMetadata
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:ref, :version]
  defstruct [:ref, :version, :source_path]

  @type t :: %__MODULE__{
          ref: reference(),
          version: {non_neg_integer(), non_neg_integer()},
          source_path: Path.t() | nil
        }

  @typedoc """
  Options accepted by `open/2`, `open!/2`, `from_binary/2`, and `from_binary!/2`.

    * `:password` — password used to authenticate against an encrypted
      PDF. When the password is wrong, the call returns
      `{:error, %PdfElixide.Error{reason: :wrong_password}}` (or raises,
      for the bang variants). When omitted or `nil`, no authentication
      attempt is made beyond `pdf_oxide`'s built-in empty-password try.

  To *check* a password against an already-open document without treating a
  wrong one as an error, use `authenticate/2`, which returns `{:ok, false}`
  rather than a `:wrong_password` error.
  """
  @type open_opts :: [password: String.t()]

  @doc """
  Opens a PDF document from the specified file path.
  """
  @spec open(Path.t(), open_opts()) :: {:ok, t()} | {:error, Error.t()}
  def open(path, opts \\ []) when is_binary(path) and is_list(opts) do
    options = build_open_options(opts)

    with {:ok, ref} <- Wrap.call(fn -> Native.document_open(path, options) end),
         {:ok, version} <- Wrap.call(fn -> Native.document_version(ref) end) do
      {:ok, %__MODULE__{ref: ref, version: version, source_path: path}}
    end
  end

  @doc """
  Opens a PDF document from the specified file path, raising an error if it fails.
  """
  @spec open!(Path.t(), open_opts()) :: t()
  def open!(path, opts \\ []) when is_binary(path) and is_list(opts) do
    case open(path, opts) do
      {:ok, doc} -> doc
      {:error, error} -> raise error
    end
  end

  @doc """
  Opens a PDF document from the given binary data.
  """
  @spec from_binary(binary(), open_opts()) :: {:ok, t()} | {:error, Error.t()}
  def from_binary(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    options = build_open_options(opts)

    with {:ok, ref} <- Wrap.call(fn -> Native.document_from_bytes(bytes, options) end),
         {:ok, version} <- Wrap.call(fn -> Native.document_version(ref) end) do
      {:ok, %__MODULE__{ref: ref, version: version, source_path: nil}}
    end
  end

  @doc """
  Opens a PDF document from the given binary data, raising an error if it fails.
  """
  @spec from_binary!(binary(), open_opts()) :: t()
  def from_binary!(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    case from_binary(bytes, opts) do
      {:ok, doc} -> doc
      {:error, error} -> raise error
    end
  end

  defp build_open_options(opts) do
    %{password: Keyword.get(opts, :password)}
  end

  @doc """
  Returns the PDF specification version of the given document as a `{major, minor}` tuple.
  """
  @spec version(t()) :: {non_neg_integer(), non_neg_integer()}
  def version(%__MODULE__{version: v}), do: v

  @doc """
  Returns the file path from which the document was loaded, or `nil` if it was loaded from binary data.
  """
  @spec source_path(t()) :: Path.t() | nil
  def source_path(%__MODULE__{source_path: p}), do: p

  @doc """
  Releases the document's native memory immediately.

  A document holds its PDF data in memory on the Rust side, which is normally
  freed only when the BEAM garbage-collects the handle — invisible to the VM's
  memory accounting, so nothing pressures it to happen promptly. `close/1` frees
  it now, which matters for long-lived processes that open many documents.
  Calling it is optional and idempotent.

  Afterwards, functions that read the document return
  `{:error, %PdfElixide.Error{reason: :closed}}`, and their bang variants raise
  it. `version/1` and `source_path/1` keep working, since they read the struct
  rather than the native handle, and any `PdfElixide.Document.Image` or
  `PdfElixide.Document.Font` handles already extracted from the document remain
  valid — they own their data independently.

      doc = PdfElixide.Document.open!("sample.pdf")
      text = PdfElixide.Document.text!(doc, 0)
      :ok = PdfElixide.Document.close(doc)

  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{ref: ref}), do: Native.document_close(ref)

  @doc """
  Returns whether the document has been released with `close/1`.
  """
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{ref: ref}), do: Native.document_closed(ref)

  @doc """
  Returns the number of pages in the given PDF document.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def page_count(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_page_count(ref) end)
  end

  @doc """
  Returns the number of pages in the given PDF document, raising an error if it fails.
  """
  @spec page_count!(t()) :: non_neg_integer()
  def page_count!(doc) do
    case page_count(doc) do
      {:ok, count} -> count
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns whether the PDF document is a Tagged PDF with a structure tree.
  """
  @spec has_structure_tree?(t()) :: boolean()
  def has_structure_tree?(%__MODULE__{ref: ref}) do
    predicate!(fn -> Native.document_has_structure_tree(ref) end)
  end

  @doc """
  Returns whether the PDF document contains XFA (XML Forms Architecture) form data.
  """
  @spec has_xfa?(t()) :: boolean()
  def has_xfa?(%__MODULE__{ref: ref}) do
    predicate!(fn -> Native.document_has_xfa(ref) end)
  end

  @doc """
  Returns whether the PDF document is encrypted.
  """
  @spec encrypted?(t()) :: boolean()
  def encrypted?(%__MODULE__{ref: ref}) do
    predicate!(fn -> Native.document_is_encrypted(ref) end)
  end

  # Predicates return a bare boolean, so a NIF failure (a closed document, a
  # poisoned lock) has nowhere to go but a raise — as the bang variants do.
  defp predicate!(fun) do
    case Wrap.call(fun) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc """
  Authenticates against the document's encryption with the given password.

  Returns `{:ok, true}` if authentication succeeded (or the PDF is not encrypted),
  `{:ok, false}` if the password was wrong, or `{:error, reason}` on a PDF/crypto error.

  Unlike `open/2`'s `:password` option — where a wrong password is an
  `{:error, %PdfElixide.Error{reason: :wrong_password}}` because the document
  cannot be produced — this is a password *check*, so a wrong password is a
  normal `{:ok, false}` result and `{:error, _}` is reserved for PDF/crypto
  errors.
  """
  @spec authenticate(t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def authenticate(%__MODULE__{ref: ref}, password) when is_binary(password) do
    Wrap.call(fn -> Native.document_authenticate(ref, password) end)
  end

  @doc """
  Same as `authenticate/2` but raises on error.

  Still returns `false` (does not raise) for a wrong password.
  """
  @spec authenticate!(t(), String.t()) :: boolean()
  def authenticate!(doc, password) when is_binary(password) do
    case authenticate(doc, password) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the document's Info dictionary metadata (title, author, dates, etc.).

  Always returns a `PdfElixide.Document.Metadata` struct; a document with no
  `/Info` dictionary yields one with every field `nil`. For XMP metadata, see
  `xmp_metadata/1`.
  """
  @spec metadata(t()) :: {:ok, Metadata.t()} | {:error, Error.t()}
  def metadata(%__MODULE__{ref: ref}) do
    with {:ok, map} <- Wrap.call(fn -> Native.document_info(ref) end) do
      {:ok, Metadata.from_nif(map)}
    end
  end

  @doc """
  Reads the document's Info dictionary metadata, raising an error if it fails.
  """
  @spec metadata!(t()) :: Metadata.t()
  def metadata!(%__MODULE__{} = doc) do
    case metadata(doc) do
      {:ok, metadata} -> metadata
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the document's XMP (Extensible Metadata Platform) metadata.

  Returns `{:ok, %PdfElixide.Document.XmpMetadata{}}` when the document carries
  an XMP packet, or `{:ok, nil}` when it does not. For the classic Info
  dictionary metadata, see `metadata/1`.
  """
  @spec xmp_metadata(t()) :: {:ok, XmpMetadata.t() | nil} | {:error, Error.t()}
  def xmp_metadata(%__MODULE__{ref: ref}) do
    with {:ok, map} <- Wrap.call(fn -> Native.document_xmp_metadata(ref) end) do
      {:ok, map && XmpMetadata.from_nif(map)}
    end
  end

  @doc """
  Reads the document's XMP metadata, raising an error if it fails.
  """
  @spec xmp_metadata!(t()) :: XmpMetadata.t() | nil
  def xmp_metadata!(%__MODULE__{} = doc) do
    case xmp_metadata(doc) do
      {:ok, xmp} -> xmp
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the document's `/P` permission flags.

  Returns `{:ok, %PdfElixide.Document.Permissions{}}` for an encrypted document,
  or `{:ok, nil}` when the document is not encrypted (no permission dictionary).

  Per the PDF specification these flags are advisory; see
  `PdfElixide.Document.Permissions`.
  """
  @spec permissions(t()) :: {:ok, Permissions.t() | nil} | {:error, Error.t()}
  def permissions(%__MODULE__{ref: ref}) do
    with {:ok, map} <- Wrap.call(fn -> Native.document_permissions(ref) end) do
      {:ok, map && Permissions.from_nif(map)}
    end
  end

  @doc """
  Reads the document's permission flags, raising an error if it fails.
  """
  @spec permissions!(t()) :: Permissions.t() | nil
  def permissions!(%__MODULE__{} = doc) do
    case permissions(doc) do
      {:ok, permissions} -> permissions
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the document's logical page labels — one per page, in page order.

  Page labels are the human-facing page numbers a PDF may define (e.g. `"i"`,
  `"ii"`, `"iii"`, `"1"`, `"2"`), independent of the zero-based physical page
  index. Pages outside any declared label range fall back to their decimal page
  number, so the returned list always has one entry per page.

  See also `PdfElixide.Document.Page.label/1` for a single page's label.
  """
  @spec page_labels(t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def page_labels(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_page_labels(ref) end)
  end

  @doc """
  Returns the document's logical page labels, raising an error if it fails.
  """
  @spec page_labels!(t()) :: [String.t()]
  def page_labels!(%__MODULE__{} = doc) do
    case page_labels(doc) do
      {:ok, labels} -> labels
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text content of the whole document.

  Returns every page's text concatenated in order, separated by a form-feed
  (`\\f`) page separator.
  """
  @spec text(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def text(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_extract_all_text(ref) end)
  end

  @doc """
  Extracts the text content of the whole document, raising an error if it fails.
  """
  @spec text!(t()) :: String.t()
  def text!(%__MODULE__{} = doc) do
    case text(doc) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text content of the page at the given zero-based index.
  """
  @spec text(t(), non_neg_integer()) :: {:ok, String.t()} | {:error, Error.t()}
  def text(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    Wrap.call(fn -> Native.document_extract_text(ref, page_index) end)
  end

  @doc """
  Extracts the text content of the page at the given zero-based index,
  raising an error if it fails.
  """
  @spec text!(t(), non_neg_integer()) :: String.t()
  def text!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case text(doc, page_index) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  @typedoc """
  Options accepted by the `to_markdown` and `to_markdown!` functions.

    * `:detect_headings` — cluster font sizes to emit `#` headings instead
      of plain paragraphs. Defaults to `true`.
    * `:extract_tables` — detect tables and render them as Markdown
      tables. Defaults to `true`.
    * `:include_images` — emit `![](…)` image syntax. Defaults to `false`,
      since embedded images can add hundreds of kilobytes per page.
    * `:embed_images` — when `true`, images are inlined as base64 data
      URIs and `:image_output_dir` is ignored. When `false`, they are
      written to `:image_output_dir` and referenced by path — and if that
      option is `nil`, no image is emitted at all. Only applies when
      `:include_images` is `true`. Defaults to `true`.
    * `:image_output_dir` — directory to write extracted images to, used
      only when `:include_images` is `true` and `:embed_images` is
      `false`. It is created if missing, and one that cannot be created
      is an `:io` error. The writes themselves are best-effort: upstream
      drops an image that fails to encode or write, so a successful call
      does not guarantee every image reached disk. Defaults to `nil`.
    * `:include_form_fields` — inline AcroForm field values at their
      positions on the page. Defaults to `true`.
    * `:strip_running_headers_footers` — drop text lines that repeat in
      the top/bottom band of a majority of pages. Defaults to `false`.
    * `:expand_ligatures` — expand `U+FB00`–`U+FB06` ligatures to their
      component letters (`ﬁ` to `fi`, and so on). Defaults to `false`.
    * `:annotate_skipped_pages` — emit a block quote naming any page that
      is a scan with no usable text layer, rather than rendering it blank.
      Defaults to `true`.
    * `:max_image_pixels` — skip images whose width times height exceeds
      this count. `nil` means `pdf_oxide`'s own 16 MP limit, not "no
      limit" — pass a large integer to lift it, or `0` to skip every
      image. Defaults to `nil`.
    * `:reading_order` — how text blocks are ordered:
      `:structure_tree` (follow a tagged PDF's structure tree, falling
      back to an XY-cut), `:column_aware`, or `:top_to_bottom`. Defaults
      to `:structure_tree`.
    * `:bold_markers` — `:conservative` applies `**` only to
      content-bearing text; `:aggressive` also wraps whitespace-only
      spans. Defaults to `:conservative`.

  Defaults mirror `pdf_oxide`'s `ConversionOptions::default()`, so calling
  `to_markdown/1` is equivalent to `to_markdown/2` with no options.
  """
  @type markdown_opts :: [
          detect_headings: boolean(),
          extract_tables: boolean(),
          include_images: boolean(),
          embed_images: boolean(),
          image_output_dir: Path.t() | nil,
          include_form_fields: boolean(),
          strip_running_headers_footers: boolean(),
          expand_ligatures: boolean(),
          annotate_skipped_pages: boolean(),
          max_image_pixels: non_neg_integer() | nil,
          reading_order: :structure_tree | :column_aware | :top_to_bottom,
          bold_markers: :conservative | :aggressive
        ]

  @doc """
  Converts the document to Markdown.

  With a keyword list (or nothing) as the second argument, converts the
  whole document, joining pages with a `---` thematic break — note that
  this differs from `text/1`, which uses a form feed. With a zero-based
  integer, converts that single page instead.

      Document.to_markdown(doc)
      Document.to_markdown(doc, detect_headings: false)
      Document.to_markdown(doc, 0)

  See `t:markdown_opts/0` for the available options.
  """
  @spec to_markdown(t()) :: {:ok, String.t()} | {:error, Error.t()}
  @spec to_markdown(t(), markdown_opts() | non_neg_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_markdown(doc, page_index_or_opts \\ [])

  def to_markdown(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_markdown_options(opts)
    Wrap.call(fn -> call_markdown_all(ref, options) end)
  end

  def to_markdown(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_markdown(doc, page_index, [])
  end

  @doc """
  Converts the document to Markdown, raising an error if it fails.
  """
  @spec to_markdown!(t()) :: String.t()
  @spec to_markdown!(t(), markdown_opts() | non_neg_integer()) :: String.t()
  def to_markdown!(doc, page_index_or_opts \\ [])

  def to_markdown!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case to_markdown(doc, opts) do
      {:ok, markdown} -> markdown
      {:error, error} -> raise error
    end
  end

  def to_markdown!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_markdown!(doc, page_index, [])
  end

  @doc """
  Converts the page at the given zero-based index to Markdown.

  See `t:markdown_opts/0` for the available options.
  """
  @spec to_markdown(t(), non_neg_integer(), markdown_opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_markdown(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_markdown_options(opts)
    Wrap.call(fn -> call_markdown(ref, page_index, options) end)
  end

  @doc """
  Converts the page at the given zero-based index to Markdown, raising an
  error if it fails.
  """
  @spec to_markdown!(t(), non_neg_integer(), markdown_opts()) :: String.t()
  def to_markdown!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case to_markdown(doc, page_index, opts) do
      {:ok, markdown} -> markdown
      {:error, error} -> raise error
    end
  end

  defp build_markdown_options(opts) do
    %{
      detect_headings: Keyword.get(opts, :detect_headings, true),
      extract_tables: Keyword.get(opts, :extract_tables, true),
      include_images: Keyword.get(opts, :include_images, false),
      embed_images: Keyword.get(opts, :embed_images, true),
      image_output_dir: Keyword.get(opts, :image_output_dir),
      include_form_fields: Keyword.get(opts, :include_form_fields, true),
      strip_running_headers_footers: Keyword.get(opts, :strip_running_headers_footers, false),
      expand_ligatures: Keyword.get(opts, :expand_ligatures, false),
      annotate_skipped_pages: Keyword.get(opts, :annotate_skipped_pages, true),
      max_image_pixels: Keyword.get(opts, :max_image_pixels),
      reading_order: Keyword.get(opts, :reading_order, :structure_tree),
      bold_markers: Keyword.get(opts, :bold_markers, :conservative)
    }
  end

  # Conversion is CPU-bound except when it writes images to disk, so it has a
  # dirty-CPU and a dirty-IO NIF and picks between them here — the same split as
  # `Document.Image.to_binary/2` and `save/3`.
  defp call_markdown_all(ref, options) do
    if writes_images?(options),
      do: Native.document_to_markdown_all_to_dir(ref, options),
      else: Native.document_to_markdown_all(ref, options)
  end

  defp call_markdown(ref, page_index, options) do
    if writes_images?(options),
      do: Native.document_to_markdown_to_dir(ref, page_index, options),
      else: Native.document_to_markdown(ref, page_index, options)
  end

  defp writes_images?(%{include_images: true, embed_images: false, image_output_dir: dir})
       when is_binary(dir),
       do: true

  defp writes_images?(_options), do: false

  @doc """
  Extracts the words of the whole document.

  Returns every page's words concatenated into a single flat list, in page
  order. Each word carries its bounding box and font metadata as a
  `PdfElixide.Document.Word` struct.
  """
  @spec words(t()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  def words(%__MODULE__{ref: ref}) do
    with {:ok, words} <- Wrap.call(fn -> Native.document_all_words(ref) end) do
      {:ok, Enum.map(words, &Word.from_nif/1)}
    end
  end

  @doc """
  Extracts the words of the whole document, raising an error if it fails.
  """
  @spec words!(t()) :: [Word.t()]
  def words!(%__MODULE__{} = doc) do
    case words(doc) do
      {:ok, words} -> words
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the words of the page at the given zero-based index.

  Each word carries its bounding box and font metadata as a
  `PdfElixide.Document.Word` struct.
  """
  @spec words(t(), non_neg_integer()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  def words(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, words} <- Wrap.call(fn -> Native.document_words(ref, page_index) end) do
      {:ok, Enum.map(words, &Word.from_nif/1)}
    end
  end

  @doc """
  Extracts the words of the page at the given zero-based index, raising an error
  if it fails.
  """
  @spec words!(t(), non_neg_integer()) :: [Word.t()]
  def words!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case words(doc, page_index) do
      {:ok, words} -> words
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text lines of the whole document.

  Returns every page's lines concatenated into a single flat list, in page
  order. Each line carries its bounding box and constituent words as a
  `PdfElixide.Document.TextLine` struct.
  """
  @spec text_lines(t()) :: {:ok, [TextLine.t()]} | {:error, Error.t()}
  def text_lines(%__MODULE__{ref: ref}) do
    with {:ok, lines} <- Wrap.call(fn -> Native.document_all_text_lines(ref) end) do
      {:ok, Enum.map(lines, &TextLine.from_nif/1)}
    end
  end

  @doc """
  Extracts the text lines of the whole document, raising an error if it fails.
  """
  @spec text_lines!(t()) :: [TextLine.t()]
  def text_lines!(%__MODULE__{} = doc) do
    case text_lines(doc) do
      {:ok, lines} -> lines
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text lines of the page at the given zero-based index.

  Each line carries its bounding box and constituent words as a
  `PdfElixide.Document.TextLine` struct.
  """
  @spec text_lines(t(), non_neg_integer()) :: {:ok, [TextLine.t()]} | {:error, Error.t()}
  def text_lines(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, lines} <- Wrap.call(fn -> Native.document_text_lines(ref, page_index) end) do
      {:ok, Enum.map(lines, &TextLine.from_nif/1)}
    end
  end

  @doc """
  Extracts the text lines of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec text_lines!(t(), non_neg_integer()) :: [TextLine.t()]
  def text_lines!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case text_lines(doc, page_index) do
      {:ok, lines} -> lines
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the characters of the whole document.

  Returns every page's characters concatenated into a single flat list, in page
  order. Each character carries its bounding box, font metadata, and
  typographic placement as a `PdfElixide.Document.Char` struct.
  """
  @spec chars(t()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  def chars(%__MODULE__{ref: ref}) do
    with {:ok, chars} <- Wrap.call(fn -> Native.document_all_chars(ref) end) do
      {:ok, Enum.map(chars, &Char.from_nif/1)}
    end
  end

  @doc """
  Extracts the characters of the whole document, raising an error if it fails.
  """
  @spec chars!(t()) :: [Char.t()]
  def chars!(%__MODULE__{} = doc) do
    case chars(doc) do
      {:ok, chars} -> chars
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the characters of the page at the given zero-based index.

  Each character carries its bounding box, font metadata, and typographic
  placement as a `PdfElixide.Document.Char` struct.
  """
  @spec chars(t(), non_neg_integer()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  def chars(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, chars} <- Wrap.call(fn -> Native.document_chars(ref, page_index) end) do
      {:ok, Enum.map(chars, &Char.from_nif/1)}
    end
  end

  @doc """
  Extracts the characters of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec chars!(t(), non_neg_integer()) :: [Char.t()]
  def chars!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case chars(doc, page_index) do
      {:ok, chars} -> chars
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the spans of the whole document.

  Returns every page's spans concatenated into a single flat list, in page
  order. Each span is a run of text sharing one text state, carried as a
  `PdfElixide.Document.Span` struct.
  """
  @spec spans(t()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  def spans(%__MODULE__{ref: ref}) do
    with {:ok, spans} <- Wrap.call(fn -> Native.document_all_spans(ref) end) do
      {:ok, Enum.map(spans, &Span.from_nif/1)}
    end
  end

  @doc """
  Extracts the spans of the whole document, raising an error if it fails.
  """
  @spec spans!(t()) :: [Span.t()]
  def spans!(%__MODULE__{} = doc) do
    case spans(doc) do
      {:ok, spans} -> spans
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the spans of the page at the given zero-based index.

  Each span is a run of text sharing one text state, carried as a
  `PdfElixide.Document.Span` struct.
  """
  @spec spans(t(), non_neg_integer()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  def spans(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, spans} <- Wrap.call(fn -> Native.document_spans(ref, page_index) end) do
      {:ok, Enum.map(spans, &Span.from_nif/1)}
    end
  end

  @doc """
  Extracts the spans of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec spans!(t(), non_neg_integer()) :: [Span.t()]
  def spans!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case spans(doc, page_index) do
      {:ok, spans} -> spans
      {:error, error} -> raise error
    end
  end

  @doc """
  Detects the tables of the whole document.

  Returns every page's tables concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Table` structs.

  Detection is heuristic — see `PdfElixide.Document.Table` for the `:real_grid?`
  flag and how to filter out likely false positives.
  """
  @spec tables(t()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  def tables(%__MODULE__{ref: ref}) do
    with {:ok, tables} <- Wrap.call(fn -> Native.document_all_tables(ref) end) do
      {:ok, Enum.map(tables, &Table.from_nif/1)}
    end
  end

  @doc """
  Detects the tables of the whole document, raising an error if it fails.
  """
  @spec tables!(t()) :: [Table.t()]
  def tables!(%__MODULE__{} = doc) do
    case tables(doc) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  @doc """
  Detects the tables of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no detectable table. Detection is
  heuristic — see `PdfElixide.Document.Table` for the `:real_grid?` flag and how
  to filter out likely false positives.
  """
  @spec tables(t(), non_neg_integer()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  def tables(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, tables} <- Wrap.call(fn -> Native.document_tables(ref, page_index) end) do
      {:ok, Enum.map(tables, &Table.from_nif/1)}
    end
  end

  @doc """
  Detects the tables of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec tables!(t(), non_neg_integer()) :: [Table.t()]
  def tables!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case tables(doc, page_index) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the vector paths of the whole document.

  Returns every page's paths concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Path` structs.
  """
  @spec paths(t()) :: {:ok, [Path.t()]} | {:error, Error.t()}
  def paths(%__MODULE__{ref: ref}) do
    with {:ok, paths} <- Wrap.call(fn -> Native.document_all_paths(ref) end) do
      {:ok, Enum.map(paths, &Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the vector paths of the whole document, raising an error if it fails.
  """
  @spec paths!(t()) :: [Path.t()]
  def paths!(%__MODULE__{} = doc) do
    case paths(doc) do
      {:ok, paths} -> paths
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the vector paths of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no vector graphics. Each path — a line,
  curve, rectangle, or filled shape — is carried as a `PdfElixide.Document.Path`
  struct.
  """
  @spec paths(t(), non_neg_integer()) :: {:ok, [Path.t()]} | {:error, Error.t()}
  def paths(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, paths} <- Wrap.call(fn -> Native.document_paths(ref, page_index) end) do
      {:ok, Enum.map(paths, &Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the vector paths of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec paths!(t(), non_neg_integer()) :: [Path.t()]
  def paths!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case paths(doc, page_index) do
      {:ok, paths} -> paths
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the fonts of the whole document.

  Returns every page's fonts concatenated into a single flat list, in page order,
  as `PdfElixide.Document.Font` structs. A font used on several pages appears once
  per page.
  """
  @spec fonts(t()) :: {:ok, [Font.t()]} | {:error, Error.t()}
  def fonts(%__MODULE__{ref: ref}) do
    with {:ok, fonts} <- Wrap.call(fn -> Native.document_all_fonts(ref) end) do
      {:ok, Enum.map(fonts, &Font.from_nif/1)}
    end
  end

  @doc """
  Extracts the fonts of the whole document, raising an error if it fails.
  """
  @spec fonts!(t()) :: [Font.t()]
  def fonts!(%__MODULE__{} = doc) do
    case fonts(doc) do
      {:ok, fonts} -> fonts
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the fonts referenced by the page at the given zero-based index.

  Returns `{:ok, []}` when the page references no fonts. Each font is carried as a
  `PdfElixide.Document.Font` struct with its metadata; the raw embedded font
  program (when present) is pulled on demand with `PdfElixide.Document.Font.data/1`.
  """
  @spec fonts(t(), non_neg_integer()) :: {:ok, [Font.t()]} | {:error, Error.t()}
  def fonts(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, fonts} <- Wrap.call(fn -> Native.document_fonts(ref, page_index) end) do
      {:ok, Enum.map(fonts, &Font.from_nif/1)}
    end
  end

  @doc """
  Extracts the fonts referenced by the page at the given zero-based index, raising
  an error if it fails.
  """
  @spec fonts!(t(), non_neg_integer()) :: [Font.t()]
  def fonts!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case fonts(doc, page_index) do
      {:ok, fonts} -> fonts
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the document outline — its bookmarks / table of contents.

  Returns the top-level `PdfElixide.Document.OutlineItem` structs, each of which
  may carry nested `:children`, forming a tree. Returns `{:ok, []}` when the
  document has no outline.
  """
  @spec outline(t()) :: {:ok, [OutlineItem.t()]} | {:error, Error.t()}
  def outline(%__MODULE__{ref: ref}) do
    with {:ok, items} <- Wrap.call(fn -> Native.document_outline(ref) end) do
      {:ok, Enum.map(items, &OutlineItem.from_nif/1)}
    end
  end

  @doc """
  Reads the document outline, raising an error if it fails.
  """
  @spec outline!(t()) :: [OutlineItem.t()]
  def outline!(%__MODULE__{} = doc) do
    case outline(doc) do
      {:ok, items} -> items
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the annotations of the whole document.

  Returns every page's annotations concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Annotation` structs. Each carries its zero-based
  `:page` index. Returns `{:ok, []}` when the document has no annotations.
  """
  @spec annotations(t()) :: {:ok, [Annotation.t()]} | {:error, Error.t()}
  def annotations(%__MODULE__{ref: ref}) do
    with {:ok, annotations} <- Wrap.call(fn -> Native.document_all_annotations(ref) end) do
      {:ok, Enum.map(annotations, &Annotation.from_nif/1)}
    end
  end

  @doc """
  Reads the annotations of the whole document, raising an error if it fails.
  """
  @spec annotations!(t()) :: [Annotation.t()]
  def annotations!(%__MODULE__{} = doc) do
    case annotations(doc) do
      {:ok, annotations} -> annotations
      {:error, error} -> raise error
    end
  end

  @doc """
  Reads the annotations of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no annotations. Each annotation — a link,
  sticky note, highlight, form widget, and so on — is carried as a
  `PdfElixide.Document.Annotation` struct.
  """
  @spec annotations(t(), non_neg_integer()) ::
          {:ok, [Annotation.t()]} | {:error, Error.t()}
  def annotations(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, annotations} <- Wrap.call(fn -> Native.document_annotations(ref, page_index) end) do
      {:ok, Enum.map(annotations, &Annotation.from_nif/1)}
    end
  end

  @doc """
  Reads the annotations of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec annotations!(t(), non_neg_integer()) :: [Annotation.t()]
  def annotations!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case annotations(doc, page_index) do
      {:ok, annotations} -> annotations
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the raster images of the whole document.

  Returns every page's images concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Image` structs. Pixel data is normalized to PNG
  bytes.
  """
  @spec images(t()) :: {:ok, [Image.t()]} | {:error, Error.t()}
  def images(%__MODULE__{ref: ref}) do
    with {:ok, images} <- Wrap.call(fn -> Native.document_all_images(ref) end) do
      {:ok, Enum.map(images, &Image.from_nif/1)}
    end
  end

  @doc """
  Extracts the raster images of the whole document, raising an error if it fails.
  """
  @spec images!(t()) :: [Image.t()]
  def images!(%__MODULE__{} = doc) do
    case images(doc) do
      {:ok, images} -> images
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the raster images of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no images. Each image — a photo, logo, or
  scanned picture — is carried as a `PdfElixide.Document.Image` struct with its
  pixel data normalized to PNG bytes.
  """
  @spec images(t(), non_neg_integer()) :: {:ok, [Image.t()]} | {:error, Error.t()}
  def images(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, images} <- Wrap.call(fn -> Native.document_images(ref, page_index) end) do
      {:ok, Enum.map(images, &Image.from_nif/1)}
    end
  end

  @doc """
  Extracts the raster images of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec images!(t(), non_neg_integer()) :: [Image.t()]
  def images!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case images(doc, page_index) do
      {:ok, images} -> images
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns a lazy handle for every page in the document.
  """
  @spec pages(t()) :: [Page.t()]
  def pages(%__MODULE__{} = doc) do
    Enum.map(0..(page_count!(doc) - 1)//1, &%Page{doc: doc, index: &1})
  end

  @doc """
  Returns a lazy handle for the page at the given zero-based index.
  """
  @spec page(t(), non_neg_integer()) :: {:ok, Page.t()} | {:error, Error.t()}
  def page(%__MODULE__{} = doc, index) when is_integer(index) and index >= 0 do
    case page_count(doc) do
      {:ok, count} when index < count ->
        {:ok, %Page{doc: doc, index: index}}

      {:ok, _count} ->
        {:error, %Error{reason: :out_of_range, message: "Page index out of range"}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Same as `page/2` but raises an error if it fails.
  """
  @spec page!(t(), non_neg_integer()) :: Page.t()
  def page!(doc, index) when is_integer(index) and index >= 0 do
    case page(doc, index) do
      {:ok, page} -> page
      {:error, error} -> raise error
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document{version: {maj, min}, source_path: path}, _opts) do
      src = if path, do: Elixir.Path.basename(path), else: "<binary>"
      concat(["#PdfElixide.Document<", src, " v", to_string(maj), ".", to_string(min), ">"])
    end
  end

  defimpl Enumerable do
    alias PdfElixide.Document
    alias PdfElixide.Document.Page

    def count(doc), do: {:ok, Document.page_count!(doc)}

    def member?(%Document{ref: ref} = doc, %Page{doc: %Document{ref: ref}, index: index})
        when is_integer(index) and index >= 0 do
      {:ok, index < Document.page_count!(doc)}
    end

    def member?(_doc, _other), do: {:ok, false}

    def slice(doc) do
      count = Document.page_count!(doc)

      {:ok, count,
       fn start, length, step ->
         Enum.map(start..(start + (length - 1) * step)//step, &%Page{doc: doc, index: &1})
       end}
    end

    def reduce(doc, acc, fun) do
      count = Document.page_count!(doc)

      Enumerable.reduce(0..(count - 1)//1, acc, fn i, acc ->
        fun.(%Page{doc: doc, index: i}, acc)
      end)
    end
  end
end
