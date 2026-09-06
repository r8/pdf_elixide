defmodule PdfElixide.Editor do
  @moduledoc """
  Mutable, in-memory PDF editor.

  Open a document, apply changes, and write the result:

      "form.pdf"
      |> PdfElixide.Editor.open!()
      |> PdfElixide.Form.put_value!("name", "Ada")
      |> PdfElixide.Editor.save!("filled.pdf")
      |> PdfElixide.Editor.close()
      #=> :ok

  Nothing is written until `save/3` or `to_binary/2` runs, and neither consumes
  the editor. Mutating calls return the editor so they compose in a pipeline.
  `close/1` **discards unsaved edits**.

  **An editor is a mutable handle: rebinding does not fork it.** Earlier bindings
  see later edits too. The [Forms](guides/forms.md) guide covers both bang
  pipelines and tuple-returning calls, plus filling and deferred flattening.

  ## Page structure

  `delete_page/2` and `move_page/3` use zero-based indices in the current page
  order. **Deleting a page is not redaction**, and bookmarks and links are not
  remapped. See [Page structure](guides/editing.md#page-structure).

  **Incremental saves omit page edits and attachments.** Use a full rewrite;
  [Saving edits](guides/editing.md#saving-edits) lists the limitations.

  ## Page rotation

  `set_rotation/3`, `rotate_page_by/3` and `rotate_all_by/2` change how a viewer
  displays pages; `rotation/2` includes pending changes. See
  [Page rotation](guides/editing.md#page-rotation) for examples and page geometry.

  ## Erasing regions

  `erase_region/3` and `erase_regions/3` paint white rectangles when the document
  is written. **Erasing is not redaction**: covered content remains recoverable.
  Annotations remain above the overlay, and the page's graphics state can change
  its coverage even when the call succeeds. See
  [Erasing regions](guides/editing.md#erasing-regions) for coordinates, unsupported
  pages, verifying coverage, and flattening before erasing.

  ## Attachments

  `embed_file/4` adds an attachment and `embedded_files/1` includes pending ones.
  Attaching to a document with an existing name tree is refused. See
  [Attachments](guides/editing.md#attachments) for the workflow and metadata limits.

  ## Document information is not carried over

  Every write loses the source `/Info` metadata. See
  [Document information is not carried over](guides/editing.md#document-information-is-not-carried-over)
  for XMP and document identifiers.

  ## Encryption

  `save/3` and `to_binary/2` accept `:encryption`. Existing encrypted documents
  cannot be edited. See the [Encryption](guides/encryption.md) guide for the
  workflow, supported algorithms, and limitations of a successful write.

  ## Concurrency

  Every call that writes or mutates takes the handle's lock exclusively — and so
  does `PdfElixide.Form.fields/1`, which only reads — so concurrent *editing* of
  a single editor serializes. `page_count/1`, `modified?/1`, `rotation/2`,
  `embedded_files/1`, `flatten_warnings/1` and `closed?/1` take the lock shared,
  as do the `PdfElixide.Signature` reads given an editor, which reach the
  document it was opened from. Give each process its own editor if you need them
  to work at once; see the [Concurrency](guides/concurrency.md) guide.
  """

  alias PdfElixide.Document.EmbeddedFile
  alias PdfElixide.Error
  alias PdfElixide.Geometry.Rect
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:ref, :version]
  defstruct [:ref, :version, :source_path]

  @typedoc """
  An open editor.

  `:version` arrives with the handle, from the same native call that opens the
  editor, and is served from the struct thereafter: it is the version of the
  document the editor was opened from, and no editing operation changes it.

  `:source_path` is `nil` for an editor built with `from_binary/1`.
  """
  @type t :: %__MODULE__{
          ref: reference(),
          version: {non_neg_integer(), non_neg_integer()},
          source_path: Path.t() | nil
        }

  @doc """
  Opens a PDF document for editing from the specified file path.

  An encrypted document is refused with
  `{:error, %PdfElixide.Error{reason: :encrypted}}`. Read one with
  `PdfElixide.Document.open/2`, which takes a password.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def open(path) when is_binary(path) do
    with {:ok, {ref, version}} <- Wrap.call(fn -> Native.editor_open(path) end) do
      {:ok, %__MODULE__{ref: ref, version: version, source_path: path}}
    end
  end

  @doc """
  Opens a PDF document for editing from the specified file path,
  raising an error if it fails.

  Raises for an encrypted document; `open/1` describes why.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec open!(Path.t()) :: t()
  def open!(path) when is_binary(path) do
    open(path) |> Wrap.unwrap!()
  end

  @doc """
  Opens a PDF document for editing from the given binary data.

  Takes bytes you already have — an HTTP response body, a database blob — so no
  path is involved; use `open/1` to read a file.

  Encrypted bytes are refused, as in `open/1`.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, Error.t()}
  def from_binary(bytes) when is_binary(bytes) do
    with {:ok, {ref, version}} <- Wrap.call(fn -> Native.editor_from_bytes(bytes) end) do
      {:ok, %__MODULE__{ref: ref, version: version, source_path: nil}}
    end
  end

  @doc """
  Opens a PDF document for editing from the given binary data,
  raising an error if it fails.

  Takes bytes you already have — an HTTP response body, a database blob — so no
  path is involved; use `open!/1` to read a file.

  Raises for encrypted bytes, as in `open/1`.
  """
  @spec from_binary!(binary()) :: t()
  def from_binary!(bytes) when is_binary(bytes) do
    from_binary(bytes) |> Wrap.unwrap!()
  end

  @doc """
  Returns the file path from which the editor was loaded, or `nil` if it
  was loaded from binary data.
  """
  @spec source_path(t()) :: Path.t() | nil
  def source_path(%__MODULE__{source_path: p}), do: p

  @doc """
  Returns the PDF specification version of the document being edited, as a
  `{major, minor}` tuple.

  This is the version of the document the editor was opened from, which editing
  does not change. It is read from the struct, so it keeps working after
  `close/1`.

  Encryption does not raise the output version; see
  [The declared version is not raised to match](guides/encryption.md#the-declared-version-is-not-raised-to-match).
  """
  @spec version(t()) :: {non_neg_integer(), non_neg_integer()}
  def version(%__MODULE__{version: v}), do: v

  @doc """
  Returns the number of pages the editor currently holds.

  Counts the pages as edited rather than as found on disk, so unlike `version/1`
  this asks the editor on every call.

  Returns `{:error, %PdfElixide.Error{reason: :closed}}` after `close/1`.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def page_count(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.editor_page_count(ref) end)
  end

  @doc """
  Returns the number of pages the editor currently holds, raising an error if it fails.
  """
  @spec page_count!(t()) :: non_neg_integer()
  def page_count!(%__MODULE__{} = editor) do
    page_count(editor) |> Wrap.unwrap!()
  end

  @doc """
  Returns whether the editor holds changes that have not been written out.

  `false` for a freshly opened editor, and `true` once something has changed it —
  `PdfElixide.Form.put_value/3`, say.

  A full rewrite clears it again, so `save/3` and `to_binary/2` both leave the
  editor unmodified — `to_binary/2` included, even though it writes no file. An
  incremental `save/3` does not: after `save(editor, path, incremental: true)`
  the flag stays `true`.
  """
  @spec modified?(t()) :: boolean()
  def modified?(%__MODULE__{ref: ref}) do
    # `Wrap.call!/1` for the reason spelled out on `PdfElixide.Document.encrypted?/1`.
    Wrap.call!(fn -> Native.editor_is_modified(ref) end)
  end

  @doc """
  Releases the editor's native memory without waiting for garbage collection.

  An editor holds the source document plus its pending edits in memory on the
  Rust side, normally freed only when the BEAM garbage-collects the handle.
  `close/1` frees it now, which matters for long-lived processes that open many
  documents. Calling it is optional and idempotent. It waits for an in-flight
  call on the same editor — a save can hold the handle's lock for seconds — and
  releases the memory as soon as the handle is idle, not preemptively.

  **Unsaved edits are discarded** — call `save/3` or `to_binary/2` first.
  Afterwards, functions that read or mutate the editor return
  `{:error, %PdfElixide.Error{reason: :closed}}`, and their bang variants raise
  it. `source_path/1` and `version/1` keep working, since they read the struct
  rather than the native handle.

      "form.pdf"
      |> PdfElixide.Editor.open!()
      |> PdfElixide.Form.put_value!("name", "Ada")
      |> PdfElixide.Editor.save!("filled.pdf")
      |> PdfElixide.Editor.close()
      #=> :ok

  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{ref: ref}), do: Native.editor_close(ref)

  @doc """
  Returns whether the editor has been released with `close/1`.
  """
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{ref: ref}), do: Native.editor_closed(ref)

  @typedoc """
  Options accepted by `save/3`, `save!/3`, `to_binary/2`, and `to_binary!/2`.

    * `:incremental` — write an incremental update instead of a full
      rewrite. Defaults to `false`. See
      [Saving edits](guides/editing.md#saving-edits) for the changes it omits.
    * `:compress` — compress streams. Defaults to `true`.
    * `:garbage_collect` — drop unreferenced objects. Defaults to
      `true`.
    * `:encryption` — encrypt the written document, as a `t:encryption_opts/0`
      keyword list. Defaults to `nil`, which writes an unencrypted PDF.
      Cannot be combined with `incremental: true`; see the
      [Encryption](guides/encryption.md) guide.

  An unknown key, or a declared key given a value of the wrong type, raises
  `ArgumentError` naming the offending key; see the "Errors versus
  exceptions" section of `PdfElixide.Error`.
  """
  @type save_opts :: [
          incremental: boolean(),
          compress: boolean(),
          garbage_collect: boolean(),
          encryption: encryption_opts() | nil
        ]

  @save_opts_keys [:incremental, :compress, :garbage_collect, :encryption]

  @typedoc """
  The `:encryption` option of `t:save_opts/0`.

    * `:user_password` — password required to open the document. Defaults to
      `""`, which produces a document that opens without a prompt but still
      carries the permission flags.
    * `:owner_password` — password granting full access and the right to change
      security settings. Defaults to `""`, which makes the user password serve
      as the owner password too.
    * `:algorithm` — `:aes128` (the default) or `:rc4_128`.
    * `:permissions` — what a reader may do with the document, as a
      `t:permission_opts/0` keyword list. Defaults to granting everything.

  Both passwords are UTF-8 `t:String.t/0`, unlike `PdfElixide.Document.open/2`'s
  `:password`, which is a byte string. See
  [Passwords](guides/encryption.md#passwords) for their length limit,
  interoperability and what each empty value means, and
  [Algorithms](guides/encryption.md#algorithms) for the cipher choice and its
  consequences for the output.

  An unknown key here or in `:permissions` raises `ArgumentError` naming that
  key. A declared key given a value of the wrong type raises naming
  `:encryption`.
  """
  @type encryption_opts :: [
          user_password: String.t(),
          owner_password: String.t(),
          algorithm: :aes128 | :rc4_128,
          permissions: permission_opts()
        ]

  @encryption_opts_keys [:user_password, :owner_password, :algorithm, :permissions]

  @algorithms [:aes128, :rc4_128]

  @typedoc """
  The `:permissions` option of `t:encryption_opts/0`.

  The eight keys are those of `PdfElixide.Document.Permissions`, which
  describes what each one grants. Every key defaults to `true`.

  See [Permissions](guides/encryption.md#permissions) for how they interact
  and what they do and do not promise.
  """
  @type permission_opts :: [
          print_low_res: boolean(),
          print_high_res: boolean(),
          modify: boolean(),
          copy: boolean(),
          annotate: boolean(),
          fill_forms: boolean(),
          accessibility: boolean(),
          assemble: boolean()
        ]

  @permission_opts_keys [
    :print_low_res,
    :print_high_res,
    :modify,
    :copy,
    :annotate,
    :fill_forms,
    :accessibility,
    :assemble
  ]

  @doc """
  Writes the editor to a PDF file at the given path, and returns the editor.

  A full rewrite is the default. Incremental saves omit page edits, attachments
  and flattening; see [Saving edits](guides/editing.md#saving-edits).

  Writing does not consume the editor: you can keep editing and write again.

  Pass `:encryption` to write a password-protected PDF. It cannot be combined
  with `incremental: true`, and a successful return does not by itself prove
  every object was encrypted — see
  [A failed encryption is not reported](guides/encryption.md#a-failed-encryption-is-not-reported).

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec save(t(), Path.t(), save_opts()) :: {:ok, t()} | {:error, Error.t()}
  def save(%__MODULE__{ref: ref} = editor, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    options = build_save_options(opts)

    case Wrap.call(fn -> Native.editor_save(ref, path, options) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes the editor to a PDF file at the given path, raising an error if it fails.

  Uses the same write modes and limitations as `save/3`; see
  [Saving edits](guides/editing.md#saving-edits).

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec save!(t(), Path.t(), save_opts()) :: t()
  def save!(%__MODULE__{} = editor, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    editor |> save(path, opts) |> Wrap.unwrap!()
  end

  @doc """
  Serialises all in-memory changes into a PDF binary.

  The result is a fully self-contained PDF that can be written to disk,
  stored in a database, or streamed over HTTP.

  Accepts the same `t:save_opts/0` keyword list as `save/3`, except
  `:incremental` — an incremental update is an append to the original file, so
  there is nothing to append to in memory and passing `incremental: true` here
  returns `{:error, %PdfElixide.Error{reason: :invalid_pdf}}`. Use `save/3` for
  an incremental write.

  That includes `:encryption`, which encrypts the returned binary exactly as it
  encrypts a file — including the caveat in
  [A failed encryption is not reported](guides/encryption.md#a-failed-encryption-is-not-reported).

  The whole document is serialised in native memory before being copied
  into the returned binary, so peak usage is roughly twice the output
  size (on top of the editor itself). For very large documents prefer
  `save/3`, which streams to the file without that second buffer.
  """
  @spec to_binary(t(), save_opts()) :: {:ok, binary()} | {:error, Error.t()}
  def to_binary(%__MODULE__{ref: ref}, opts \\ []) when is_list(opts) do
    options = build_save_options(opts)
    Wrap.call(fn -> Native.editor_to_bytes(ref, options) end)
  end

  @doc """
  Serialises all in-memory changes into a PDF binary, raising an error if it fails.
  """
  @spec to_binary!(t(), save_opts()) :: binary()
  def to_binary!(%__MODULE__{} = editor, opts \\ []) when is_list(opts) do
    to_binary(editor, opts) |> Wrap.unwrap!()
  end

  @doc """
  Deletes the page at the given zero-based index, and returns the editor.

  Every later page moves down one index, and `page_count/1` reflects the removal
  at once — no save is needed. See [Page structure](guides/editing.md#page-structure)
  and [Saving edits](guides/editing.md#saving-edits) for the deletion's security
  and writing limitations.

  Returns `{:error, %PdfElixide.Error{reason: :out_of_range}}` if the page does
  not exist.
  """
  @spec delete_page(t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def delete_page(%__MODULE__{ref: ref} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case Wrap.call(fn -> Native.editor_delete_page(ref, page_index) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Deletes the page at the given zero-based index, raising an error if it fails.
  """
  @spec delete_page!(t(), non_neg_integer()) :: t()
  def delete_page!(%__MODULE__{} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    editor |> delete_page(page_index) |> Wrap.unwrap!()
  end

  @doc """
  Moves the page at zero-based index `from` so that it sits at index `to`, and
  returns the editor.

  `to` is where the page ends up once it has been lifted out, so
  `move_page(editor, 0, 2)` on a three-page document leaves the first page last.
  The pages it passes over shift by one to fill the gap; nothing else changes.

  Returns `{:error, %PdfElixide.Error{reason: :out_of_range}}` if either index
  does not exist. See [Page structure](guides/editing.md#page-structure) for what
  a move does not update and [Saving edits](guides/editing.md#saving-edits) for
  the incremental-save limitation.
  """
  @spec move_page(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, Error.t()}
  def move_page(%__MODULE__{ref: ref} = editor, from, to)
      when is_integer(from) and from >= 0 and is_integer(to) and to >= 0 do
    case Wrap.call(fn -> Native.editor_move_page(ref, from, to) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Moves the page at zero-based index `from` so that it sits at index `to`,
  raising an error if it fails.
  """
  @spec move_page!(t(), non_neg_integer(), non_neg_integer()) :: t()
  def move_page!(%__MODULE__{} = editor, from, to)
      when is_integer(from) and from >= 0 and is_integer(to) and to >= 0 do
    editor |> move_page(from, to) |> Wrap.unwrap!()
  end

  @doc """
  Returns the clockwise display rotation of the page at the given zero-based
  index, as `0`, `90`, `180` or `270`.

  It reflects pending edits immediately. For unchanged pages, it matches
  `PdfElixide.Document.Page.rotation/1`, including inheritance and normalization.

  Returns `{:error, %PdfElixide.Error{reason: :out_of_range}}` if the page does
  not exist.
  """
  @spec rotation(t(), non_neg_integer()) ::
          {:ok, PdfElixide.Document.Page.rotation()} | {:error, Error.t()}
  def rotation(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    Wrap.call(fn -> Native.editor_page_rotation(ref, page_index) end)
  end

  @doc """
  Returns the clockwise display rotation of the page at the given zero-based
  index, raising an error if it fails.
  """
  @spec rotation!(t(), non_neg_integer()) :: PdfElixide.Document.Page.rotation()
  def rotation!(%__MODULE__{} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    rotation(editor, page_index) |> Wrap.unwrap!()
  end

  @doc """
  Sets the page at the given zero-based index to rotate by `degrees` clockwise,
  and returns the editor.

  `degrees` is absolute, not a delta, and must be `0`, `90`, `180` or `270` —
  anything else raises `FunctionClauseError`. Use `rotate_page_by/3` to turn a
  page relative to where it already is.

  Returns `{:error, %PdfElixide.Error{reason: :out_of_range}}` if the page does
  not exist. See the "Page rotation" section of this module.
  """
  @spec set_rotation(t(), non_neg_integer(), PdfElixide.Document.Page.rotation()) ::
          {:ok, t()} | {:error, Error.t()}
  def set_rotation(%__MODULE__{ref: ref} = editor, page_index, degrees)
      when is_integer(page_index) and page_index >= 0 and degrees in [0, 90, 180, 270] do
    case Wrap.call(fn -> Native.editor_set_page_rotation(ref, page_index, degrees) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Sets the page at the given zero-based index to rotate by `degrees` clockwise,
  raising an error if it fails.
  """
  @spec set_rotation!(t(), non_neg_integer(), PdfElixide.Document.Page.rotation()) :: t()
  def set_rotation!(%__MODULE__{} = editor, page_index, degrees)
      when is_integer(page_index) and page_index >= 0 and degrees in [0, 90, 180, 270] do
    editor |> set_rotation(page_index, degrees) |> Wrap.unwrap!()
  end

  @doc """
  Turns the page at the given zero-based index a further `degrees` clockwise from
  where it already is, and returns the editor.

  `degrees` is a delta rather than an absolute angle, so `rotate_page_by(e, 0, 90)`
  takes a page already at `180` to `270`. Any integer is accepted: a negative one
  turns anticlockwise, one past `360` wraps, and one that is not a multiple of 90
  is rounded to the nearest quadrant — `45` and `134` both add `90`.

  Returns `{:error, %PdfElixide.Error{reason: :out_of_range}}` if the page does
  not exist. See the "Page rotation" section of this module.
  """
  @spec rotate_page_by(t(), non_neg_integer(), integer()) :: {:ok, t()} | {:error, Error.t()}
  def rotate_page_by(%__MODULE__{ref: ref} = editor, page_index, degrees)
      when is_integer(page_index) and page_index >= 0 and is_integer(degrees) do
    case Wrap.call(fn -> Native.editor_rotate_page_by(ref, page_index, delta(degrees)) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Turns the page at the given zero-based index a further `degrees` clockwise,
  raising an error if it fails.
  """
  @spec rotate_page_by!(t(), non_neg_integer(), integer()) :: t()
  def rotate_page_by!(%__MODULE__{} = editor, page_index, degrees)
      when is_integer(page_index) and page_index >= 0 and is_integer(degrees) do
    editor |> rotate_page_by(page_index, degrees) |> Wrap.unwrap!()
  end

  @doc """
  Turns every page a further `degrees` clockwise from where it already is, and
  returns the editor.

  Each page is turned from its own current rotation, so a document whose pages
  disagree keeps them disagreeing. `degrees` is a delta and is accepted on the
  same terms as `rotate_page_by/3`. On a document with no pages this changes
  nothing and succeeds.

  Every page's current rotation is read before any page is turned, so if one of
  them cannot be read the call fails having turned none of them and left the
  editor unmodified.

  See the "Page rotation" section of this module.
  """
  @spec rotate_all_by(t(), integer()) :: {:ok, t()} | {:error, Error.t()}
  def rotate_all_by(%__MODULE__{ref: ref} = editor, degrees) when is_integer(degrees) do
    case Wrap.call(fn -> Native.editor_rotate_all_pages_by(ref, delta(degrees)) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Turns every page a further `degrees` clockwise, raising an error if it fails.
  """
  @spec rotate_all_by!(t(), integer()) :: t()
  def rotate_all_by!(%__MODULE__{} = editor, degrees) when is_integer(degrees) do
    editor |> rotate_all_by(degrees) |> Wrap.unwrap!()
  end

  # Reduce before the NIF so arbitrary-size Elixir integers fit `i32`.
  defp delta(degrees), do: rem(degrees, 360)

  @doc """
  Paints a white rectangle over `rect` on the page at the given zero-based index
  when the document is written, and returns the editor.

  See [Erasing regions](guides/editing.md#erasing-regions) for the coordinate
  system and coverage limitations.
  Reversed corners are normalized. A rectangle whose corners do not fit a
  32-bit float raises `ArgumentError`.

  Returns `{:error, %PdfElixide.Error{reason: :out_of_range}}` if the page does
  not exist, and `{:error, %PdfElixide.Error{reason: :unsupported}}` if the
  page stores its content streams as an indirect array. Nothing is recorded
  in the latter case.
  """
  @spec erase_region(t(), non_neg_integer(), Rect.t()) :: {:ok, t()} | {:error, Error.t()}
  def erase_region(%__MODULE__{} = editor, page_index, %Rect{} = rect)
      when is_integer(page_index) and page_index >= 0 do
    erase_regions(editor, page_index, [rect])
  end

  @doc """
  Paints a white rectangle over `rect` on the page at the given zero-based
  index, raising an error if it fails.
  """
  @spec erase_region!(t(), non_neg_integer(), Rect.t()) :: t()
  def erase_region!(%__MODULE__{} = editor, page_index, %Rect{} = rect)
      when is_integer(page_index) and page_index >= 0 do
    editor |> erase_region(page_index, rect) |> Wrap.unwrap!()
  end

  @doc """
  Paints a white rectangle over each of `rects` on the page at the given
  zero-based index when the document is written, and returns the editor.

  Accepts a nonempty list of `PdfElixide.Geometry.Rect` with the same
  validation, errors and coverage limitations as `erase_region/3`.
  An empty list raises `ArgumentError`.
  """
  @spec erase_regions(t(), non_neg_integer(), [Rect.t(), ...]) ::
          {:ok, t()} | {:error, Error.t()}
  def erase_regions(%__MODULE__{ref: ref} = editor, page_index, rects)
      when is_integer(page_index) and page_index >= 0 and is_list(rects) do
    # An empty list must not reach the NIF: upstream records it, and its writer
    # then references an overlay stream it never emits.
    if rects == [] do
      raise ArgumentError, "erase_regions/3 needs at least one region, got []"
    end

    Enum.each(rects, &validate_region!/1)

    case Wrap.call(fn -> Native.editor_erase_regions(ref, page_index, rects) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  # Finite fields can still overflow when added. Validate here to raise
  # ArgumentError before the NIF; leave type errors to its field decoder.
  @max_f32 3.402_823_466_385_288_6e38

  defp validate_region!(%Rect{x: x, y: y, width: width, height: height} = rect)
       when is_number(x) and is_number(y) and is_number(width) and is_number(height) do
    if Enum.any?([x, y, x + width, y + height], &(abs(&1) > @max_f32)) do
      raise ArgumentError, "invalid region #{inspect(rect)}: its corners must fit a 32-bit float"
    end

    :ok
  end

  defp validate_region!(_rect), do: :ok

  @doc """
  Paints a white rectangle over each of `rects` on the page at the given
  zero-based index, raising an error if it fails.
  """
  @spec erase_regions!(t(), non_neg_integer(), [Rect.t(), ...]) :: t()
  def erase_regions!(%__MODULE__{} = editor, page_index, rects)
      when is_integer(page_index) and page_index >= 0 and is_list(rects) do
    editor |> erase_regions(page_index, rects) |> Wrap.unwrap!()
  end

  @doc """
  Discards the regions pending on the page at the given zero-based index, so
  the next write paints nothing over it, and returns the editor.

  `modified?/1` is left as it was. Returns
  `{:error, %PdfElixide.Error{reason: :out_of_range}}` if the page does not
  exist. See [Erasing regions](guides/editing.md#erasing-regions).
  """
  @spec clear_erase_regions(t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def clear_erase_regions(%__MODULE__{ref: ref} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case Wrap.call(fn -> Native.editor_clear_erase_regions(ref, page_index) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Discards the regions pending on the page at the given zero-based index,
  raising an error if it fails.
  """
  @spec clear_erase_regions!(t(), non_neg_integer()) :: t()
  def clear_erase_regions!(%__MODULE__{} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    editor |> clear_erase_regions(page_index) |> Wrap.unwrap!()
  end

  @typedoc """
  Options for `embed_file/4`.

    * `:description` — a human-readable note about the attachment, shown by
      viewers beside its name. Absent by default.
    * `:relationship` — how the attachment relates to the document, one of the
      values in `t:PdfElixide.Document.EmbeddedFile.relationship/0`. Absent by
      default.

  Unknown keys and invalid values raise `ArgumentError` naming the key.
  """
  @type embed_opts :: [
          description: String.t(),
          relationship: EmbeddedFile.relationship()
        ]

  @embed_opts_keys [:description, :relationship]

  @relationships [
    :source,
    :data,
    :alternative,
    :supplement,
    :encrypted_payload,
    :form_data,
    :schema,
    :unspecified
  ]

  @doc """
  Attaches `data` to the document under `name`, and returns the editor.

  The attachment is written into the document's `/Names /EmbeddedFiles` name
  tree by the next **full** write — `save/3` without `:incremental`, or
  `to_binary/2` — and read back with `PdfElixide.Document.embedded_files/1`. It
  is a file the document carries, not page content: nothing about the pages
  changes and nothing displays it, though
  a viewer will offer it for saving.

  `name` must be a non-empty UTF-8 string; anything else raises. Attaching two
  files under the same name is allowed and produces a document declaring both,
  which readers resolve inconsistently — use distinct names.

  Returns `{:error, %PdfElixide.Error{reason: :unsupported}}` for a document that
  already has a name tree. See the "Attachments" section of this module for this
  restriction, the media-type limitation and incremental-save behavior.

  Attachment data is copied into native memory and increases peak memory during
  writes, so measure large attachments before adding several.
  """
  @spec embed_file(t(), String.t(), binary(), embed_opts()) ::
          {:ok, t()} | {:error, Error.t()}
  def embed_file(%__MODULE__{ref: ref} = editor, name, data, opts \\ [])
      when is_binary(name) and name != "" and is_binary(data) and is_list(opts) do
    name = validate_name!(name)
    %{description: description, relationship: relationship} = build_embed_options(opts)

    case Wrap.call(fn ->
           Native.editor_embed_file(ref, name, data, description, relationship)
         end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Attaches `data` to the document under `name`, raising an error if it fails.
  """
  @spec embed_file!(t(), String.t(), binary(), embed_opts()) :: t()
  def embed_file!(%__MODULE__{} = editor, name, data, opts \\ [])
      when is_binary(name) and name != "" and is_binary(data) and is_list(opts) do
    editor |> embed_file(name, data, opts) |> Wrap.unwrap!()
  end

  @doc """
  Lists the file attachments the edited document will carry, in name-tree order.

  This reflects pending edits: an attachment added with `embed_file/4` appears
  here before any save, in the order a full write will place it. Its `:size`,
  `:checksum`, `:created` and `:modified` remain `nil`, even after a save. Read
  those fields with `PdfElixide.Document.embedded_files/1` on the written
  document.

  Malformed or excessively complex name trees return an error. See
  `PdfElixide.Document.EmbeddedFile` for the fields and for the memory the
  result holds.
  """
  @spec embedded_files(t()) :: {:ok, [EmbeddedFile.t()]} | {:error, Error.t()}
  def embedded_files(%__MODULE__{ref: ref}) do
    with {:ok, files} <- Wrap.call(fn -> Native.editor_embedded_files(ref) end) do
      {:ok, Enum.map(files, &EmbeddedFile.from_nif/1)}
    end
  end

  @doc """
  Lists the file attachments the edited document will carry, raising an error if
  it fails.
  """
  @spec embedded_files!(t()) :: [EmbeddedFile.t()]
  def embedded_files!(%__MODULE__{} = editor) do
    embedded_files(editor) |> Wrap.unwrap!()
  end

  @doc """
  Marks every page's annotations for flattening.

  Flattening draws each annotation's appearance into the page content. Nothing
  happens until the next full write: `save/3` without `:incremental`, or
  `to_binary/2`. An incremental save ignores the mark entirely. The mark cannot
  be removed — reopen the source for an unflattened document.

  On a page where at least one annotation appearance can be produced, this
  removes every annotation entry, including ones it could not draw and form field
  widgets. A skipped annotation can therefore be deleted without being rendered
  or reported. If the page produces no appearances, the write creates no flatten
  data for it and draws or removes nothing.

  Do not flatten annotations on a page whose form fields you also flatten with
  `PdfElixide.Form.flatten/1,2`: where appearances are produced, the two marks
  are applied independently and fields can be drawn twice.

  Returns the editor. See the "Flattening" section of the
  [Forms](guides/forms.md) guide.
  """
  @spec flatten_annotations(t()) :: {:ok, t()} | {:error, Error.t()}
  def flatten_annotations(%__MODULE__{ref: ref} = editor) do
    case Wrap.call(fn -> Native.editor_flatten_all_annotations(ref) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Marks every page's annotations for flattening, raising an error if it fails.
  """
  @spec flatten_annotations!(t()) :: t()
  def flatten_annotations!(%__MODULE__{} = editor) do
    editor |> flatten_annotations() |> Wrap.unwrap!()
  end

  @doc """
  Marks the annotations of the page at the given zero-based index for flattening.

  Deferred until the next full write, with the same all-or-nothing page behavior
  around appearance production as `flatten_annotations/1`.

  Returns the editor, or `{:error, %PdfElixide.Error{reason: :out_of_range}}` if
  the page does not exist. See the "Flattening" section of the
  [Forms](guides/forms.md) guide.
  """
  @spec flatten_annotations(t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def flatten_annotations(%__MODULE__{ref: ref} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case Wrap.call(fn -> Native.editor_flatten_page_annotations(ref, page_index) end) do
      {:ok, _} -> {:ok, editor}
      {:error, _} = err -> err
    end
  end

  @doc """
  Marks the annotations of the page at the given zero-based index for flattening,
  raising an error if it fails.
  """
  @spec flatten_annotations!(t(), non_neg_integer()) :: t()
  def flatten_annotations!(%__MODULE__{} = editor, page_index)
      when is_integer(page_index) and page_index >= 0 do
    editor |> flatten_annotations(page_index) |> Wrap.unwrap!()
  end

  @doc """
  Lists the warnings collected while flattening.

  Flattening is deferred, so warnings cannot appear before a full write processes
  a flatten mark. Each entry describes a problem encountered while flattening —
  most importantly a newly set non-Latin or emoji field value the shipped
  appearance path cannot render faithfully, which is written with wrong glyphs
  or none while the PDF stays otherwise valid. The warning is the only signal
  that happened.

  Warnings accumulate for the life of the editor and are never cleared, so a
  second write reports the first one's entries again. Read the list after the
  write you care about.

  **The list is a best effort, not an inventory.** Some losses are recorded
  nowhere, so an empty list is not proof that the written document matches the
  original. The "Flattening" section of the [Forms](guides/forms.md) guide says
  which, and what each warning means.
  """
  @spec flatten_warnings(t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def flatten_warnings(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.editor_flatten_warnings(ref) end)
  end

  @doc """
  Lists the warnings collected while flattening, raising an error if it fails.
  """
  @spec flatten_warnings!(t()) :: [String.t()]
  def flatten_warnings!(%__MODULE__{} = editor) do
    flatten_warnings(editor) |> Wrap.unwrap!()
  end

  # Validate here so a bad positional NIF argument still names what it was.
  defp validate_name!(name) do
    unless String.valid?(name) do
      raise ArgumentError, "invalid name, expected a UTF-8 string: #{inspect(name)}"
    end

    name
  end

  defp build_embed_options(opts) do
    opts = Keyword.validate!(opts, @embed_opts_keys)

    %{
      description: validate_text!(:description, Keyword.get(opts, :description)),
      relationship: validate_relationship!(Keyword.get(opts, :relationship))
    }
  end

  defp validate_text!(_key, nil), do: nil

  defp validate_text!(key, value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      raise ArgumentError, "invalid #{inspect(key)}, expected a UTF-8 string: #{inspect(value)}"
    end
  end

  defp validate_text!(key, other) do
    raise ArgumentError, "invalid #{inspect(key)}, expected a string: #{inspect(other)}"
  end

  defp validate_relationship!(nil), do: nil

  defp validate_relationship!(value) when value in @relationships, do: value

  defp validate_relationship!(other) do
    raise ArgumentError,
          "invalid :relationship, expected one of #{inspect(@relationships)}: #{inspect(other)}"
  end

  defp build_save_options(opts) do
    opts = Keyword.validate!(opts, @save_opts_keys)

    incremental = Keyword.get(opts, :incremental, false)
    encryption = build_encryption_option(Keyword.get(opts, :encryption))

    validate_encryption_target!(incremental, encryption)

    %{
      incremental: incremental,
      compress: Keyword.get(opts, :compress, true),
      garbage_collect: Keyword.get(opts, :garbage_collect, true),
      encryption: encryption
    }
  end

  # Without this guard an incremental save silently writes plaintext.
  defp validate_encryption_target!(true, encryption) when not is_nil(encryption) do
    raise ArgumentError,
          ":encryption cannot be combined with incremental: true — an incremental " <>
            "update is appended to the original file and carries no encryption"
  end

  defp validate_encryption_target!(_incremental, _encryption), do: :ok

  # Pass malformed values to the NIF so its decode error names the option.
  defp build_encryption_option(nil), do: nil

  defp build_encryption_option(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @encryption_opts_keys)

    %{
      user_password: Keyword.get(opts, :user_password, ""),
      owner_password: Keyword.get(opts, :owner_password, ""),
      algorithm: validate_algorithm!(opts),
      permissions: build_permission_option(Keyword.get(opts, :permissions, []))
    }
  end

  defp build_encryption_option(other), do: other

  defp validate_algorithm!(opts) do
    case Keyword.get(opts, :algorithm, :aes128) do
      :aes256 ->
        raise ArgumentError,
              "invalid :algorithm :aes256 — no reader could decrypt the output, " <>
                "expected one of #{inspect(@algorithms)}"

      :rc4_40 ->
        raise ArgumentError,
              "invalid :algorithm :rc4_40 — it cannot express the permission flags, " <>
                "expected one of #{inspect(@algorithms)}"

      algorithm ->
        algorithm
    end
  end

  defp build_permission_option(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @permission_opts_keys)

    Map.new(@permission_opts_keys, fn key -> {key, Keyword.get(opts, key, true)} end)
  end

  defp build_permission_option(other), do: other

  @doc false
  @spec __option_defaults__(:save | :embed | :encryption | :permissions) :: map()
  def __option_defaults__(:save), do: build_save_options([])
  def __option_defaults__(:embed), do: build_embed_options([])
  def __option_defaults__(:encryption), do: build_encryption_option([])
  def __option_defaults__(:permissions), do: build_permission_option([])

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Editor{source_path: path}, _opts) do
      src = PdfElixide.Inspecting.source(path)
      concat(["#PdfElixide.Editor<", src, ">"])
    end
  end
end
