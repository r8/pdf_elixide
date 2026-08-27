defmodule PdfElixide.Editor do
  @moduledoc """
  Mutable, in-memory PDF editor.

  Where `PdfElixide.Document` only reads, an editor accumulates changes in
  memory and writes them out on demand. The shape is open, mutate, write:

      "form.pdf"
      |> PdfElixide.Editor.open!()
      |> PdfElixide.Form.put_value!("name", "Ada")
      |> PdfElixide.Editor.save!("filled.pdf")
      |> PdfElixide.Editor.close()
      #=> :ok

  Nothing is written until `save/3` or `to_binary/2` runs, and neither consumes
  the editor — you can keep editing and write again. `close/1` **discards
  unsaved edits**, so write before you close. Flattening is deferred to that same
  write: `flatten_annotations/1,2` and `PdfElixide.Form.flatten/1,2` mark what to
  flatten and the drawing happens as the file is written.

  Every function that changes an editor returns the editor, as above, and the
  tuple-returning half is uniform in the same way, so both compose as one
  pipeline. `to_binary/2` and `close/1` are the two ways such a pipeline ends.

  **An editor is a mutable handle, not a value, and rebinding does not fork it**
  — the editor a mutating call returns is the one that went in, so an earlier
  binding will not give you the document as it was before the edit. The
  [Forms](guides/forms.md) guide has both shapes and the full account.

  Every call that writes or mutates takes the handle's lock exclusively — and so
  does `PdfElixide.Form.fields/1`, which only reads — so concurrent *editing* of
  a single editor serializes. `page_count/1`, `modified?/1`,
  `flatten_warnings/1` and `closed?/1` take the lock shared, as do the
  `PdfElixide.Signature` reads given an editor, which reach the document it was
  opened from. Give each process its own editor if you need them to work at
  once; see the [Concurrency](guides/concurrency.md) guide.
  """

  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  # Spelled out rather than `defstruct @enforce_keys`, unlike the value structs:
  # `:source_path` is nil for an editor built from a binary, so it cannot be
  # enforced.
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
  Releases the editor's native memory immediately.

  An editor holds the source document plus its pending edits in memory on the
  Rust side, normally freed only when the BEAM garbage-collects the handle.
  `close/1` frees it now, which matters for long-lived processes that open many
  documents. Calling it is optional and idempotent. It waits for an in-flight
  call on the same editor — a save can hold the handle's lock for seconds — so
  *immediately* means as soon as the handle is idle, not preemptively.

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
      rewrite. Defaults to `false`.
    * `:compress` — compress streams. Defaults to `true`.
    * `:garbage_collect` — drop unreferenced objects. Defaults to
      `true`.

  An unknown key, or a declared key given a value that is not a boolean,
  raises `ArgumentError` naming the offending key; see the "Errors versus
  exceptions" section of `PdfElixide.Error`.
  """
  @type save_opts :: [
          incremental: boolean(),
          compress: boolean(),
          garbage_collect: boolean()
        ]

  @save_opts_keys [:incremental, :compress, :garbage_collect]

  @doc """
  Writes all in-memory changes to a PDF file at the given path, and returns the
  editor.

  Writing does not consume the editor: you can keep editing and write again.

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
  Writes all in-memory changes to a PDF file at the given path, raising an error if it fails.

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
    # Loosely bound for the same reason as `flatten_annotations/1`.
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

  defp build_save_options(opts) do
    opts = Keyword.validate!(opts, @save_opts_keys)

    %{
      incremental: Keyword.get(opts, :incremental, false),
      compress: Keyword.get(opts, :compress, true),
      garbage_collect: Keyword.get(opts, :garbage_collect, true)
    }
  end

  @doc false
  @spec __option_defaults__(:save) :: map()
  def __option_defaults__(:save), do: build_save_options([])

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Editor{source_path: path}, _opts) do
      src = PdfElixide.Inspecting.source(path)
      concat(["#PdfElixide.Editor<", src, ">"])
    end
  end
end
