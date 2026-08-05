defmodule PdfElixide.Editor do
  @moduledoc """
  Mutable, in-memory PDF editor backed by `pdf_oxide`'s `DocumentEditor`.

  Where `PdfElixide.Document` only reads, an editor accumulates changes in
  memory and writes them out on demand. The shape is open, mutate, write:

      editor = PdfElixide.Editor.open!("form.pdf")
      :ok = PdfElixide.Form.set_value(editor, "name", {:text, "Ada"})
      :ok = PdfElixide.Editor.save(editor, "filled.pdf")
      :ok = PdfElixide.Editor.close(editor)

  Nothing is written until `save/3` or `to_binary/2` runs, and neither consumes
  the editor — you can keep editing and write again. `close/1` **discards
  unsaved edits**, so write before you close.

  Every call that writes or mutates takes the handle's lock exclusively — and so
  does `PdfElixide.Form.fields/1`, which only reads — so concurrent *editing* of
  a single editor serializes. Only `page_count/1` and `modified?/1` take the lock
  shared. Give each process its own editor if you need them to work at once; see
  the [Concurrency](guides/concurrency.md) guide.
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
  `PdfElixide.Form.set_value/3`, say.

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

      editor = PdfElixide.Editor.open!("form.pdf")
      :ok = PdfElixide.Form.set_value(editor, "name", {:text, "Ada"})
      :ok = PdfElixide.Editor.save(editor, "filled.pdf")
      :ok = PdfElixide.Editor.close(editor)

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
    * `:linearize` — linearize the output for fast web view. Defaults
      to `false`.
    * `:garbage_collect` — drop unreferenced objects. Defaults to
      `true`.

  Defaults mirror `pdf_oxide`'s own full-rewrite defaults, so calling `save/2`
  is equivalent to `save/3` with no options.

  An unknown key, or a declared key given a value that is not a boolean,
  raises `ArgumentError` naming the offending key; see the "Errors versus
  exceptions" section of `PdfElixide.Error`.
  """
  @type save_opts :: [
          incremental: boolean(),
          compress: boolean(),
          linearize: boolean(),
          garbage_collect: boolean()
        ]

  @save_opts_keys [:incremental, :compress, :linearize, :garbage_collect]

  @doc """
  Writes all in-memory changes to a PDF file at the given path.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec save(t(), Path.t(), save_opts()) :: :ok | {:error, Error.t()}
  def save(%__MODULE__{ref: ref}, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    options = build_save_options(opts)

    case Wrap.call(fn -> Native.editor_save(ref, path, options) end) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes all in-memory changes to a PDF file at the given path, raising an error if it fails.

  The path is handed to the operating system unchanged — see the "File paths"
  section of `PdfElixide`.
  """
  @spec save!(t(), Path.t(), save_opts()) :: :ok
  def save!(%__MODULE__{} = editor, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    # Keeps a local `case` where every other bang variant pipes through
    # `Wrap.unwrap!/1`: `save/3` answers a bare `:ok`, not `{:ok, value}`, so
    # there is no payload to unwrap.
    case save(editor, path, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Serialises all in-memory changes into a PDF binary.

  The result is a fully self-contained PDF that can be written to disk,
  stored in a database, or streamed over HTTP.

  Accepts the same `t:save_opts/0` keyword list as `save/3`. Note that
  `:incremental` is not supported here — upstream returns
  `{:error, _}` because incremental updates can only be appended to
  the original file.

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

  # Defaults pinned by `option_defaults_test.exs` via `__option_defaults__(:save)`.
  defp build_save_options(opts) do
    opts = Keyword.validate!(opts, @save_opts_keys)

    %{
      incremental: Keyword.get(opts, :incremental, false),
      compress: Keyword.get(opts, :compress, true),
      linearize: Keyword.get(opts, :linearize, false),
      garbage_collect: Keyword.get(opts, :garbage_collect, true)
    }
  end

  @doc false
  # See `PdfElixide.Document.__option_defaults__/1` for why this exists.
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
