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
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:ref, :version]
  defstruct [:ref, :version, :page_count, :source_path]

  @typedoc """
  A handle on an open PDF document.

  `:version` and `:page_count` are read once at open and served from the struct
  thereafter, since both are immutable for a read-only document. `:page_count`
  is `nil` when the count could not be determined at open — an encrypted
  document whose page tree needs a password, opened without one — in which case
  `page_count/1` asks the document instead.
  """
  @type t :: %__MODULE__{
          ref: reference(),
          version: {non_neg_integer(), non_neg_integer()},
          page_count: non_neg_integer() | nil,
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
      {:ok,
       %__MODULE__{
         ref: ref,
         version: version,
         page_count: cached_page_count(ref),
         source_path: path
       }}
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
      {:ok,
       %__MODULE__{
         ref: ref,
         version: version,
         page_count: cached_page_count(ref),
         source_path: nil
       }}
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

  # The page count is immutable for a read-only document, so it is read once here
  # and served from the struct afterwards. A failure is not an open failure: for an
  # encrypted document whose page tree cannot be decrypted yet, upstream reports
  # `EncryptedPdf` until `authenticate/2` runs, and refusing to open would be
  # stricter than upstream itself, which keeps a metadata-broken document usable
  # because every per-page call surfaces the real error anyway. Such a document
  # caches nothing and `page_count/1` asks it again.
  #
  # A cached number cannot go stale: for an encrypted document upstream either
  # fails or returns the real `/Count`, and authentication changes only whether
  # the count is readable, never what it is.
  defp cached_page_count(ref) do
    case Wrap.call(fn -> Native.document_page_count(ref) end) do
      {:ok, count} -> count
      {:error, _error} -> nil
    end
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
  it. `version/1`, `source_path/1` and `page_count/1` keep working, since they
  read the struct rather than the native handle — `page_count/1` only for a
  document whose count was determined at open, which is every document except an
  encrypted one opened without a password. Any `PdfElixide.Document.Image` or
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

  The count is read once at open and cached on the struct, so this normally
  costs nothing and keeps working after `close/1`, as `version/1` does.

  The exception is a document whose page tree could not be read at open — an
  encrypted one opened without a password. Nothing is cached for it, so the
  count is read from the document on every call: an error until `authenticate/2`
  succeeds, the real count afterwards, and `{:error, %PdfElixide.Error{reason: :closed}}`
  once the document is closed.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def page_count(%__MODULE__{page_count: count}) when is_integer(count), do: {:ok, count}

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

  @typedoc """
  How a `:region` (or `:exclude_regions`) decides whether an object is inside
  it.

    * `:intersects` — any overlap at all counts. The default, and what
      `pdf_oxide` uses everywhere it does not take a mode.
    * `:fully_contained` — the object's bounding box must lie entirely
      within the region.
    * `{:min_overlap, ratio}` — at least `ratio` of the object's area must
      lie within the region.

  ## `:min_overlap` details

  `ratio` must be between `0.0` and `1.0`; anything outside that range is
  `{:error, %PdfElixide.Error{reason: :other}}`. The bound is checked here
  rather than upstream, which validates it nowhere — no other `pdf_oxide`
  binding can even select this mode, so an out-of-range value would otherwise
  fail silently and wrongly (a negative one matches every object, and one
  above `1.0` matches none).

  Two behaviors worth knowing before choosing a value:

    * The fraction is of the **object's own** area, not the region's. A large
      element clipped by a small region scores low however much of the region
      it covers, so `:min_overlap` answers "how much of this object is in the
      region?", never the reverse.
    * `{:min_overlap, 0.0}` matches *everything*, including objects that do
      not touch the region at all — a non-overlapping object scores `0.0`,
      and the comparison is `>=`. Use `:intersects` if you meant "any
      overlap".
  """
  @type region_mode :: :intersects | :fully_contained | {:min_overlap, float()}

  @typedoc """
  Options accepted by the `text` and `text!` functions.

    * `:extract_tables` — detect tables and render them inline as
      space-padded, column-aligned rows. Defaults to `true`, matching
      `pdf_oxide`'s own `extract_text`.
    * `:expand_ligatures` — expand `U+FB00`–`U+FB06` ligatures to their
      component letters (`ﬁ` to `fi`, and so on). Defaults to `false`.
      Unlike in `t:markdown_opts/0`, this one is live: upstream applies it
      on the plain-text assembly path, which is exactly the path this
      function uses.
    * `:table_detection` — a keyword list tuning the spatial table
      detector; see `t:table_detection_opts/0`. Only consulted when
      `:extract_tables` is `true`, and its `:text_fallback` key is ignored
      here — upstream forces it to `false` on the text path, so a page with
      no ruling lines yields no tables regardless. Defaults to `nil` (the
      upstream default config).
    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the text inside
      it. An extracted `bbox` can be handed straight back in. Defaults to
      `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:exclude_regions` — a list of rects whose text is dropped. Applied
      *before* `:region`, so exclusion wins. Defaults to `[]`.
    * `:exclude_regions_mode` — how `:exclude_regions` match. Defaults to
      `:intersects`.
    * `:exclude_layers` — names of optional-content (OCG) layers to
      suppress. Defaults to `[]`.
    * `:exclude_inks` — names of Separation/DeviceN inks to suppress.
      Defaults to `[]`.

  ## Layer and ink filtering drops the other options

  `pdf_oxide` serves layer and ink filtering only through
  `extract_text_filtered` / `extract_text_filtered_in_rect`, which build
  their own conversion options internally and offer no way to pass ours.
  So when `:exclude_layers` or `:exclude_inks` is non-empty, **only
  `:region` and `:region_mode` still apply** — `:extract_tables`,
  `:expand_ligatures`, `:table_detection`, `:exclude_regions` and
  `:exclude_regions_mode` fall back to their upstream defaults
  (`:extract_tables` to `true`, the rest to off). The Python bindings have
  the same limitation and do not document it.

  Options `to_markdown/2` accepts but this function does not —
  `:reading_order`, `:include_form_fields`, `:strip_running_headers_footers`
  — are omitted because upstream's text assembler never reads them. Like any
  other undeclared key, passing one is silently ignored.
  """
  @type text_opts :: [
          extract_tables: boolean(),
          expand_ligatures: boolean(),
          table_detection: table_detection_opts() | nil,
          region: Rect.t() | nil,
          region_mode: region_mode(),
          exclude_regions: [Rect.t()],
          exclude_regions_mode: region_mode(),
          exclude_layers: [String.t()],
          exclude_inks: [String.t()]
        ]

  @doc """
  Extracts text content.

  With a keyword list (or nothing) as the second argument, extracts the whole
  document — every page's text concatenated in order, separated by a form-feed
  (`\\f`) page separator. With a zero-based integer, extracts that single page
  instead.

      Document.text(doc)
      Document.text(doc, extract_tables: false)
      Document.text(doc, 0)
      Document.text(doc, 0, region: word.bbox)

  A page that fails to extract contributes nothing to the whole-document
  result rather than failing the call, matching `pdf_oxide`.

  See `t:text_opts/0` for the available options.
  """
  @spec text(t()) :: {:ok, String.t()} | {:error, Error.t()}
  @spec text(t(), text_opts() | non_neg_integer()) :: {:ok, String.t()} | {:error, Error.t()}
  def text(doc, page_index_or_opts \\ [])

  def text(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_text_options(opts)
    Wrap.call(fn -> Native.document_extract_all_text(ref, options) end)
  end

  def text(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    text(doc, page_index, [])
  end

  @doc """
  Extracts text content, raising an error if it fails.
  """
  @spec text!(t()) :: String.t()
  @spec text!(t(), text_opts() | non_neg_integer()) :: String.t()
  def text!(doc, page_index_or_opts \\ [])

  def text!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case text(doc, opts) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  def text!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    text!(doc, page_index, [])
  end

  @doc """
  Extracts the text content of the page at the given zero-based index.

  See `t:text_opts/0` for the available options.
  """
  @spec text(t(), non_neg_integer(), text_opts()) :: {:ok, String.t()} | {:error, Error.t()}
  def text(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_text_options(opts)
    Wrap.call(fn -> Native.document_extract_text(ref, page_index, options) end)
  end

  @doc """
  Extracts the text content of the page at the given zero-based index,
  raising an error if it fails.
  """
  @spec text!(t(), non_neg_integer(), text_opts()) :: String.t()
  def text!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case text(doc, page_index, opts) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  defp build_text_options(opts) do
    %{
      extract_tables: Keyword.get(opts, :extract_tables, true),
      expand_ligatures: Keyword.get(opts, :expand_ligatures, false),
      table_detection: build_table_detection_option(Keyword.get(opts, :table_detection)),
      region: Keyword.get(opts, :region),
      region_mode: Keyword.get(opts, :region_mode, :intersects),
      exclude_regions: Keyword.get(opts, :exclude_regions, []),
      exclude_regions_mode: Keyword.get(opts, :exclude_regions_mode, :intersects),
      exclude_layers: Keyword.get(opts, :exclude_layers, []),
      exclude_inks: Keyword.get(opts, :exclude_inks, [])
    }
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
      component letters (`ﬁ` to `fi`, and so on). Accepted for forward
      compatibility, but currently has no effect on Markdown output:
      upstream applies it only on its plain-text assembly path, which the
      Markdown converter does not use. Defaults to `false`.
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

  @typedoc """
  Options accepted by the `to_html` and `to_html!` functions.

  Only the options that upstream actually reads on its HTML path are
  exposed, so every one of them changes the output. In particular
  `:bold_markers`, `:annotate_skipped_pages`,
  `:strip_running_headers_footers` and `:expand_ligatures` — all valid for
  `to_markdown/2` — are not part of this list, because `pdf_oxide` never
  consults them while converting to HTML. Like any other undeclared key,
  passing one is silently ignored rather than an error. A *declared* key
  given a value of the wrong type is reported as
  `{:error, %PdfElixide.Error{reason: :other}}`, with a message naming the
  offending field, rather than raising.

    * `:preserve_layout` — emit one absolutely positioned `<div>` per text
      span, carrying that span's coordinates and font size in inline CSS
      (`pt` units), in place of the semantic flow of `<p>`/`<h1>`/`<ul>`
      elements. Colour is written only for non-black text. Note that this
      mode emits *only* those positioned spans: headings, lists and tables
      are not produced, so `:detect_headings` and `:extract_tables` have no
      effect under it. Defaults to `false`.

      The result is **not** directly renderable, and reproducing the page
      needs two corrections from you. Upstream writes the PDF's own
      user-space coordinates verbatim, so the `top` value is measured from
      the *bottom* of the page while CSS `top` measures from the top: flip
      it yourself with `top = height - y`, taking the page height from
      `PdfElixide.Document.Page.height/1`. And the per-page wrapper
      `to_html/1` emits carries no styling, so it is not a positioned
      containing block and gives the spans no page-sized box to resolve
      against — add `position: relative` and an explicit size to each
      wrapper, or every page will pile up in the same place.
    * `:detect_headings` — cluster font sizes to emit `<h1>`–`<h6>`
      elements instead of plain `<p>` paragraphs. Defaults to `true`.
    * `:extract_tables` — detect tables and render them as
      `<table>`/`<thead>`/`<tbody>` markup, with `colspan` and `rowspan` on
      the cells. Defaults to `true`.
    * `:include_images` — emit `<img>` elements. Defaults to `false`, since
      embedded images can add hundreds of kilobytes per page. Images are
      appended to the end of the page in a `<div class="page-images">`
      rather than placed at their position in the content.
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

      Upstream interpolates the resulting path into the `src` attribute
      **without HTML escaping**, so a directory whose name contains `"` or
      `&` produces malformed markup. Never build this path from untrusted
      input: a crafted directory name can close the attribute and inject
      others.
    * `:include_form_fields` — inline AcroForm field values at their
      positions on the page. Defaults to `true`.
    * `:max_image_pixels` — skip images whose width times height exceeds
      this count. `nil` means `pdf_oxide`'s own 16 MP limit, not "no
      limit" — pass a large integer to lift it, or `0` to skip every
      image. Defaults to `nil`.
    * `:reading_order` — how text blocks are ordered:
      `:structure_tree` (follow a tagged PDF's structure tree, falling
      back to an XY-cut), `:column_aware`, or `:top_to_bottom`. Defaults
      to `:structure_tree`.

  Defaults mirror `pdf_oxide`'s `ConversionOptions::default()`, so calling
  `to_html/1` is equivalent to `to_html/2` with no options.
  """
  @type html_opts :: [
          preserve_layout: boolean(),
          detect_headings: boolean(),
          extract_tables: boolean(),
          include_images: boolean(),
          embed_images: boolean(),
          image_output_dir: Path.t() | nil,
          include_form_fields: boolean(),
          max_image_pixels: non_neg_integer() | nil,
          reading_order: :structure_tree | :column_aware | :top_to_bottom
        ]

  @doc """
  Converts the document to HTML.

  With a keyword list (or nothing) as the second argument, converts the
  whole document, wrapping each page in a
  `<div class="page" data-page="N">` element whose `N` is the one-based
  page number. With a zero-based integer, converts that single page
  instead, without the wrapper.

      Document.to_html(doc)
      Document.to_html(doc, detect_headings: false)
      Document.to_html(doc, 0)

  The result is an HTML *fragment*, not a standalone document: there is no
  doctype, no `<html>`/`<body>`, and no stylesheet — bring your own, or
  wrap the fragment yourself. A page with no extractable content converts
  to an empty string, as does a document that is encrypted and could not
  be decrypted.

  See `t:html_opts/0` for the available options.
  """
  @spec to_html(t()) :: {:ok, String.t()} | {:error, Error.t()}
  @spec to_html(t(), html_opts() | non_neg_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_html(doc, page_index_or_opts \\ [])

  def to_html(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_html_options(opts)
    Wrap.call(fn -> call_html_all(ref, options) end)
  end

  def to_html(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_html(doc, page_index, [])
  end

  @doc """
  Converts the document to HTML, raising an error if it fails.
  """
  @spec to_html!(t()) :: String.t()
  @spec to_html!(t(), html_opts() | non_neg_integer()) :: String.t()
  def to_html!(doc, page_index_or_opts \\ [])

  def to_html!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case to_html(doc, opts) do
      {:ok, html} -> html
      {:error, error} -> raise error
    end
  end

  def to_html!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_html!(doc, page_index, [])
  end

  @doc """
  Converts the page at the given zero-based index to HTML.

  See `t:html_opts/0` for the available options.
  """
  @spec to_html(t(), non_neg_integer(), html_opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_html(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_html_options(opts)
    Wrap.call(fn -> call_html(ref, page_index, options) end)
  end

  @doc """
  Converts the page at the given zero-based index to HTML, raising an
  error if it fails.
  """
  @spec to_html!(t(), non_neg_integer(), html_opts()) :: String.t()
  def to_html!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case to_html(doc, page_index, opts) do
      {:ok, html} -> html
      {:error, error} -> raise error
    end
  end

  defp build_html_options(opts) do
    %{
      preserve_layout: Keyword.get(opts, :preserve_layout, false),
      detect_headings: Keyword.get(opts, :detect_headings, true),
      extract_tables: Keyword.get(opts, :extract_tables, true),
      include_images: Keyword.get(opts, :include_images, false),
      embed_images: Keyword.get(opts, :embed_images, true),
      image_output_dir: Keyword.get(opts, :image_output_dir),
      include_form_fields: Keyword.get(opts, :include_form_fields, true),
      max_image_pixels: Keyword.get(opts, :max_image_pixels),
      reading_order: Keyword.get(opts, :reading_order, :structure_tree)
    }
  end

  # Same dirty-CPU / dirty-IO split as the Markdown pair above.
  defp call_html_all(ref, options) do
    if writes_images?(options),
      do: Native.document_to_html_all_to_dir(ref, options),
      else: Native.document_to_html_all(ref, options)
  end

  defp call_html(ref, page_index, options) do
    if writes_images?(options),
      do: Native.document_to_html_to_dir(ref, page_index, options),
      else: Native.document_to_html(ref, page_index, options)
  end

  @typedoc """
  A span-extraction tuning preset, named after `pdf_oxide`'s own
  `ExtractionProfile` constants. A profile changes the TJ-offset and
  word-margin thresholds used to turn glyphs into spans, before any word
  clustering happens.
  """
  @type extraction_profile ::
          :conservative
          | :tj_heavy
          | :aggressive
          | :balanced
          | :academic
          | :policy
          | :form
          | :government
          | :scanned_ocr
          | :adaptive

  @typedoc """
  Options accepted by the `words` and `words!` functions.

    * `:include_artifacts` — keep spans tagged `/Artifact` (running
      headers and footers, page numbers, watermarks; ISO 32000-1
      §14.8.2.2.1). Defaults to `true`, which is the current behavior and
      what the Python bindings default to; `false` selects upstream's
      spec-correct variant.
    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the words
      inside it. Defaults to `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:word_gap_threshold` — the inter-glyph gap in points that starts a
      new word. `nil` lets upstream compute it adaptively from page
      statistics (median character width × 0.3). Defaults to `nil`.
    * `:profile` — a `t:extraction_profile/0`, or `nil` for none.
      Defaults to `nil`.

  ## `:word_gap_threshold` and `:profile` are deprecated upstream

  `pdf_oxide` plans to move both to a separate advanced API (its Python
  bindings already emit a `DeprecationWarning` for them), and `:profile`
  in particular is documented as pending removal. `:profile` also does
  more than its name suggests: passing *any* profile switches span
  extraction to a different, legacy ordering path (XY-cut plus a row-aware
  sort), so it can change word **order** and not merely word boundaries —
  even for `:conservative`, which is nominally the default profile. Prefer
  leaving both at `nil`.

  Unlike the Python bindings, `:region` here composes with everything else:
  it is applied after extraction, so it does not discard the thresholds or
  the profile.
  """
  @type words_opts :: [
          include_artifacts: boolean(),
          region: Rect.t() | nil,
          region_mode: region_mode(),
          word_gap_threshold: float() | nil,
          profile: extraction_profile() | nil
        ]

  @doc """
  Extracts words, each with its bounding box and font metadata as a
  `PdfElixide.Document.Word` struct.

  With a keyword list (or nothing) as the second argument, returns every
  page's words concatenated into a single flat list, in page order. With a
  zero-based integer, returns that single page's words instead.

      Document.words(doc)
      Document.words(doc, include_artifacts: false)
      Document.words(doc, 0)
      Document.words(doc, 0, region: heading.bbox)

  See `t:words_opts/0` for the available options.
  """
  @spec words(t()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  @spec words(t(), words_opts() | non_neg_integer()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  def words(doc, page_index_or_opts \\ [])

  def words(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_words_options(opts)

    with {:ok, words} <- Wrap.call(fn -> Native.document_all_words(ref, options) end) do
      {:ok, Enum.map(words, &Word.from_nif/1)}
    end
  end

  def words(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    words(doc, page_index, [])
  end

  @doc """
  Extracts words, raising an error if it fails.
  """
  @spec words!(t()) :: [Word.t()]
  @spec words!(t(), words_opts() | non_neg_integer()) :: [Word.t()]
  def words!(doc, page_index_or_opts \\ [])

  def words!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case words(doc, opts) do
      {:ok, words} -> words
      {:error, error} -> raise error
    end
  end

  def words!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    words!(doc, page_index, [])
  end

  @doc """
  Extracts the words of the page at the given zero-based index.

  See `t:words_opts/0` for the available options.
  """
  @spec words(t(), non_neg_integer(), words_opts()) :: {:ok, [Word.t()]} | {:error, Error.t()}
  def words(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_words_options(opts)

    with {:ok, words} <- Wrap.call(fn -> Native.document_words(ref, page_index, options) end) do
      {:ok, Enum.map(words, &Word.from_nif/1)}
    end
  end

  @doc """
  Extracts the words of the page at the given zero-based index, raising an error
  if it fails.
  """
  @spec words!(t(), non_neg_integer(), words_opts()) :: [Word.t()]
  def words!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case words(doc, page_index, opts) do
      {:ok, words} -> words
      {:error, error} -> raise error
    end
  end

  defp build_words_options(opts) do
    %{
      include_artifacts: Keyword.get(opts, :include_artifacts, true),
      word_gap_threshold: Keyword.get(opts, :word_gap_threshold),
      profile: Keyword.get(opts, :profile),
      region: Keyword.get(opts, :region),
      region_mode: Keyword.get(opts, :region_mode, :intersects)
    }
  end

  @typedoc """
  Options accepted by the `text_lines` and `text_lines!` functions.

  The same options as `t:words_opts/0` — including the upstream deprecation
  of `:word_gap_threshold` and `:profile` documented there — plus:

    * `:line_gap_threshold` — the vertical gap in points that starts a new
      line. `nil` lets upstream compute it. Defaults to `nil`, and is
      deprecated upstream alongside the other two.
  """
  @type text_lines_opts :: [
          include_artifacts: boolean(),
          region: Rect.t() | nil,
          region_mode: region_mode(),
          word_gap_threshold: float() | nil,
          line_gap_threshold: float() | nil,
          profile: extraction_profile() | nil
        ]

  @doc """
  Extracts text lines, each with its bounding box and constituent words as a
  `PdfElixide.Document.TextLine` struct.

  With a keyword list (or nothing) as the second argument, returns every
  page's lines concatenated into a single flat list, in page order. With a
  zero-based integer, returns that single page's lines instead.

  See `t:text_lines_opts/0` for the available options.
  """
  @spec text_lines(t()) :: {:ok, [TextLine.t()]} | {:error, Error.t()}
  @spec text_lines(t(), text_lines_opts() | non_neg_integer()) ::
          {:ok, [TextLine.t()]} | {:error, Error.t()}
  def text_lines(doc, page_index_or_opts \\ [])

  def text_lines(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_text_lines_options(opts)

    with {:ok, lines} <- Wrap.call(fn -> Native.document_all_text_lines(ref, options) end) do
      {:ok, Enum.map(lines, &TextLine.from_nif/1)}
    end
  end

  def text_lines(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    text_lines(doc, page_index, [])
  end

  @doc """
  Extracts text lines, raising an error if it fails.
  """
  @spec text_lines!(t()) :: [TextLine.t()]
  @spec text_lines!(t(), text_lines_opts() | non_neg_integer()) :: [TextLine.t()]
  def text_lines!(doc, page_index_or_opts \\ [])

  def text_lines!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case text_lines(doc, opts) do
      {:ok, lines} -> lines
      {:error, error} -> raise error
    end
  end

  def text_lines!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    text_lines!(doc, page_index, [])
  end

  @doc """
  Extracts the text lines of the page at the given zero-based index.

  See `t:text_lines_opts/0` for the available options.
  """
  @spec text_lines(t(), non_neg_integer(), text_lines_opts()) ::
          {:ok, [TextLine.t()]} | {:error, Error.t()}
  def text_lines(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_text_lines_options(opts)

    with {:ok, lines} <- Wrap.call(fn -> Native.document_text_lines(ref, page_index, options) end) do
      {:ok, Enum.map(lines, &TextLine.from_nif/1)}
    end
  end

  @doc """
  Extracts the text lines of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec text_lines!(t(), non_neg_integer(), text_lines_opts()) :: [TextLine.t()]
  def text_lines!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case text_lines(doc, page_index, opts) do
      {:ok, lines} -> lines
      {:error, error} -> raise error
    end
  end

  defp build_text_lines_options(opts) do
    %{
      include_artifacts: Keyword.get(opts, :include_artifacts, true),
      word_gap_threshold: Keyword.get(opts, :word_gap_threshold),
      line_gap_threshold: Keyword.get(opts, :line_gap_threshold),
      profile: Keyword.get(opts, :profile),
      region: Keyword.get(opts, :region),
      region_mode: Keyword.get(opts, :region_mode, :intersects)
    }
  end

  @typedoc """
  Options accepted by the `chars` and `chars!` functions.

    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the characters
      inside it. Defaults to `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:exclude_layers` — names of optional-content (OCG) layers to
      suppress. Defaults to `[]`.
    * `:exclude_inks` — names of Separation/DeviceN inks to suppress.
      Defaults to `[]`.
  """
  @type chars_opts :: [
          region: Rect.t() | nil,
          region_mode: region_mode(),
          exclude_layers: [String.t()],
          exclude_inks: [String.t()]
        ]

  @doc """
  Extracts characters, each with its bounding box, font metadata and
  typographic placement as a `PdfElixide.Document.Char` struct.

  With a keyword list (or nothing) as the second argument, returns every
  page's characters concatenated into a single flat list, in page order. With
  a zero-based integer, returns that single page's characters instead.

  See `t:chars_opts/0` for the available options.
  """
  @spec chars(t()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  @spec chars(t(), chars_opts() | non_neg_integer()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  def chars(doc, page_index_or_opts \\ [])

  def chars(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_chars_options(opts)

    with {:ok, chars} <- Wrap.call(fn -> Native.document_all_chars(ref, options) end) do
      {:ok, Enum.map(chars, &Char.from_nif/1)}
    end
  end

  def chars(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    chars(doc, page_index, [])
  end

  @doc """
  Extracts characters, raising an error if it fails.
  """
  @spec chars!(t()) :: [Char.t()]
  @spec chars!(t(), chars_opts() | non_neg_integer()) :: [Char.t()]
  def chars!(doc, page_index_or_opts \\ [])

  def chars!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case chars(doc, opts) do
      {:ok, chars} -> chars
      {:error, error} -> raise error
    end
  end

  def chars!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    chars!(doc, page_index, [])
  end

  @doc """
  Extracts the characters of the page at the given zero-based index.

  See `t:chars_opts/0` for the available options.
  """
  @spec chars(t(), non_neg_integer(), chars_opts()) :: {:ok, [Char.t()]} | {:error, Error.t()}
  def chars(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_chars_options(opts)

    with {:ok, chars} <- Wrap.call(fn -> Native.document_chars(ref, page_index, options) end) do
      {:ok, Enum.map(chars, &Char.from_nif/1)}
    end
  end

  @doc """
  Extracts the characters of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec chars!(t(), non_neg_integer(), chars_opts()) :: [Char.t()]
  def chars!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case chars(doc, page_index, opts) do
      {:ok, chars} -> chars
      {:error, error} -> raise error
    end
  end

  defp build_chars_options(opts) do
    %{
      region: Keyword.get(opts, :region),
      region_mode: Keyword.get(opts, :region_mode, :intersects),
      exclude_layers: Keyword.get(opts, :exclude_layers, []),
      exclude_inks: Keyword.get(opts, :exclude_inks, [])
    }
  end

  @typedoc """
  Options tuning how glyph runs are merged into spans, accepted as
  `:span_merging`. `pdf_oxide`'s own bindings expose none of this.

    * `:preset` — the base configuration every other key overrides:
      `:default`, `:aggressive` (merges across wider gaps), `:conservative`
      (splits more readily), `:adaptive` (derives thresholds from page gap
      statistics), or `:legacy`. Defaults to `:default`.
    * `:space_threshold_em_ratio` — gap, as a fraction of font size, that
      becomes a space.
    * `:conservative_threshold_pt` — floor gap in points below which no
      space is inserted.
    * `:column_boundary_threshold_pt` — gap in points treated as a column
      break rather than a space.
    * `:severe_overlap_threshold_pt` — negative gap indicating real glyph
      overlap.
    * `:use_adaptive_threshold` — derive the space threshold from page gap
      statistics.
    * `:adaptive` — a keyword list tuning that derivation:
      `:median_multiplier`, `:min_threshold_pt`, `:max_threshold_pt`,
      `:use_iqr`, `:min_samples`. Only consulted when
      `:use_adaptive_threshold` resolves to `true`.
    * `:detect_email_patterns` / `:email_threshold_multiplier` — keep
      addresses from being split at the `@`.
    * `:detect_citation_markers` / `:citation_font_size_ratio` — treat
      small raised runs as citation markers.
    * `:merge_tm_tj_runs` — when `false`, every text-matrix operator starts
      a fresh span.

  Every key except `:preset` defaults to `nil`, meaning "keep the preset's
  value".
  """
  @type span_merging_opts :: [
          preset: :default | :aggressive | :conservative | :adaptive | :legacy,
          space_threshold_em_ratio: float() | nil,
          conservative_threshold_pt: float() | nil,
          column_boundary_threshold_pt: float() | nil,
          severe_overlap_threshold_pt: float() | nil,
          use_adaptive_threshold: boolean() | nil,
          adaptive: keyword() | nil,
          detect_email_patterns: boolean() | nil,
          email_threshold_multiplier: float() | nil,
          detect_citation_markers: boolean() | nil,
          citation_font_size_ratio: float() | nil,
          merge_tm_tj_runs: boolean() | nil
        ]

  @typedoc """
  Options accepted by the `spans` and `spans!` functions.

    * `:reading_order` — how spans are ordered: `:top_to_bottom` (simple
      geometric sorting), `:column_aware` (XY-cut column detection), or
      `:structure` (follow a tagged PDF's structure tree). Defaults to
      `:top_to_bottom`. This is `pdf_oxide`'s span-level reading order and
      names its values differently from the `:reading_order` of
      `t:markdown_opts/0`, which is a separate upstream type.
    * `:span_merging` — a `t:span_merging_opts/0` keyword list, or `nil`
      for upstream's default merging. Defaults to `nil`.
    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the spans
      inside it. Defaults to `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:exclude_layers` — names of optional-content (OCG) layers to
      suppress. Defaults to `[]`.
    * `:exclude_inks` — names of Separation/DeviceN inks to suppress.
      Defaults to `[]`.

  ## `:span_merging` drops the other options

  Upstream serves a merging configuration through a call that accepts
  neither a reading order nor layer/ink filters. So when `:span_merging` is
  set, `:reading_order`, `:exclude_layers` and `:exclude_inks` are ignored.
  `:region` still applies — it is a post-filter, not an upstream argument.
  """
  @type spans_opts :: [
          reading_order: :top_to_bottom | :column_aware | :structure,
          span_merging: span_merging_opts() | nil,
          region: Rect.t() | nil,
          region_mode: region_mode(),
          exclude_layers: [String.t()],
          exclude_inks: [String.t()]
        ]

  @doc """
  Extracts spans — runs of text sharing one text state — as
  `PdfElixide.Document.Span` structs.

  With a keyword list (or nothing) as the second argument, returns every
  page's spans concatenated into a single flat list, in page order. With a
  zero-based integer, returns that single page's spans instead.

  See `t:spans_opts/0` for the available options.
  """
  @spec spans(t()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  @spec spans(t(), spans_opts() | non_neg_integer()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  def spans(doc, page_index_or_opts \\ [])

  def spans(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_spans_options(opts)

    with {:ok, spans} <- Wrap.call(fn -> Native.document_all_spans(ref, options) end) do
      {:ok, Enum.map(spans, &Span.from_nif/1)}
    end
  end

  def spans(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    spans(doc, page_index, [])
  end

  @doc """
  Extracts spans, raising an error if it fails.
  """
  @spec spans!(t()) :: [Span.t()]
  @spec spans!(t(), spans_opts() | non_neg_integer()) :: [Span.t()]
  def spans!(doc, page_index_or_opts \\ [])

  def spans!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case spans(doc, opts) do
      {:ok, spans} -> spans
      {:error, error} -> raise error
    end
  end

  def spans!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    spans!(doc, page_index, [])
  end

  @doc """
  Extracts the spans of the page at the given zero-based index.

  See `t:spans_opts/0` for the available options.
  """
  @spec spans(t(), non_neg_integer(), spans_opts()) :: {:ok, [Span.t()]} | {:error, Error.t()}
  def spans(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_spans_options(opts)

    with {:ok, spans} <- Wrap.call(fn -> Native.document_spans(ref, page_index, options) end) do
      {:ok, Enum.map(spans, &Span.from_nif/1)}
    end
  end

  @doc """
  Extracts the spans of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec spans!(t(), non_neg_integer(), spans_opts()) :: [Span.t()]
  def spans!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case spans(doc, page_index, opts) do
      {:ok, spans} -> spans
      {:error, error} -> raise error
    end
  end

  defp build_spans_options(opts) do
    %{
      reading_order: Keyword.get(opts, :reading_order, :top_to_bottom),
      span_merging: build_span_merging_option(Keyword.get(opts, :span_merging)),
      region: Keyword.get(opts, :region),
      region_mode: Keyword.get(opts, :region_mode, :intersects),
      exclude_layers: Keyword.get(opts, :exclude_layers, []),
      exclude_inks: Keyword.get(opts, :exclude_inks, [])
    }
  end

  # The nested option builders below each take a keyword list, but a value of
  # any other shape is passed through untouched rather than rejected by a
  # guard. That keeps the rule the rest of the library follows: a wrong-typed
  # value inside an options map fails in the NIF's own decode, surfacing as
  # `{:error, %Error{reason: :other}}` whose message names the offending
  # field. A guard here would instead raise a `FunctionClauseError` naming a
  # private function, which tells the caller nothing about which option was
  # wrong.
  defp build_span_merging_option(nil), do: nil

  defp build_span_merging_option(opts) when is_list(opts) do
    %{
      preset: Keyword.get(opts, :preset, :default),
      space_threshold_em_ratio: Keyword.get(opts, :space_threshold_em_ratio),
      conservative_threshold_pt: Keyword.get(opts, :conservative_threshold_pt),
      column_boundary_threshold_pt: Keyword.get(opts, :column_boundary_threshold_pt),
      severe_overlap_threshold_pt: Keyword.get(opts, :severe_overlap_threshold_pt),
      use_adaptive_threshold: Keyword.get(opts, :use_adaptive_threshold),
      adaptive: build_adaptive_threshold_option(Keyword.get(opts, :adaptive)),
      detect_email_patterns: Keyword.get(opts, :detect_email_patterns),
      email_threshold_multiplier: Keyword.get(opts, :email_threshold_multiplier),
      detect_citation_markers: Keyword.get(opts, :detect_citation_markers),
      citation_font_size_ratio: Keyword.get(opts, :citation_font_size_ratio),
      merge_tm_tj_runs: Keyword.get(opts, :merge_tm_tj_runs)
    }
  end

  defp build_span_merging_option(other), do: other

  defp build_adaptive_threshold_option(nil), do: nil

  defp build_adaptive_threshold_option(opts) when is_list(opts) do
    %{
      median_multiplier: Keyword.get(opts, :median_multiplier),
      min_threshold_pt: Keyword.get(opts, :min_threshold_pt),
      max_threshold_pt: Keyword.get(opts, :max_threshold_pt),
      use_iqr: Keyword.get(opts, :use_iqr),
      min_samples: Keyword.get(opts, :min_samples)
    }
  end

  defp build_adaptive_threshold_option(other), do: other

  @typedoc """
  Options tuning `pdf_oxide`'s spatial table detector. Accepted directly by
  the `tables` functions, and as the `:table_detection` option of the `text`
  functions.

    * `:preset` — the base configuration every other key overrides:
      `:default`, `:strict` (demands ruling lines and regular rows) or
      `:relaxed` (tolerant, text-driven). Defaults to `:default`.
    * `:horizontal_strategy` / `:vertical_strategy` — what evidence
      delimits cells on that axis: `:lines` (ruling lines only), `:text`
      (glyph alignment only) or `:both`.
    * `:column_tolerance` / `:row_tolerance` — coordinate slack in points
      when grouping cells into columns and rows.
    * `:min_table_cells` / `:min_table_columns` — smallest grid accepted as
      a table.
    * `:max_table_columns` — reject anything wider as a false positive.
    * `:regular_row_ratio` — fraction of rows that must share the column
      count.
    * `:column_merge_threshold` — slack for the post-clustering column
      merge pass.
    * `:v_split_gap` — minimum gap between vertical-line groups that splits
      a cluster.
    * `:text_fallback` — allow text-only detection when a page has no
      ruling lines. Ignored on the `text` path, where upstream forces it to
      `false`.
    * `:enabled` — set to `false` to disable detection entirely.

  Every key except `:preset` defaults to `nil`, meaning "keep the preset's
  value". The Python bindings' `table_settings` dict reaches only five of
  these.
  """
  @type table_detection_opts :: [
          preset: :default | :strict | :relaxed,
          enabled: boolean() | nil,
          horizontal_strategy: :lines | :text | :both | nil,
          vertical_strategy: :lines | :text | :both | nil,
          column_tolerance: float() | nil,
          row_tolerance: float() | nil,
          min_table_cells: non_neg_integer() | nil,
          min_table_columns: non_neg_integer() | nil,
          regular_row_ratio: float() | nil,
          max_table_columns: non_neg_integer() | nil,
          column_merge_threshold: float() | nil,
          v_split_gap: float() | nil,
          text_fallback: boolean() | nil
        ]

  @typedoc """
  Options accepted by the `tables` and `tables!` functions: every
  `t:table_detection_opts/0` key, plus

    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the tables
      overlapping it. Defaults to `nil`. There is no `:region_mode`:
      upstream filters tables by bounding-box intersection only.

  Note that `:region` here keeps the detection options you passed, whereas
  `pdf_oxide`'s own region call silently substitutes its `:relaxed` preset.
  Pass `preset: :relaxed` to ask for that explicitly.
  """
  @type tables_opts :: [{:region, Rect.t() | nil} | {atom(), term()}]

  @doc """
  Detects tables, as `PdfElixide.Document.Table` structs.

  With a keyword list (or nothing) as the second argument, returns every
  page's tables concatenated into a single flat list, in page order. With a
  zero-based integer, returns that single page's tables instead.

      Document.tables(doc)
      Document.tables(doc, 0)
      Document.tables(doc, 0, preset: :strict, row_tolerance: 1.5)

  Detection is heuristic — see `PdfElixide.Document.Table` for the
  `:real_grid?` flag and how to filter out likely false positives, and
  `t:tables_opts/0` for the available options.
  """
  @spec tables(t()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  @spec tables(t(), tables_opts() | non_neg_integer()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  def tables(doc, page_index_or_opts \\ [])

  def tables(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_tables_options(opts)

    with {:ok, tables} <- Wrap.call(fn -> Native.document_all_tables(ref, options) end) do
      {:ok, Enum.map(tables, &Table.from_nif/1)}
    end
  end

  def tables(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    tables(doc, page_index, [])
  end

  @doc """
  Detects tables, raising an error if it fails.
  """
  @spec tables!(t()) :: [Table.t()]
  @spec tables!(t(), tables_opts() | non_neg_integer()) :: [Table.t()]
  def tables!(doc, page_index_or_opts \\ [])

  def tables!(%__MODULE__{} = doc, opts) when is_list(opts) do
    case tables(doc, opts) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  def tables!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    tables!(doc, page_index, [])
  end

  @doc """
  Detects the tables of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no detectable table. See
  `t:tables_opts/0` for the available options.
  """
  @spec tables(t(), non_neg_integer(), tables_opts()) :: {:ok, [Table.t()]} | {:error, Error.t()}
  def tables(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_tables_options(opts)

    with {:ok, tables} <- Wrap.call(fn -> Native.document_tables(ref, page_index, options) end) do
      {:ok, Enum.map(tables, &Table.from_nif/1)}
    end
  end

  @doc """
  Detects the tables of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec tables!(t(), non_neg_integer(), tables_opts()) :: [Table.t()]
  def tables!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    case tables(doc, page_index, opts) do
      {:ok, tables} -> tables
      {:error, error} -> raise error
    end
  end

  defp build_tables_options(opts) do
    %{
      detection: build_table_detection(opts),
      region: Keyword.get(opts, :region)
    }
  end

  defp build_table_detection_option(nil), do: nil

  defp build_table_detection_option(opts) when is_list(opts), do: build_table_detection(opts)

  defp build_table_detection_option(other), do: other

  defp build_table_detection(opts) do
    %{
      preset: Keyword.get(opts, :preset, :default),
      enabled: Keyword.get(opts, :enabled),
      horizontal_strategy: Keyword.get(opts, :horizontal_strategy),
      vertical_strategy: Keyword.get(opts, :vertical_strategy),
      column_tolerance: Keyword.get(opts, :column_tolerance),
      row_tolerance: Keyword.get(opts, :row_tolerance),
      min_table_cells: Keyword.get(opts, :min_table_cells),
      min_table_columns: Keyword.get(opts, :min_table_columns),
      regular_row_ratio: Keyword.get(opts, :regular_row_ratio),
      max_table_columns: Keyword.get(opts, :max_table_columns),
      column_merge_threshold: Keyword.get(opts, :column_merge_threshold),
      v_split_gap: Keyword.get(opts, :v_split_gap),
      text_fallback: Keyword.get(opts, :text_fallback)
    }
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

  Reads the page count cached on the struct, so it raises only for a document
  whose count could not be determined at open — see `page_count/1`.
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
