defmodule PdfElixide.Editor do
  @moduledoc """
  Mutable, in-memory PDF editor backed by `pdf_oxide`'s `DocumentEditor`.
  """

  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [:ref]
  defstruct [:ref, :source_path]

  @type t :: %__MODULE__{
          ref: reference(),
          source_path: Path.t() | nil
        }

  @doc """
  Opens a PDF document for editing from the specified file path.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def open(path) when is_binary(path) do
    with {:ok, ref} <- Wrap.call(fn -> Native.editor_open(path) end) do
      {:ok, %__MODULE__{ref: ref, source_path: path}}
    end
  end

  @doc """
  Opens a PDF document for editing from the specified file path,
  raising an error if it fails.
  """
  @spec open!(Path.t()) :: t()
  def open!(path) when is_binary(path) do
    case open(path) do
      {:ok, editor} -> editor
      {:error, error} -> raise error
    end
  end

  @doc """
  Opens a PDF document for editing from the given binary data.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, Error.t()}
  def from_binary(bytes) when is_binary(bytes) do
    with {:ok, ref} <- Wrap.call(fn -> Native.editor_from_bytes(bytes) end) do
      {:ok, %__MODULE__{ref: ref, source_path: nil}}
    end
  end

  @doc """
  Opens a PDF document for editing from the given binary data,
  raising an error if it fails.
  """
  @spec from_binary!(binary()) :: t()
  def from_binary!(bytes) when is_binary(bytes) do
    case from_binary(bytes) do
      {:ok, editor} -> editor
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the file path from which the editor was loaded, or `nil` if it
  was loaded from binary data.
  """
  @spec source_path(t()) :: Path.t() | nil
  def source_path(%__MODULE__{source_path: p}), do: p

  @doc """
  Releases the editor's native memory immediately.

  An editor holds the source document plus its pending edits in memory on the
  Rust side, normally freed only when the BEAM garbage-collects the handle.
  `close/1` frees it now, which matters for long-lived processes that open many
  documents. Calling it is optional and idempotent.

  **Unsaved edits are discarded** — call `save/3` or `to_binary/2` first.
  Afterwards, functions that read or mutate the editor return
  `{:error, %PdfElixide.Error{reason: :closed}}`, and their bang variants raise
  it. `source_path/1` keeps working, since it reads the struct rather than the
  native handle.

      editor = PdfElixide.Editor.open!("form.pdf")
      :ok = PdfElixide.Form.set_value(editor, "name", "Ada")
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

  Defaults mirror `pdf_oxide`'s `SaveOptions::full_rewrite()`, so
  calling `save/2` is equivalent to `save/3` with no options.
  """
  @type save_opts :: [
          incremental: boolean(),
          compress: boolean(),
          linearize: boolean(),
          garbage_collect: boolean()
        ]

  @doc """
  Writes all in-memory changes to a PDF file at the given path.
  """
  @spec save(t(), Path.t(), save_opts()) :: :ok | {:error, Error.t()}
  def save(%__MODULE__{ref: ref}, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    options = build_save_options(opts)

    case Wrap.call(fn -> Native.editor_save(ref, path, options) end) do
      {:ok, :ok} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes all in-memory changes to a PDF file at the given path, raising an error if it fails.
  """
  @spec save!(t(), Path.t(), save_opts()) :: :ok
  def save!(%__MODULE__{} = editor, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
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
    case to_binary(editor, opts) do
      {:ok, bytes} -> bytes
      {:error, error} -> raise error
    end
  end

  defp build_save_options(opts) do
    %{
      incremental: Keyword.get(opts, :incremental, false),
      compress: Keyword.get(opts, :compress, true),
      linearize: Keyword.get(opts, :linearize, false),
      garbage_collect: Keyword.get(opts, :garbage_collect, true)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Editor{source_path: path}, _opts) do
      src = if path, do: Path.basename(path), else: "<binary>"
      concat(["#PdfElixide.Editor<", src, ">"])
    end
  end
end
