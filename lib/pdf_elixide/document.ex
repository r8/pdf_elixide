defmodule PdfElixide.Document do
  @moduledoc """
  Read-only representation of a PDF document.

  ## Sharing a document across processes

  A `%Document{}` is safe to pass to other processes. Operations that read the
  native document take its handle lock shared, so N processes extracting from
  one document do not queue on that lock. `version/1`, `source_path/1` and,
  normally, `page_count/1` read cached struct fields instead and take no native
  lock. `authenticate/2`, `clear_search_index/1` and `close/1` take the handle
  lock exclusively. The [Concurrency](guides/concurrency.md) guide has the rest,
  including contention inside the PDF reader and the tagged-PDF hazard that
  makes fanning out *by page* the shape to prefer.

  ## Whole-document extraction and memory

  Every extractor here has a whole-document arity. `chars/1`, `words/1`,
  `text_lines/1`, `spans/1`, `tables/1`, `paths/1`, `rects/1`, `lines/1`,
  `images/1`, `fonts/1` and `annotations/1` return one flat list, as does
  `search/2`; `text/1`, `to_markdown/1`, `to_html/1` and `to_plain_text/1`
  return a single string with the pages joined. Either shape walks all pages
  inside a **single** native call, so its cost scales with the whole document
  rather than with what the caller keeps. As the call returns, the result exists
  twice — natively and as the Elixir terms encoded from it — so peak usage is
  roughly double what the caller ends up holding. `search/2` given a
  `:max_results` is the one that need not walk every page; see
  `t:search_opts/0`.

  Three of them hold native memory *after* the call as well, since each returned
  struct carries a handle that BEAM memory accounting cannot see:

    * `images/1` — every image's decoded pixels, or its original JPEG bytes.
    * `fonts/1` — one handle per page per font, with no sharing across pages.
    * `tables/1` — the full detected table, including the per-glyph metrics the
      struct itself omits.

  On a large document, release them with `PdfElixide.Document.Image.close/1`,
  `PdfElixide.Document.Font.close/1` or `PdfElixide.Document.Table.close/1` as
  you finish with each.

  ### Working a page at a time

  `PdfElixide.Document` implements `Enumerable` over its pages, and
  `PdfElixide.Document.Page` offers every extractor, so bounding memory needs no
  extra API — only one page's results are live at a time, and one page is the
  floor:

      Stream.flat_map(doc, &Page.chars!/1)

  Concatenating pages this way reproduces the whole-document arity exactly for
  the list-returning extractors. The four that return one value do **not**,
  since each joins pages itself: `text/1` separates them with a form feed and
  applies `:on_page_error` (see `t:text_opts/0`), `to_markdown/1` and
  `to_plain_text/1` each join with a `---` break, and `to_html/1` wraps each
  page in a `<div class="page">`.

  ## Choosing an extractor for search and matching

  `text/1` infers word breaks from where glyphs sit, and can fuse neighbouring
  runs. In a generated report whose table cells are positioned independently, a
  row like

      Age  0.042  0.011  0.001

  is joined into one token, `"Age0.0420.0110.001"`.

  Whether the values survive that depends on `:extract_tables`, which defaults
  to `true`. A table the detector **recognises** is additionally rendered from
  its own cells, so the page text carries the values a second time, separated —
  they stay matchable, at the cost of appearing twice. Detection on this path
  keys on the table's ruling lines, so a table aligned only by whitespace is not
  recognised and its values appear in the fused form alone. Turning
  `:extract_tables` off removes the separated copy from every table, recognised
  or not, which is why it yields strictly less (see `t:text_opts/0`).

  **To find or match tokens rather than read the page, use `words/2`.** It is
  unaffected by either of those: it clusters characters by their own advance
  widths, so it returns `"Age"`, `"0.042"`, `"0.011"` and `"0.001"` separately
  and exactly once, each `PdfElixide.Document.Word` carrying the `bbox` to
  locate the hit. Prefer `search/2` when the query is known in advance.

  `to_plain_text/2` is a third reading of the same page — prose paragraphs
  rather than the page's visual lines. The [Text
  extraction](guides/text-extraction.md) guide says when it is the one you
  want.

  ## Page boxes and the coordinate origin

  Every coordinate this library reports — an extracted `bbox`, a path operation,
  an image's placement — is in the page's own PDF user space: a bottom-left
  origin, y increasing upward, measured in points.

  The sheet those coordinates fall on is the page's `/MediaBox`, read with
  `PdfElixide.Document.Page.media_box/1` as a `PdfElixide.Geometry.Rect`. Its
  origin is usually `{0.0, 0.0}`, but nothing requires that, and **content
  coordinates are not rebased on it**: a glyph at the very left edge of a page
  whose box starts at `{10.0, 20.0}` reports an `x` near `10.0`. Subtract the
  origin yourself when you want offsets from the page corner:

      box = PdfElixide.Document.Page.media_box!(page)
      {word.bbox.x - box.x, word.bbox.y - box.y}

  `PdfElixide.Document.Page.width/1` and `PdfElixide.Document.Page.height/1` are
  that rect's `:width` and `:height`. All three are normalized to non-negative
  dimensions, none is turned to match a rotated page (see below), and a page
  with no `/MediaBox` anywhere above it is an
  `%PdfElixide.Error{reason: :invalid_pdf}` rather than an assumed page size.
  There is no reader for `/CropBox`, `/BleedBox`, `/TrimBox` or `/ArtBox` on a
  read-only document.

  ### Which ancestor an inherited box comes from

  `/MediaBox` and `/Rotate` are inheritable: a page declaring neither takes them
  from an ancestor `/Pages` node, unambiguously where exactly one ancestor
  declares the entry. Where **two** nested ancestors declare it, which wins is
  not stable: the same page can report a different box, and a different
  rotation, on a later call. Almost all documents declare each entry at one
  level only and are unaffected.

  ## Rotated pages and extracted geometry

  A page may carry a `/Rotate` telling a viewer to display it turned — read it
  with `PdfElixide.Document.Page.rotation/1`. It does **not** mean every
  coordinate handed back is turned with it, and on a rotated page **the
  extractors do not all report in the same frame**:

    * `chars/1`, `spans/1`, `paths/1` — with `rects/1` and `lines/1`, which are
      the same values narrowed — and `images/1` stay in raw, unrotated user
      space, whatever the rotation.
    * `words/1`, `text_lines/1`, the cell boxes of `tables/1` and the boxes on a
      `search/2` match are mapped into the **displayed** frame.
      The mapping is selective: a `180`-degree page maps everything, while a
      `90`- or `270`-degree page maps only text whose own text matrix is
      rotated, leaving a horizontal run raw.

  So on a `180`-degree page, `spans/1` and `words/1` describing the very same
  line report mirrored boxes. Compare or lay out boxes from **one** extractor,
  and use `chars/1` or `spans/1` when raw page space is what you want. Page
  boxes are likewise never swapped, so computing the displayed page size is the
  caller's job. A caller that only wants text is unaffected — the distinction
  matters when bounding boxes do.
  """

  # `PdfElixide.Document.Path` — the vector-path struct — is deliberately left
  # unaliased: a bare `Path` alias shadows `Elixir.Path`, silently turning every
  # filesystem-path `Path.t()` in this module into the struct type.
  alias PdfElixide.Document.Annotation
  alias PdfElixide.Document.Char
  alias PdfElixide.Document.Font
  alias PdfElixide.Document.Image
  alias PdfElixide.Document.Metadata
  alias PdfElixide.Document.OutlineItem
  alias PdfElixide.Document.Page
  alias PdfElixide.Document.Permissions
  alias PdfElixide.Document.SearchMatch
  alias PdfElixide.Document.Span
  alias PdfElixide.Document.Table
  alias PdfElixide.Document.TextLine
  alias PdfElixide.Document.Word
  alias PdfElixide.Document.XmpMetadata
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap
  alias PdfElixide.Predicate

  # Spelled out rather than `defstruct @enforce_keys`, unlike the value structs:
  # `:page_count` is nil for a document whose page tree was unreadable at open,
  # and `:source_path` is nil for one built from a binary, so neither can be
  # enforced.
  @enforce_keys [:ref, :version]
  defstruct [:ref, :version, :page_count, :source_path]

  @typedoc """
  A handle on an open PDF document.

  `:version` and `:page_count` arrive with the handle, from the same native call
  that opens the document, and are served from the struct thereafter, since both
  are immutable for a read-only document.

  `:page_count` is `nil` when the count could not be determined at open — an
  encrypted document whose page tree needs a password, opened without one — in
  which case `page_count/1` asks the document instead.
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
      for the bang variants). When omitted or `nil`, only the empty password is
      tried automatically.

  The password is a *byte string*, not necessarily valid UTF-8: a password for
  a PDF of encryption revision 4 or lower is PDFDocEncoded, so
  `"caf" <> <<0xE9>>` is a legitimate password that no UTF-8 spelling can
  express. `authenticate/2` accepts and rejects exactly the same values.

  To *check* a password against an already-open document without treating a
  wrong one as an error, use `authenticate/2`, which returns `{:ok, false}`
  rather than a `:wrong_password` error.

  An unknown key, or a `:password` that is not a binary, raises `ArgumentError`
  — see the "Errors versus exceptions" section of `PdfElixide.Error`.
  """
  @type open_opts :: [password: binary()]

  @open_opts_keys [:password]

  @doc """
  Opens a PDF document from the specified file path.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec open(Path.t(), open_opts()) :: {:ok, t()} | {:error, Error.t()}
  def open(path, opts \\ []) when is_binary(path) and is_list(opts) do
    options = build_open_options(opts)

    with {:ok, {ref, version, page_count}} <-
           Wrap.call(fn -> Native.document_open(path, options) end) do
      {:ok,
       %__MODULE__{
         ref: ref,
         version: version,
         page_count: page_count,
         source_path: path
       }}
    end
  end

  @doc """
  Opens a PDF document from the specified file path, raising an error if it fails.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec open!(Path.t(), open_opts()) :: t()
  def open!(path, opts \\ []) when is_binary(path) and is_list(opts) do
    open(path, opts) |> Wrap.unwrap!()
  end

  @doc """
  Opens a PDF document from the given binary data.

  Takes bytes you already have — an HTTP response body, a database blob — so no
  path is involved; use `open/2` to read a file. `source_path/1` is `nil` for the
  resulting document.
  """
  @spec from_binary(binary(), open_opts()) :: {:ok, t()} | {:error, Error.t()}
  def from_binary(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    options = build_open_options(opts)

    with {:ok, {ref, version, page_count}} <-
           Wrap.call(fn -> Native.document_from_bytes(bytes, options) end) do
      {:ok,
       %__MODULE__{
         ref: ref,
         version: version,
         page_count: page_count,
         source_path: nil
       }}
    end
  end

  @doc """
  Opens a PDF document from the given binary data, raising an error if it fails.

  Takes bytes you already have — an HTTP response body, a database blob — so no
  path is involved; use `open!/2` to read a file.
  """
  @spec from_binary!(binary(), open_opts()) :: t()
  def from_binary!(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    from_binary(bytes, opts) |> Wrap.unwrap!()
  end

  defp build_open_options(opts) do
    opts = Keyword.validate!(opts, @open_opts_keys)
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

  A document holds its PDF data in memory on the Rust side, normally freed only
  when the BEAM garbage-collects the handle. `close/1` frees it now, which
  matters for long-lived processes that open many documents. Calling it is
  optional and idempotent.

  It takes the handle's lock *exclusively*, where reads take it shared, so it
  waits for every in-flight call on the same document — and an extraction can
  hold its share of that lock for seconds. *Immediately* means as soon as the
  handle is idle, not preemptively. That is one of the exclusive calls the
  [Concurrency](guides/concurrency.md) guide is about.

  Afterwards, functions that read the document return
  `{:error, %PdfElixide.Error{reason: :closed}}`, and their bang variants raise
  it. `version/1`, `source_path/1` and `page_count/1` keep working, since they
  read the struct rather than the native handle — `page_count/1` only for a
  document whose count was determined at open. Any
  `PdfElixide.Document.Image`, `PdfElixide.Document.Font` or
  `PdfElixide.Document.Table` handles already extracted from the document remain
  valid, owning their data independently.

      doc = Document.open!("sample.pdf")
      text = Document.text!(doc, 0)
      :ok = Document.close(doc)

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

  The count arrives with the handle from the call that opens the document and is
  cached on the struct, so this normally costs nothing and keeps working after
  `close/1`, as `version/1` does.

  The exception is a document whose page tree could not be read at open — an
  encrypted one opened without a password. Nothing is cached for it, so the
  count is read from the document on every call: an error until `authenticate/2`
  succeeds, and the real count afterwards.
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
    page_count(doc) |> Wrap.unwrap!()
  end

  @doc """
  Returns whether the PDF document is a Tagged PDF with a structure tree.

  Answers `false` for a document whose structure tree cannot be *read* as well
  as for one that has none: a corrupt `/StructTreeRoot` is reported the same way
  an untagged document is. Use `has_structure_tree/1` to tell the two apart. A
  handle that cannot be used at all — a closed document, a native panic — still
  raises.
  """
  @spec has_structure_tree?(t()) :: boolean()
  def has_structure_tree?(%__MODULE__{ref: ref}) do
    Predicate.tolerant!(fn -> Native.document_has_structure_tree(ref) end)
  end

  @doc """
  Returns whether the PDF document is a Tagged PDF with a structure tree,
  reporting a structure tree that cannot be read.

  The strict counterpart of `has_structure_tree?/1`, which cannot distinguish
  `false` from a failure. This keeps the three states apart: tagged
  (`{:ok, true}`), untagged (`{:ok, false}`) and unparseable
  (`{:error, %PdfElixide.Error{}}`).
  """
  @spec has_structure_tree(t()) :: {:ok, boolean()} | {:error, Error.t()}
  def has_structure_tree(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_has_structure_tree(ref) end)
  end

  @doc """
  Returns whether the PDF document contains XFA (XML Forms Architecture) form data.

  Answers `false` for a document whose catalog or `/AcroForm` entry cannot be
  read as well as for one that carries no XFA. Use `has_xfa/1` to tell the two
  apart; a closed document or a native panic still raises.
  """
  @spec has_xfa?(t()) :: boolean()
  def has_xfa?(%__MODULE__{ref: ref}) do
    Predicate.tolerant!(fn -> Native.document_has_xfa(ref) end)
  end

  @doc """
  Returns whether the PDF document contains XFA (XML Forms Architecture) form
  data, reporting a catalog that cannot be read.

  The strict counterpart of `has_xfa?/1`. Only a *broken* document reaches the
  error: every structural absence — a catalog that is not a dictionary, a
  missing `/AcroForm`, a missing `/XFA` — already answers `{:ok, false}`.
  """
  @spec has_xfa(t()) :: {:ok, boolean()} | {:error, Error.t()}
  def has_xfa(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_has_xfa(ref) end)
  end

  @doc """
  Returns whether the PDF document is encrypted.

  A closed document or a native panic raises — see the "Errors versus
  exceptions" section of `PdfElixide.Error`. Nothing else can fail here.
  """
  @spec encrypted?(t()) :: boolean()
  def encrypted?(%__MODULE__{ref: ref}) do
    # A predicate returns a bare boolean, so a NIF failure — a closed document,
    # a poisoned lock — has nowhere to go but a raise, as the bang variants do.
    # `Wrap.call!/1` rather than `Wrap.unwrap!/1` because there is no non-bang
    # counterpart here to have run `Wrap.call/1` already.
    Wrap.call!(fn -> Native.document_is_encrypted(ref) end)
  end

  # Validate the semantic range here so it raises the same `ArgumentError` as
  # other bad option values; the NIF keeps the same check as defence in depth.
  defp validate_region_mode!(opts, key) do
    case Keyword.get(opts, key, :intersects) do
      {:min_overlap, ratio} when is_number(ratio) and (ratio < 0.0 or ratio > 1.0) ->
        raise ArgumentError,
              "invalid :#{key} {:min_overlap, #{inspect(ratio)}}: " <>
                "the ratio must be between 0.0 and 1.0"

      mode ->
        mode
    end
  end

  @doc """
  Authenticates against the document's encryption with the given password.

  Returns `{:ok, true}` if authentication succeeded (or the PDF is not encrypted),
  `{:ok, false}` if the password was wrong, or `{:error, reason}` on a PDF/crypto error.

  This is a password *check*, so a wrong password is a normal `{:ok, false}`
  result — unlike `open/2`'s `:password` option, where it is an
  `{:error, %PdfElixide.Error{reason: :wrong_password}}` because the document
  cannot be produced.

  The password is a byte string and is not required to be valid UTF-8 — see
  `t:open_opts/0`, whose `:password` option takes the same values.

  An encrypted document read *before* it is authenticated extracts as empty —
  `text/2` answers `""`, `search/2` answers `[]`. A first successful
  authentication reloads the document, so everything after it answers as though
  the handle had been opened with `open/2`'s `:password`, and it costs about what
  opening the document cost — a rejected password too.

  Like `clear_search_index/1` and `close/1`, and unlike every other read here,
  this takes the document's lock *exclusively*, so it waits for in-flight calls
  on the handle and blocks new ones for its duration. Authenticate before
  sharing the document with other processes, not after — see the
  [Concurrency](guides/concurrency.md) guide.
  """
  @spec authenticate(t(), binary()) :: {:ok, boolean()} | {:error, Error.t()}
  def authenticate(%__MODULE__{ref: ref}, password) when is_binary(password) do
    Wrap.call(fn -> Native.document_authenticate(ref, password) end)
  end

  @doc """
  Same as `authenticate/2` but raises on error.

  Still returns `false` (does not raise) for a wrong password.
  """
  @spec authenticate!(t(), binary()) :: boolean()
  def authenticate!(doc, password) when is_binary(password) do
    authenticate(doc, password) |> Wrap.unwrap!()
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
    metadata(doc) |> Wrap.unwrap!()
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
    xmp_metadata(doc) |> Wrap.unwrap!()
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
    permissions(doc) |> Wrap.unwrap!()
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
    page_labels(doc) |> Wrap.unwrap!()
  end

  @doc """
  Lists the names of the optional-content groups (OCG layers) the document
  declares — the values `:exclude_layers` accepts, see `t:text_opts/0`. Pass one
  back **unchanged** rather than retyping it; the filter matches the exact string.

  They arrive in `/OCGs` order, **neither sorted nor deduplicated**, so a display
  name two groups share appears twice. A group that cannot be read or declares no
  name is skipped, and a document with no optional content yields `{:ok, []}`.

  The list is not exhaustive of what `:exclude_layers` acts on: filtering matches
  whatever group a page's content references, declared here or not.
  """
  @spec layers(t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def layers(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_layers(ref) end)
  end

  @doc """
  Lists the document's optional-content group names, raising an error if it fails.
  """
  @spec layers!(t()) :: [String.t()]
  def layers!(%__MODULE__{} = doc) do
    layers(doc) |> Wrap.unwrap!()
  end

  @typedoc """
  Options for `inks/3`.

    * `:deep` — also walk into the Form XObjects the page's content stream
      invokes, returning every ink reachable from the page rather than only
      those it declares itself. Defaults to `false`.

  The default reads the page's own `/Resources` and nothing else, so it can
  **miss inks the page actually paints with** — a colorant declared inside a
  Form XObject's own resources is absent from the list even though the
  extraction filters still honor it. `deep: true` returns the complete set.

  What it costs is failure modes: `deep: true` parses the page's content stream
  and every form's, so it reports an error where the default would have
  succeeded — an undecryptable or malformed stream, or an XObject tree nested
  deeper than the parser follows. Prefer the default when the page's own
  declarations are enough, and `deep: true` when building a picker a user will
  choose from.
  """
  @type inks_opts :: [deep: boolean()]

  @inks_opts_keys [:deep]

  @doc """
  Lists the Separation and DeviceN ink names the page at the given zero-based
  index declares — the values `:exclude_inks` accepts, see `t:text_opts/0`.
  Sorted and deduplicated.

  Only the page's own `/Resources` is read unless `t:inks_opts/0`'s `:deep` is
  set, which is where that trade-off is explained.

  Some names never appear: `All` and `None`, DeviceN colorants the colour space
  declares to be process components, and colorants declared only inside a pattern
  object's own resources or an annotation's appearance stream.

  Returns `{:ok, []}` for a page that declares no colour spaces. There is no
  whole-document arity — take the union yourself:

      doc |> Enum.flat_map(&PdfElixide.Document.Page.inks!(&1, deep: true)) |> Enum.uniq()

  """
  @spec inks(t(), non_neg_integer(), inks_opts()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def inks(%__MODULE__{ref: ref}, page_index, opts \\ [])
      when is_integer(page_index) and page_index >= 0 do
    options = build_inks_options(opts)
    Wrap.call(fn -> Native.document_page_inks(ref, page_index, options) end)
  end

  @doc """
  Lists the page's ink names, raising an error if it fails.
  """
  @spec inks!(t(), non_neg_integer(), inks_opts()) :: [String.t()]
  def inks!(doc, page_index, opts \\ [])
      when is_integer(page_index) and page_index >= 0 do
    inks(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_inks_options(opts) do
    opts = Keyword.validate!(opts, @inks_opts_keys)
    %{deep: Keyword.get(opts, :deep, false)}
  end

  @typedoc """
  How a `:region` (or `:exclude_regions`) decides whether an object is inside
  it.

    * `:intersects` — any overlap at all counts. This is the default.
    * `:fully_contained` — the object's bounding box must lie entirely
      within the region.
    * `{:min_overlap, ratio}` — at least `ratio` of the object's area must
      lie within the region.

  `ratio` must be between `0.0` and `1.0`; anything outside that range raises
  `ArgumentError`, like any other bad option value. Two behaviors are worth
  knowing before choosing one:

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
      space-padded, column-aligned rows. Defaults to `true`. The rendered rows
      are emitted *in addition to* the page's own text for those regions, so a
      recognised table's values appear twice — once fused, once separated — and
      the padding is collapsed to single spaces before the text is returned.
      Keep it on: that separated copy is what keeps a table's values
      searchable — see "Choosing an extractor for search and
      matching" in `PdfElixide.Document`, which also covers when to reach for
      `words/2` instead.
    * `:expand_ligatures` — expand `U+FB00`–`U+FB06` ligatures to their
      component letters (`ﬁ` to `fi`, and so on). Defaults to `false`.
      Unlike in `t:markdown_opts/0`, it is live here.
    * `:table_detection` — a keyword list tuning the spatial table
      detector; see `t:table_detection_opts/0`. Only consulted when
      `:extract_tables` is `true`, and its `:text_fallback` key is ignored
      here: the text path always disables it, so a page with no ruling lines
      yields no tables regardless. Defaults to `nil`.
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
      suppress, as listed by `layers/1`. Defaults to `[]`.
    * `:exclude_inks` — names of Separation/DeviceN inks to suppress, as
      listed by `inks/3`. Defaults to `[]`.
    * `:on_page_error` — what a page that fails to extract does to the
      whole-document result: `:skip` it (the default) or `:halt`, failing the
      call with the first page's error. See below.

  ## `:on_page_error` and partly extractable documents

  Read **only on the whole-document arity**; `text/3` and
  `PdfElixide.Document.Page.text/2` extract one page and always return its
  error. Under the `:skip` default a failed page contributes an empty string,
  its page separator is emitted either way, and the call still returns
  `{:ok, text}` with content silently missing. `:halt` instead fails the call
  with `{:error, %PdfElixide.Error{}}`, the failing page's zero-based index
  prefixed to the message.

  `:halt` is not a general corruption detector, though: almost every damaged
  page degrades to empty text rather than an error — an undecodable content
  stream, missing fonts, a scan with no text layer and an undecryptable
  document all extract as `""`. All it can catch is a page whose page-tree entry
  does not resolve at all, which the other whole-document extractors fail on
  unconditionally, except `fonts/1`, which skips it.

  ## Layer and ink filtering drops the other options

  When `:exclude_layers` or `:exclude_inks` is non-empty,
  **only `:region` and `:region_mode` still apply** — `:extract_tables`,
  `:expand_ligatures`, `:table_detection`, `:exclude_regions` and
  `:exclude_regions_mode` fall back to their defaults
  (`:extract_tables` to `true`, the rest to off).

  `:reading_order`, `:include_form_fields` and
  `:strip_running_headers_footers` are valid for `to_markdown/2` but not here,
  since the text assembler never reads them; passing one raises
  `ArgumentError`, as any other undeclared key does.

  There is a second way to read a page as text — `to_plain_text/2`, which
  returns reflowed paragraphs rather than the page's visual lines and takes a
  different, smaller set of options. The [Text
  extraction](guides/text-extraction.md) guide compares the two.
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
          exclude_inks: [String.t()],
          on_page_error: :skip | :halt
        ]

  @text_opts_keys [
    :extract_tables,
    :expand_ligatures,
    :table_detection,
    :region,
    :region_mode,
    :exclude_regions,
    :exclude_regions_mode,
    :exclude_layers,
    :exclude_inks,
    :on_page_error
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

  A page that fails to extract contributes an empty string to the
  whole-document result rather than failing the call. Its separator is emitted
  regardless, so a document with at least one page splits into exactly
  `page_count/1` parts and a skipped page reads as a blank one. A document with
  no pages returns `""`. Pass `on_page_error: :halt` to fail the call instead.

  The whole-document form builds every page's text in memory at once — see the
  "Whole-document extraction and memory" section of `PdfElixide.Document`.

  See `t:text_opts/0` for the available options.
  """
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
  @spec text!(t(), text_opts() | non_neg_integer()) :: String.t()
  def text!(doc, page_index_or_opts \\ [])

  def text!(%__MODULE__{} = doc, opts) when is_list(opts) do
    text(doc, opts) |> Wrap.unwrap!()
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
    text(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_text_options(opts) do
    opts = Keyword.validate!(opts, @text_opts_keys)

    %{
      extract_tables: Keyword.get(opts, :extract_tables, true),
      expand_ligatures: Keyword.get(opts, :expand_ligatures, false),
      table_detection: build_table_detection_option(Keyword.get(opts, :table_detection)),
      region: Keyword.get(opts, :region),
      region_mode: validate_region_mode!(opts, :region_mode),
      exclude_regions: Keyword.get(opts, :exclude_regions, []),
      exclude_regions_mode: validate_region_mode!(opts, :exclude_regions_mode),
      exclude_layers: Keyword.get(opts, :exclude_layers, []),
      exclude_inks: Keyword.get(opts, :exclude_inks, []),
      on_page_error: Keyword.get(opts, :on_page_error, :skip)
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
      only when `:include_images` is `true` and `:embed_images` is `false`.
      It is created if missing, and one that cannot be created is an `:io`
      error; the writes themselves are best-effort, since an image that
      fails to encode or write is dropped. Defaults to `nil`.

      This is a `t:String.t/0` and **not** a path in the sense the "File
      paths" section of `PdfElixide` describes: it is also pasted into the
      `src` attribute of every generated image reference, so it must be
      valid UTF-8 and a value that is not raises `ArgumentError` naming the
      key. A directory whose name has no UTF-8 spelling cannot be used here
      even where the filesystem allows one.

      **Give every concurrent conversion its own directory.** Filenames are
      fixed — `pageN_M.png`, one-based page then one-based position in that
      page's *kept* image list — so two conversions writing to one directory
      overwrite each other's files, non-atomically. That includes two
      conversions of the same document, since `:max_image_pixels` changes
      which images are kept and so renumbers the rest.
    * `:include_form_fields` — inline AcroForm field values at their
      positions on the page. Defaults to `true`.
    * `:strip_running_headers_footers` — drop text lines that repeat in
      the top/bottom band of a majority of pages. Defaults to `false`.
    * `:expand_ligatures` — expand `U+FB00`–`U+FB06` ligatures to their
      component letters (`ﬁ` to `fi`, and so on). Accepted for forward
      compatibility, but currently has **no effect** on Markdown output; it is
      applied only on the plain-text path used by `text/2`. Defaults to `false`.
    * `:annotate_skipped_pages` — emit a block quote naming any page that
      is a scan with no usable text layer, rather than rendering it blank.
      Defaults to `true`.
    * `:max_image_pixels` — skip images whose width times height exceeds
      this count. `nil` means the built-in 16 MP limit, not "no
      limit" — pass a large integer to lift it, or `0` to skip every
      image. Defaults to `nil`.
    * `:reading_order` — how text blocks are ordered:
      `:structure_tree` (follow a tagged PDF's structure tree, falling
      back to an XY-cut), `:column_aware`, or `:top_to_bottom`. Defaults
      to `:structure_tree`.
    * `:bold_markers` — `:conservative` applies `**` only to
      content-bearing text; `:aggressive` also wraps whitespace-only
      spans. Defaults to `:conservative`.

  Calling `to_markdown/1` is equivalent to `to_markdown/2` with no options.

  An unknown key, or a declared key given a value of the wrong type, raises
  `ArgumentError` naming the offending key; see the "Errors versus exceptions"
  section of `PdfElixide.Error`.
  """
  @type markdown_opts :: [
          detect_headings: boolean(),
          extract_tables: boolean(),
          include_images: boolean(),
          embed_images: boolean(),
          image_output_dir: String.t() | nil,
          include_form_fields: boolean(),
          strip_running_headers_footers: boolean(),
          expand_ligatures: boolean(),
          annotate_skipped_pages: boolean(),
          max_image_pixels: non_neg_integer() | nil,
          reading_order: :structure_tree | :column_aware | :top_to_bottom,
          bold_markers: :conservative | :aggressive
        ]

  @markdown_opts_keys [
    :detect_headings,
    :extract_tables,
    :include_images,
    :embed_images,
    :image_output_dir,
    :include_form_fields,
    :strip_running_headers_footers,
    :expand_ligatures,
    :annotate_skipped_pages,
    :max_image_pixels,
    :reading_order,
    :bold_markers
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

  The whole-document form builds the entire conversion in memory at once, which
  `:include_images` can make considerably larger — see the "Whole-document
  extraction and memory" section of `PdfElixide.Document`.

  See `t:markdown_opts/0` for the available options.
  """
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
  @spec to_markdown!(t(), markdown_opts() | non_neg_integer()) :: String.t()
  def to_markdown!(doc, page_index_or_opts \\ [])

  def to_markdown!(%__MODULE__{} = doc, opts) when is_list(opts) do
    to_markdown(doc, opts) |> Wrap.unwrap!()
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
    to_markdown(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_markdown_options(opts) do
    opts = Keyword.validate!(opts, @markdown_opts_keys)

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

  Only options that affect HTML output are exposed. `:bold_markers`,
  `:annotate_skipped_pages`, `:strip_running_headers_footers` and
  `:expand_ligatures` — all valid for `to_markdown/2` — are therefore absent
  here, and passing one raises `ArgumentError`, as does a declared key given a
  value of the wrong type. See the "Errors versus exceptions" section of
  `PdfElixide.Error`.

    * `:preserve_layout` — emit one absolutely positioned `<div>` per text
      span, carrying that span's coordinates and font size in inline CSS
      (`pt` units), in place of the semantic flow of `<p>`/`<h1>`/`<ul>`
      elements. Colour is written only for non-black text. This mode emits
      *only* those positioned spans: headings, lists and tables are not
      produced, so `:detect_headings` and `:extract_tables` have no effect
      under it. Defaults to `false`.

      The result is **not** directly renderable and needs two corrections from
      you. The generated CSS uses the PDF's own user-space coordinates
      verbatim, so `top` is measured from the *bottom* of the page while CSS `top` measures
      from the top: flip it with `top = height - y`, taking the page height
      from `PdfElixide.Document.Page.height/1`. And the per-page wrapper
      `to_html/1` emits carries no styling, so it is not a positioned
      containing block — add `position: relative` and an explicit size to each
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
      only when `:include_images` is `true` and `:embed_images` is `false`.
      Behaves exactly as it does for Markdown, including the
      filename-collision caveat and the requirement that it be valid UTF-8
      rather than an arbitrary path — see `t:markdown_opts/0`. Defaults to
      `nil`.

      It is interpolated into the `src` attribute **without HTML
      escaping**, so a directory whose name contains `"` or `&` produces
      malformed markup and a crafted one can inject attributes. Never build
      it from untrusted input. It is the only unescaped input here — see the
      "Escaping" section of `to_html/2`.
    * `:include_form_fields` — inline AcroForm field values at their
      positions on the page. Defaults to `true`.
    * `:max_image_pixels` — skip images whose width times height exceeds
      this count. `nil` means the built-in 16 MP limit, not "no
      limit" — pass a large integer to lift it, or `0` to skip every
      image. Defaults to `nil`.
    * `:reading_order` — how text blocks are ordered:
      `:structure_tree` (follow a tagged PDF's structure tree, falling
      back to an XY-cut), `:column_aware`, or `:top_to_bottom`. Defaults
      to `:structure_tree`.

  Calling `to_html/1` is equivalent to `to_html/2` with no options.
  """
  @type html_opts :: [
          preserve_layout: boolean(),
          detect_headings: boolean(),
          extract_tables: boolean(),
          include_images: boolean(),
          embed_images: boolean(),
          image_output_dir: String.t() | nil,
          include_form_fields: boolean(),
          max_image_pixels: non_neg_integer() | nil,
          reading_order: :structure_tree | :column_aware | :top_to_bottom
        ]

  @html_opts_keys [
    :preserve_layout,
    :detect_headings,
    :extract_tables,
    :include_images,
    :embed_images,
    :image_output_dir,
    :include_form_fields,
    :max_image_pixels,
    :reading_order
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

  The whole-document form builds the entire conversion in memory at once, which
  `:include_images` can make considerably larger — see the "Whole-document
  extraction and memory" section of `PdfElixide.Document`.

  ## Escaping

  Text taken from the PDF is escaped before it reaches the fragment — `&`, `<`,
  `>` and `"` become entities in span text, headings and table cells alike, in
  `:preserve_layout` mode as well — so a crafted document cannot inject markup.
  `'` is left as-is, which is safe only because every attribute the converter
  emits is double-quoted: **don't re-quote the fragment with single quotes**.

  A `/Link` annotation's URI is escaped too, and an anchor is emitted only for
  the `http`, `https`, `mailto`, `tel`, `ftp` and `ftps` schemes; any other
  target keeps its link text and loses the link. Anchors carry
  `rel="noopener noreferrer"`.

  The one input that is **not** escaped is `:image_output_dir`; see
  `t:html_opts/0`. So the fragment is safe to render as raw HTML as long as that
  path is yours and not an untrusted one.

  See `t:html_opts/0` for the available options.
  """
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
  @spec to_html!(t(), html_opts() | non_neg_integer()) :: String.t()
  def to_html!(doc, page_index_or_opts \\ [])

  def to_html!(%__MODULE__{} = doc, opts) when is_list(opts) do
    to_html(doc, opts) |> Wrap.unwrap!()
  end

  def to_html!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_html!(doc, page_index, [])
  end

  @doc """
  Converts the page at the given zero-based index to HTML.

  See `t:html_opts/0` for the available options, and the "Escaping"
  section of `to_html/2` for what in the fragment is escaped.
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
    to_html(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_html_options(opts) do
    opts = Keyword.validate!(opts, @html_opts_keys)

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
  Options accepted by the `to_plain_text` and `to_plain_text!` functions.

    * `:extract_tables` — detect tables and render them inline as
      space-padded, column-aligned rows. Defaults to `true`.
    * `:table_detection` — a keyword list tuning the spatial table
      detector; see `t:table_detection_opts/0`. Only consulted when
      `:extract_tables` is `true`, and its `:text_fallback` key is ignored
      here just as it is for `text/2`: this path always disables it, so a page
      with no ruling lines yields no tables regardless. Defaults to `nil`.
    * `:reading_order` — how text blocks are ordered: `:structure_tree`,
      `:column_aware` or `:top_to_bottom`. Defaults to `:structure_tree`.
      On an untagged document, `:structure_tree` and `:column_aware` produce
      the same column-aware order; `:top_to_bottom` does not detect columns.
    * `:include_form_fields` — inline AcroForm field values at their
      positions on the page. Defaults to `true`. `text/2` has no such option
      and always includes them.

  `:reading_order` and `:include_form_fields` have no effect when a trustworthy
  structure tree supplies the reading order. The [Text
  extraction](guides/text-extraction.md) guide covers that case and compares
  these options with `t:text_opts/0`.

  Calling `to_plain_text/1` is equivalent to `to_plain_text/2` with no options.

  An unknown key, or a declared key given a value of the wrong type, raises
  `ArgumentError` naming the offending key; see the "Errors versus exceptions"
  section of `PdfElixide.Error`.
  """
  @type plain_text_opts :: [
          extract_tables: boolean(),
          table_detection: table_detection_opts() | nil,
          reading_order: :structure_tree | :column_aware | :top_to_bottom,
          include_form_fields: boolean()
        ]

  @plain_text_opts_keys [
    :extract_tables,
    :table_detection,
    :reading_order,
    :include_form_fields
  ]

  @doc """
  Converts the document to plain text.

  This generally reflows prose paragraphs and orders them by detected column;
  tables and some columnar layouts retain internal line breaks. `text/2`
  instead preserves inferred visual rows. The [Text
  extraction](guides/text-extraction.md) guide compares the two.

  With a keyword list (or nothing) as the second argument, converts the whole
  document, joining pages with `"\\n\\n---\\n\\n"` — close to the `---` break
  `to_markdown/1` uses, and not the form feed of `text/1`. With a zero-based
  integer, converts that single page instead.

      Document.to_plain_text(doc)
      Document.to_plain_text(doc, extract_tables: false)
      Document.to_plain_text(doc, 0)

  There is no `:on_page_error` here: a page that cannot be converted fails the
  whole call, as it does for `to_markdown/1` and `to_html/1`. `text/1` is the
  only whole-document text call that can skip one. A document that is
  encrypted and could not be decrypted converts to an empty string rather than
  failing.

  The whole-document form builds the entire conversion in memory at once — see
  the "Whole-document extraction and memory" section of `PdfElixide.Document`.

  See `t:plain_text_opts/0` for the available options.
  """
  @spec to_plain_text(t(), plain_text_opts() | non_neg_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_plain_text(doc, page_index_or_opts \\ [])

  def to_plain_text(%__MODULE__{ref: ref}, opts) when is_list(opts) do
    options = build_plain_text_options(opts)
    Wrap.call(fn -> Native.document_to_plain_text_all(ref, options) end)
  end

  def to_plain_text(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_plain_text(doc, page_index, [])
  end

  @doc """
  Converts the document to plain text, raising an error if it fails.
  """
  @spec to_plain_text!(t(), plain_text_opts() | non_neg_integer()) :: String.t()
  def to_plain_text!(doc, page_index_or_opts \\ [])

  def to_plain_text!(%__MODULE__{} = doc, opts) when is_list(opts) do
    to_plain_text(doc, opts) |> Wrap.unwrap!()
  end

  def to_plain_text!(%__MODULE__{} = doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    to_plain_text!(doc, page_index, [])
  end

  @doc """
  Converts the page at the given zero-based index to plain text.

  See `t:plain_text_opts/0` for the available options, and `to_plain_text/2`
  for how this differs from `text/3`.
  """
  @spec to_plain_text(t(), non_neg_integer(), plain_text_opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def to_plain_text(%__MODULE__{ref: ref}, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    options = build_plain_text_options(opts)
    Wrap.call(fn -> Native.document_to_plain_text(ref, page_index, options) end)
  end

  @doc """
  Converts the page at the given zero-based index to plain text, raising an
  error if it fails.
  """
  @spec to_plain_text!(t(), non_neg_integer(), plain_text_opts()) :: String.t()
  def to_plain_text!(doc, page_index, opts)
      when is_integer(page_index) and page_index >= 0 and is_list(opts) do
    to_plain_text(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_plain_text_options(opts) do
    opts = Keyword.validate!(opts, @plain_text_opts_keys)

    %{
      extract_tables: Keyword.get(opts, :extract_tables, true),
      table_detection: build_table_detection_option(Keyword.get(opts, :table_detection)),
      reading_order: Keyword.get(opts, :reading_order, :structure_tree),
      include_form_fields: Keyword.get(opts, :include_form_fields, true)
    }
  end

  @typedoc """
  A span-extraction tuning preset. A profile changes the TJ-offset and
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
      §14.8.2.2.1). Defaults to `true`; `false` selects the spec-correct
      variant.
    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the words
      inside it. Defaults to `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:word_gap_threshold` — the inter-glyph gap in points that starts a
      new word. `nil` computes it adaptively from page
      statistics (median character width × 0.3). Defaults to `nil`.
    * `:profile` — a `t:extraction_profile/0`, or `nil` for none.
      Defaults to `nil`.

  ## Legacy extraction controls

  `:word_gap_threshold` and `:profile` are retained for compatibility. Passing
  *any* profile switches to a legacy ordering path, so it can change word
  **order**, not merely word boundaries — even for `:conservative`, nominally
  the default profile. Prefer leaving both at `nil`.

  `:region` composes with everything else here: it is applied after
  extraction, so it does not discard the thresholds or the profile.
  """
  @type words_opts :: [
          include_artifacts: boolean(),
          region: Rect.t() | nil,
          region_mode: region_mode(),
          word_gap_threshold: float() | nil,
          profile: extraction_profile() | nil
        ]

  @words_opts_keys [:include_artifacts, :region, :region_mode, :word_gap_threshold, :profile]

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

  The whole-document form builds every page's words in memory at once — see the
  "Whole-document extraction and memory" section of `PdfElixide.Document` for
  when to prefer the per-page arity.

  See `t:words_opts/0` for the available options.
  """
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
  @spec words!(t(), words_opts() | non_neg_integer()) :: [Word.t()]
  def words!(doc, page_index_or_opts \\ [])

  def words!(%__MODULE__{} = doc, opts) when is_list(opts) do
    words(doc, opts) |> Wrap.unwrap!()
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
    words(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_words_options(opts) do
    opts = Keyword.validate!(opts, @words_opts_keys)

    %{
      include_artifacts: Keyword.get(opts, :include_artifacts, true),
      word_gap_threshold: Keyword.get(opts, :word_gap_threshold),
      profile: Keyword.get(opts, :profile),
      region: Keyword.get(opts, :region),
      region_mode: validate_region_mode!(opts, :region_mode)
    }
  end

  @typedoc """
  Options accepted by the `text_lines` and `text_lines!` functions.

  The same options as `t:words_opts/0` — including the legacy controls
  `:word_gap_threshold` and `:profile` documented there — plus:

    * `:line_gap_threshold` — the vertical gap in points that starts a new
      line. `nil` computes it automatically. Defaults to `nil`; like the other
      two legacy controls, prefer leaving it unset.
  """
  @type text_lines_opts :: [
          include_artifacts: boolean(),
          region: Rect.t() | nil,
          region_mode: region_mode(),
          word_gap_threshold: float() | nil,
          line_gap_threshold: float() | nil,
          profile: extraction_profile() | nil
        ]

  @text_lines_opts_keys [:line_gap_threshold | @words_opts_keys]

  @doc """
  Extracts text lines, each with its bounding box and constituent words as a
  `PdfElixide.Document.TextLine` struct.

  With a keyword list (or nothing) as the second argument, returns every
  page's lines concatenated into a single flat list, in page order. With a
  zero-based integer, returns that single page's lines instead.

      Document.text_lines(doc)
      Document.text_lines(doc, include_artifacts: false)
      Document.text_lines(doc, 0)
      Document.text_lines(doc, 0, region: heading.bbox)

  The whole-document form builds every page's lines in memory at once — see the
  "Whole-document extraction and memory" section of `PdfElixide.Document` for
  when to prefer the per-page arity.

  See `t:text_lines_opts/0` for the available options.
  """
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
  @spec text_lines!(t(), text_lines_opts() | non_neg_integer()) :: [TextLine.t()]
  def text_lines!(doc, page_index_or_opts \\ [])

  def text_lines!(%__MODULE__{} = doc, opts) when is_list(opts) do
    text_lines(doc, opts) |> Wrap.unwrap!()
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
    text_lines(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_text_lines_options(opts) do
    opts = Keyword.validate!(opts, @text_lines_opts_keys)

    %{
      include_artifacts: Keyword.get(opts, :include_artifacts, true),
      word_gap_threshold: Keyword.get(opts, :word_gap_threshold),
      line_gap_threshold: Keyword.get(opts, :line_gap_threshold),
      profile: Keyword.get(opts, :profile),
      region: Keyword.get(opts, :region),
      region_mode: validate_region_mode!(opts, :region_mode)
    }
  end

  @typedoc """
  Options accepted by the `chars` and `chars!` functions.

    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the characters
      inside it. Defaults to `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:exclude_layers` — names of optional-content (OCG) layers to
      suppress, as listed by `layers/1`. Defaults to `[]`.
    * `:exclude_inks` — names of Separation/DeviceN inks to suppress, as
      listed by `inks/3`. Defaults to `[]`.
  """
  @type chars_opts :: [
          region: Rect.t() | nil,
          region_mode: region_mode(),
          exclude_layers: [String.t()],
          exclude_inks: [String.t()]
        ]

  @chars_opts_keys [:region, :region_mode, :exclude_layers, :exclude_inks]

  @doc """
  Extracts characters, each with its bounding box, font metadata and
  typographic placement as a `PdfElixide.Document.Char` struct.

  With a keyword list (or nothing) as the second argument, returns every
  page's characters concatenated into a single flat list, in page order. With
  a zero-based integer, returns that single page's characters instead.

      Document.chars(doc)
      Document.chars(doc, region: heading.bbox)
      Document.chars(doc, 0)
      Document.chars(doc, 0, region_mode: :fully_contained)

  This is the most memory-hungry extractor here — one struct per glyph, each
  carrying its own text and font-name binary — so the whole-document form is
  the one most worth avoiding on a large document. See the "Whole-document
  extraction and memory" section of `PdfElixide.Document`, and consider
  `spans/1`, which describes the same text in runs.

  See `t:chars_opts/0` for the available options.
  """
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
  @spec chars!(t(), chars_opts() | non_neg_integer()) :: [Char.t()]
  def chars!(doc, page_index_or_opts \\ [])

  def chars!(%__MODULE__{} = doc, opts) when is_list(opts) do
    chars(doc, opts) |> Wrap.unwrap!()
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
    chars(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_chars_options(opts) do
    opts = Keyword.validate!(opts, @chars_opts_keys)

    %{
      region: Keyword.get(opts, :region),
      region_mode: validate_region_mode!(opts, :region_mode),
      exclude_layers: Keyword.get(opts, :exclude_layers, []),
      exclude_inks: Keyword.get(opts, :exclude_inks, [])
    }
  end

  @typedoc """
  Options tuning how glyph runs are merged into spans, accepted as
  `:span_merging`.

    * `:preset` — the base configuration every other key overrides:
      `:default`, `:aggressive` (splits more readily), `:conservative`
      (merges across wider gaps), `:adaptive` (derives thresholds from page
      gap statistics), or `:legacy`. Defaults to `:default`. The names mean
      aggression about *inserting spaces*, so `:aggressive` produces more
      word boundaries, not fewer.
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
    * `:adaptive` — a `t:adaptive_threshold_opts/0` keyword list tuning that
      derivation. Only consulted when `:use_adaptive_threshold` resolves to
      `true`.
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
          adaptive: adaptive_threshold_opts() | nil,
          detect_email_patterns: boolean() | nil,
          email_threshold_multiplier: float() | nil,
          detect_citation_markers: boolean() | nil,
          citation_font_size_ratio: float() | nil,
          merge_tm_tj_runs: boolean() | nil
        ]

  @span_merging_opts_keys [
    :preset,
    :space_threshold_em_ratio,
    :conservative_threshold_pt,
    :column_boundary_threshold_pt,
    :severe_overlap_threshold_pt,
    :use_adaptive_threshold,
    :adaptive,
    :detect_email_patterns,
    :email_threshold_multiplier,
    :detect_citation_markers,
    :citation_font_size_ratio,
    :merge_tm_tj_runs
  ]

  @typedoc """
  Options accepted as the `:adaptive` key of `t:span_merging_opts/0`, tuning
  how a space threshold is derived from a page's gap statistics. Consulted
  only when `:use_adaptive_threshold` resolves to `true`.

  Every key defaults to `nil`, meaning "keep the preset's value".
  """
  @type adaptive_threshold_opts :: [
          median_multiplier: float() | nil,
          min_threshold_pt: float() | nil,
          max_threshold_pt: float() | nil,
          use_iqr: boolean() | nil,
          min_samples: non_neg_integer() | nil
        ]

  @adaptive_threshold_opts_keys [
    :median_multiplier,
    :min_threshold_pt,
    :max_threshold_pt,
    :use_iqr,
    :min_samples
  ]

  @typedoc """
  Options accepted by the `spans` and `spans!` functions.

    * `:reading_order` — how spans are ordered: `:top_to_bottom` (simple
      geometric sorting), `:column_aware` (XY-cut column detection), or
      `:structure` (follow a tagged PDF's structure tree). Defaults to
      `:top_to_bottom`. Note these values differ from the `:reading_order` of
      `t:markdown_opts/0`, which is a separate setting.
    * `:span_merging` — a `t:span_merging_opts/0` keyword list, or `nil`
      for the default merging behavior. Defaults to `nil`.
    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the spans
      inside it. Defaults to `nil`.
    * `:region_mode` — how `:region` matches; see `t:region_mode/0`.
      Defaults to `:intersects`.
    * `:exclude_layers` — names of optional-content (OCG) layers to
      suppress, as listed by `layers/1`. Defaults to `[]`.
    * `:exclude_inks` — names of Separation/DeviceN inks to suppress, as
      listed by `inks/3`. Defaults to `[]`.

  ## `:span_merging` drops the other options

  When `:span_merging` is set, `:reading_order`, `:exclude_layers` and
  `:exclude_inks` are ignored. `:region` still applies, being a post-filter.
  """
  @type spans_opts :: [
          reading_order: :top_to_bottom | :column_aware | :structure,
          span_merging: span_merging_opts() | nil,
          region: Rect.t() | nil,
          region_mode: region_mode(),
          exclude_layers: [String.t()],
          exclude_inks: [String.t()]
        ]

  @spans_opts_keys [
    :reading_order,
    :span_merging,
    :region,
    :region_mode,
    :exclude_layers,
    :exclude_inks
  ]

  @doc """
  Extracts spans — runs of text sharing one text state — as
  `PdfElixide.Document.Span` structs.

  With a keyword list (or nothing) as the second argument, returns every
  page's spans concatenated into a single flat list, in page order. With a
  zero-based integer, returns that single page's spans instead.

      Document.spans(doc)
      Document.spans(doc, reading_order: :column_aware)
      Document.spans(doc, 0)
      Document.spans(doc, 0, span_merging: [preset: :aggressive])

  A span covers a run of text rather than one glyph, so this is the cheaper way
  to ask for what `chars/1` returns. The whole-document form still builds every
  page's spans in memory at once — see the "Whole-document extraction and
  memory" section of `PdfElixide.Document`.

  See `t:spans_opts/0` for the available options.
  """
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
  @spec spans!(t(), spans_opts() | non_neg_integer()) :: [Span.t()]
  def spans!(doc, page_index_or_opts \\ [])

  def spans!(%__MODULE__{} = doc, opts) when is_list(opts) do
    spans(doc, opts) |> Wrap.unwrap!()
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
    spans(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_spans_options(opts) do
    opts = Keyword.validate!(opts, @spans_opts_keys)

    %{
      reading_order: Keyword.get(opts, :reading_order, :top_to_bottom),
      span_merging: build_span_merging_option(Keyword.get(opts, :span_merging)),
      region: Keyword.get(opts, :region),
      region_mode: validate_region_mode!(opts, :region_mode),
      exclude_layers: Keyword.get(opts, :exclude_layers, []),
      exclude_inks: Keyword.get(opts, :exclude_inks, [])
    }
  end

  # The nested option builders below validate their own key list, but a value
  # that is not a keyword list at all is passed through untouched rather than
  # rejected by a guard. That keeps the rule the rest of the library follows: a
  # wrong-typed value inside an options map fails in the NIF's own decode,
  # which `Native.Wrap.call/1` turns into an `ArgumentError` naming the
  # offending field. A guard here would instead raise a `FunctionClauseError`
  # naming a private function, which tells the caller nothing about which
  # option was wrong.
  defp build_span_merging_option(nil), do: nil

  defp build_span_merging_option(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @span_merging_opts_keys)

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
    opts = Keyword.validate!(opts, @adaptive_threshold_opts_keys)

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
  Options tuning the spatial table detector. Accepted directly by the `tables`
  functions, and as the `:table_detection` option of the `text` functions.

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
      ruling lines. Ignored on the `text` path, which always disables it.
    * `:enabled` — set to `false` to disable detection entirely.

  Every key except `:preset` defaults to `nil`, meaning "keep the preset's
  value".
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

  @table_detection_opts_keys [
    :preset,
    :enabled,
    :horizontal_strategy,
    :vertical_strategy,
    :column_tolerance,
    :row_tolerance,
    :min_table_cells,
    :min_table_columns,
    :regular_row_ratio,
    :max_table_columns,
    :column_merge_threshold,
    :v_split_gap,
    :text_fallback
  ]

  @typedoc """
  Options accepted by the `tables` and `tables!` functions: every
  `t:table_detection_opts/0` key, plus

    * `:region` — a `PdfElixide.Geometry.Rect` keeping only the tables
      overlapping it. Defaults to `nil`. There is no `:region_mode`; tables use
      bounding-box intersection only.

  Unlike the `:table_detection` option of the `text` functions, the detection
  keys are given *flat* here rather than nested under one key.

  `:region` keeps the detection options you passed rather than loosening them.
  Pass `preset: :relaxed` to ask for that explicitly.
  """
  @type tables_opts :: [
          region: Rect.t() | nil,
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

  @tables_opts_keys [:region | @table_detection_opts_keys]

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

  Every returned table stays resident behind its handle until
  `PdfElixide.Document.Table.close/1` or GC — see the "Whole-document
  extraction and memory" section of `PdfElixide.Document`.
  """
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
  @spec tables!(t(), tables_opts() | non_neg_integer()) :: [Table.t()]
  def tables!(doc, page_index_or_opts \\ [])

  def tables!(%__MODULE__{} = doc, opts) when is_list(opts) do
    tables(doc, opts) |> Wrap.unwrap!()
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
    tables(doc, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_tables_options(opts) do
    opts = Keyword.validate!(opts, @tables_opts_keys)

    %{
      detection: build_table_detection(opts),
      region: Keyword.get(opts, :region)
    }
  end

  defp build_table_detection_option(nil), do: nil

  defp build_table_detection_option(opts) when is_list(opts) do
    build_table_detection(Keyword.validate!(opts, @table_detection_opts_keys))
  end

  defp build_table_detection_option(other), do: other

  # Takes an already-validated keyword list: `tables/2,3` allows `:region`
  # alongside the detection keys, while the `:table_detection` option of the
  # `text` functions does not, so each caller checks its own key list.
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

  @doc false
  @spec __option_defaults__(atom()) :: map()
  def __option_defaults__(:open), do: build_open_options([])
  def __option_defaults__(:inks), do: build_inks_options([])
  def __option_defaults__(:text), do: build_text_options([])
  def __option_defaults__(:markdown), do: build_markdown_options([])
  def __option_defaults__(:html), do: build_html_options([])
  def __option_defaults__(:plain_text), do: build_plain_text_options([])
  def __option_defaults__(:words), do: build_words_options([])
  def __option_defaults__(:text_lines), do: build_text_lines_options([])
  def __option_defaults__(:chars), do: build_chars_options([])
  def __option_defaults__(:spans), do: build_spans_options([])
  def __option_defaults__(:tables), do: build_tables_options([])
  def __option_defaults__(:search), do: build_search_options([])
  def __option_defaults__(:table_detection), do: build_table_detection_option([])
  def __option_defaults__(:span_merging), do: build_span_merging_option([])
  def __option_defaults__(:adaptive_threshold), do: build_adaptive_threshold_option([])

  @doc """
  Extracts the vector paths of the whole document.

  Returns every page's paths concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Path` structs.

  This builds every page's paths in memory at once — see the "Whole-document
  extraction and memory" section of `PdfElixide.Document` for when to prefer
  `paths/2`.
  """
  @spec paths(t()) :: {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def paths(%__MODULE__{ref: ref}) do
    with {:ok, paths} <- Wrap.call(fn -> Native.document_all_paths(ref) end) do
      {:ok, Enum.map(paths, &PdfElixide.Document.Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the vector paths of the whole document, raising an error if it fails.
  """
  @spec paths!(t()) :: [PdfElixide.Document.Path.t()]
  def paths!(%__MODULE__{} = doc) do
    paths(doc) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the vector paths of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no vector graphics. Each path — a line,
  curve, rectangle, or filled shape — is carried as a `PdfElixide.Document.Path`
  struct.
  """
  @spec paths(t(), non_neg_integer()) ::
          {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def paths(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, paths} <- Wrap.call(fn -> Native.document_paths(ref, page_index) end) do
      {:ok, Enum.map(paths, &PdfElixide.Document.Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the vector paths of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec paths!(t(), non_neg_integer()) :: [PdfElixide.Document.Path.t()]
  def paths!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    paths(doc, page_index) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the rectangles of the whole document.

  Returns every page's rectangles concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Path` structs — the values `paths/1` returns,
  narrowed to those classified as rectangles (see the "Rectangles and straight
  lines" section of `PdfElixide.Document.Path` for which shapes those are).

  This builds every page's rectangles in memory at once — see the
  "Whole-document extraction and memory" section of `PdfElixide.Document` for
  when to prefer `rects/2`.
  """
  @spec rects(t()) :: {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def rects(%__MODULE__{ref: ref}) do
    with {:ok, rects} <- Wrap.call(fn -> Native.document_all_rects(ref) end) do
      {:ok, Enum.map(rects, &PdfElixide.Document.Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the rectangles of the whole document, raising an error if it fails.
  """
  @spec rects!(t()) :: [PdfElixide.Document.Path.t()]
  def rects!(%__MODULE__{} = doc) do
    rects(doc) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the rectangles of the page at the given zero-based index.

  Returns `{:ok, []}` when the page draws no shape classified as a rectangle.
  See the "Rectangles and straight lines" section of
  `PdfElixide.Document.Path` for which shapes qualify.
  """
  @spec rects(t(), non_neg_integer()) ::
          {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def rects(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, rects} <- Wrap.call(fn -> Native.document_rects(ref, page_index) end) do
      {:ok, Enum.map(rects, &PdfElixide.Document.Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the rectangles of the page at the given zero-based index, raising an
  error if it fails.
  """
  @spec rects!(t(), non_neg_integer()) :: [PdfElixide.Document.Path.t()]
  def rects!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    rects(doc, page_index) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the straight lines of the whole document.

  Returns every page's lines concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Path` structs — the values `paths/1` returns,
  narrowed to those classified as single straight segments (see the "Rectangles
  and straight lines" section of `PdfElixide.Document.Path` for which shapes
  those are). These are vector graphics; `text_lines/1` is the unrelated text
  extractor.

  This builds every page's lines in memory at once — see the "Whole-document
  extraction and memory" section of `PdfElixide.Document` for when to prefer
  `lines/2`.
  """
  @spec lines(t()) :: {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def lines(%__MODULE__{ref: ref}) do
    with {:ok, lines} <- Wrap.call(fn -> Native.document_all_lines(ref) end) do
      {:ok, Enum.map(lines, &PdfElixide.Document.Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the straight lines of the whole document, raising an error if it
  fails.
  """
  @spec lines!(t()) :: [PdfElixide.Document.Path.t()]
  def lines!(%__MODULE__{} = doc) do
    lines(doc) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the straight lines of the page at the given zero-based index.

  Returns `{:ok, []}` when the page draws no shape classified as a single
  straight segment. See the "Rectangles and straight lines" section of
  `PdfElixide.Document.Path` for which shapes qualify.
  """
  @spec lines(t(), non_neg_integer()) ::
          {:ok, [PdfElixide.Document.Path.t()]} | {:error, Error.t()}
  def lines(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    with {:ok, lines} <- Wrap.call(fn -> Native.document_lines(ref, page_index) end) do
      {:ok, Enum.map(lines, &PdfElixide.Document.Path.from_nif/1)}
    end
  end

  @doc """
  Extracts the straight lines of the page at the given zero-based index, raising
  an error if it fails.
  """
  @spec lines!(t(), non_neg_integer()) :: [PdfElixide.Document.Path.t()]
  def lines!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    lines(doc, page_index) |> Wrap.unwrap!()
  end

  @typedoc """
  Options accepted by the `search` and `search!` functions.

    * `:literal` — treat the pattern as plain text rather than a regular
      expression. Defaults to `true`; see the [Search](guides/search.md) guide
      for the regular expression syntax `literal: false` accepts.
    * `:case_insensitive` — match regardless of case. Defaults to `false`.
    * `:whole_word` — require a word boundary at each end of the match.
      Defaults to `false`.
    * `:max_results` — stop after this many matches, counted across pages.
      Defaults to `0`, meaning no limit. This bounds the work as well as the
      list: searching the whole document stops at the page that reaches the
      limit, leaving the ones after it unread and unindexed.

  There is no `:page_range`: searching one page is what `search/3` and
  `search/4` are for.
  """
  @type search_opts :: [
          literal: boolean(),
          case_insensitive: boolean(),
          whole_word: boolean(),
          max_results: non_neg_integer()
        ]

  @search_opts_keys [:literal, :case_insensitive, :whole_word, :max_results]

  @doc """
  Finds every occurrence of `pattern` in the document's text, as
  `PdfElixide.Document.SearchMatch` structs.

  With a keyword list (or nothing) as the third argument, searches every page
  and returns the matches in page order. With a zero-based integer, searches
  that single page instead.

      Document.search(doc, "Figure 3")
      Document.search(doc, "figure 3", case_insensitive: true)
      Document.search(doc, "Figure 3", 0)
      Document.search(doc, ~S"Figure \\d+", 0, literal: false)

  The pattern is plain text by default. Pass `literal: false` to treat it as a
  regular expression, which reports an unparseable one as
  `%PdfElixide.Error{reason: :invalid_pattern}`. An empty pattern is rejected
  outright with a `FunctionClauseError`, since it would match at every position
  on every page.

  A match's boxes cover whole runs of text rather than the matched characters —
  see `PdfElixide.Document.SearchMatch`. Searching builds a per-page index that
  is reused by later searches and released by `clear_search_index/1` or
  `close/1`. The [Search](guides/search.md) guide covers both.

  The whole-document form builds every page's matches in memory at once — see the
  "Whole-document extraction and memory" section of `PdfElixide.Document` for
  when to prefer the per-page arity.

  See `t:search_opts/0` for the available options.
  """
  @spec search(t(), String.t(), search_opts() | non_neg_integer()) ::
          {:ok, [SearchMatch.t()]} | {:error, Error.t()}
  def search(doc, pattern, page_index_or_opts \\ [])

  # `pattern != ""` is a guard rather than an `%Error{}` because `:max_results`
  # is no defence: it bounds the page walk as well as the list, so a capped call
  # still returns a cap's worth of zero-width matches at offset 0.
  def search(%__MODULE__{ref: ref}, pattern, opts)
      when is_binary(pattern) and pattern != "" and is_list(opts) do
    options = build_search_options(opts)

    with {:ok, matches} <- Wrap.call(fn -> Native.document_all_search(ref, pattern, options) end) do
      {:ok, Enum.map(matches, &SearchMatch.from_nif/1)}
    end
  end

  def search(%__MODULE__{} = doc, pattern, page_index)
      when is_binary(pattern) and pattern != "" and is_integer(page_index) and page_index >= 0 do
    search(doc, pattern, page_index, [])
  end

  @doc """
  Finds every occurrence of `pattern`, raising an error if it fails.
  """
  @spec search!(t(), String.t(), search_opts() | non_neg_integer()) :: [SearchMatch.t()]
  def search!(doc, pattern, page_index_or_opts \\ [])

  def search!(%__MODULE__{} = doc, pattern, opts)
      when is_binary(pattern) and pattern != "" and is_list(opts) do
    search(doc, pattern, opts) |> Wrap.unwrap!()
  end

  def search!(%__MODULE__{} = doc, pattern, page_index)
      when is_binary(pattern) and pattern != "" and is_integer(page_index) and page_index >= 0 do
    search!(doc, pattern, page_index, [])
  end

  @doc """
  Finds every occurrence of `pattern` on the page at the given zero-based index.

  See `t:search_opts/0` for the available options.
  """
  @spec search(t(), String.t(), non_neg_integer(), search_opts()) ::
          {:ok, [SearchMatch.t()]} | {:error, Error.t()}
  def search(%__MODULE__{ref: ref}, pattern, page_index, opts)
      when is_binary(pattern) and pattern != "" and is_integer(page_index) and page_index >= 0 and
             is_list(opts) do
    options = build_search_options(opts)

    with {:ok, matches} <-
           Wrap.call(fn -> Native.document_search(ref, pattern, page_index, options) end) do
      {:ok, Enum.map(matches, &SearchMatch.from_nif/1)}
    end
  end

  @doc """
  Finds every occurrence of `pattern` on the page at the given zero-based index,
  raising an error if it fails.
  """
  @spec search!(t(), String.t(), non_neg_integer(), search_opts()) :: [SearchMatch.t()]
  def search!(doc, pattern, page_index, opts)
      when is_binary(pattern) and pattern != "" and is_integer(page_index) and page_index >= 0 and
             is_list(opts) do
    search(doc, pattern, page_index, opts) |> Wrap.unwrap!()
  end

  defp build_search_options(opts) do
    opts = Keyword.validate!(opts, @search_opts_keys)

    %{
      literal: Keyword.get(opts, :literal, true),
      case_insensitive: Keyword.get(opts, :case_insensitive, false),
      whole_word: Keyword.get(opts, :whole_word, false),
      max_results: Keyword.get(opts, :max_results, 0)
    }
  end

  @doc """
  Builds the search index for every page, so a later `search/2` does not pay for
  the whole document at once.

  Searching already builds the index lazily, so this only moves that cost — see
  the [Search](guides/search.md) guide.
  """
  @spec prepare_search(t()) :: :ok | {:error, Error.t()}
  def prepare_search(%__MODULE__{ref: ref}) do
    case Wrap.call(fn -> Native.document_prepare_search(ref) end) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Builds the search index for every page, raising an error if it fails.
  """
  @spec prepare_search!(t()) :: :ok
  def prepare_search!(%__MODULE__{} = doc) do
    # Local `case` rather than `Wrap.unwrap!/1`: `prepare_search/1` answers a
    # bare `:ok`, not `{:ok, value}`, so there is no payload to unwrap.
    case prepare_search(doc) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Releases the cached search index, and the page text and boxes it holds.

  The document stays usable; a later `search/2` rebuilds what it needs. Nothing
  evicts from this index on its own, so on a large document this is the only
  release short of `close/1` — see the [Search](guides/search.md) guide.

  Unlike the other reads here it takes the handle's lock *exclusively*, so it
  waits for calls already in flight — see [Concurrency](guides/concurrency.md).
  """
  @spec clear_search_index(t()) :: :ok | {:error, Error.t()}
  def clear_search_index(%__MODULE__{ref: ref}) do
    case Wrap.call(fn -> Native.document_clear_search_index(ref) end) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Releases the cached search index, raising an error if it fails.
  """
  @spec clear_search_index!(t()) :: :ok
  def clear_search_index!(%__MODULE__{} = doc) do
    # Local `case` for the same reason as `prepare_search!/1`.
    case clear_search_index(doc) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the fonts of the whole document.

  Returns every page's fonts concatenated into a single flat list, in page order,
  as `PdfElixide.Document.Font` structs. A font used on several pages appears once
  per page.

  A page whose fonts cannot be read contributes nothing and does not fail the
  call — see `fonts/2` for what that covers. Along with `text/1` this is the
  only whole-document extractor that tolerates such a page, and the only one
  that does so with no option to say otherwise.

  Each returned font holds the embedded font program behind its handle until
  `PdfElixide.Document.Font.close/1` or GC, one handle per page per font — see
  the "Whole-document extraction and memory" section of `PdfElixide.Document`.
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
    fonts(doc) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the fonts referenced by the page at the given zero-based index.

  Returns `{:ok, []}` when the page references no fonts. Each font is carried as a
  `PdfElixide.Document.Font` struct with its metadata; the raw embedded font
  program (when present) is pulled on demand with `PdfElixide.Document.Font.data/1`.

  **An empty list also covers a page that could not be read** — one whose
  page-tree entry, `/Resources` reference or fonts do not resolve yields no
  fonts rather than an error. Only an out-of-range index and a failed handle are
  errors, and there is no strict variant that reports the difference.
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
    fonts(doc, page_index) |> Wrap.unwrap!()
  end

  @doc """
  Reads the document outline — its bookmarks / table of contents.

  Returns the top-level `PdfElixide.Document.OutlineItem` structs, each of which
  may carry nested `:children`, forming a tree. Returns `{:ok, []}` when the
  document has no outline.

  **Nesting deeper than 256 levels is rejected** with
  `%PdfElixide.Error{reason: :unsupported}` rather than truncated, so a
  malformed or hostile bookmark tree cannot overflow the native stack. No real
  table of contents comes close to the limit.
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
    outline(doc) |> Wrap.unwrap!()
  end

  @doc """
  Reads the annotations of the whole document.

  Returns every page's annotations concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Annotation` structs. Each carries its zero-based
  `:page` index. Returns `{:ok, []}` when the document has no annotations.

  This builds every page's annotations in memory at once — see the
  "Whole-document extraction and memory" section of `PdfElixide.Document` for
  when to prefer `annotations/2`.
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
    annotations(doc) |> Wrap.unwrap!()
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
    annotations(doc, page_index) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the raster images of the whole document.

  Returns every page's images concatenated into a single flat list, in page
  order, as `PdfElixide.Document.Image` structs. The pixel data is not carried on
  the struct — encode it on demand with `PdfElixide.Document.Image.to_binary/2`
  or `PdfElixide.Document.Image.save/3`.

  What is deferred there is the *encode*, not the load: every image's decoded
  pixels — or its original JPEG bytes — stay resident behind its handle until
  `PdfElixide.Document.Image.close/1` or GC. See the "Whole-document extraction
  and memory" section of `PdfElixide.Document`.

  An image that is too small, or whose encoding cannot be decoded, is left out
  of the list rather than reported — see the "Which images are extracted"
  section of `PdfElixide.Document.Image`.
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
    images(doc) |> Wrap.unwrap!()
  end

  @doc """
  Extracts the raster images of the page at the given zero-based index.

  Returns `{:ok, []}` when the page has no images. Each image — a photo, logo, or
  scanned picture — is carried as a `PdfElixide.Document.Image` struct, which
  holds the metadata and a handle rather than the pixel data itself; encode it on
  demand with `PdfElixide.Document.Image.to_binary/2` or
  `PdfElixide.Document.Image.save/3`.

  It also returns `{:ok, []}` when every image on the page was skipped, or the
  page's content stream could not be parsed — see the "Which images are
  extracted" section of `PdfElixide.Document.Image`.
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
    images(doc, page_index) |> Wrap.unwrap!()
  end

  @doc """
  Returns a `PdfElixide.Document.Page` handle for every page in the document.

  The list is built eagerly, but each handle is just the document and a
  zero-based index and holds no native resource, so building one costs nothing.
  To walk a large document without materializing every handle, enumerate the
  document itself: it implements `Enumerable` over its pages.

  Reads the page count cached on the struct, so it raises only for a document
  whose count could not be determined at open — see `page_count/1`.
  """
  @spec pages(t()) :: [Page.t()]
  def pages(%__MODULE__{} = doc) do
    Enum.map(0..(page_count!(doc) - 1)//1, &%Page{doc: doc, index: &1})
  end

  @doc """
  Returns a `PdfElixide.Document.Page` handle for the page at the given
  zero-based index.

  Builds nothing but the handle itself, and reads no page content until an
  extractor is called on it.
  """
  @spec page(t(), non_neg_integer()) :: {:ok, Page.t()} | {:error, Error.t()}
  def page(%__MODULE__{} = doc, index) when is_integer(index) and index >= 0 do
    case page_count(doc) do
      {:ok, count} when index < count ->
        {:ok, %Page{doc: doc, index: index}}

      {:ok, count} ->
        {:error,
         %Error{
           reason: :out_of_range,
           message: "Page index #{index} out of range (document has #{count} pages)"
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Same as `page/2` but raises an error if it fails.
  """
  @spec page!(t(), non_neg_integer()) :: Page.t()
  def page!(doc, index) when is_integer(index) and index >= 0 do
    page(doc, index) |> Wrap.unwrap!()
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Document{version: {maj, min}, source_path: path}, _opts) do
      src = PdfElixide.Inspecting.source(path)
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
