defmodule PdfElixide.Editor do
  @moduledoc """
  Mutable, in-memory PDF editor backed by `pdf_oxide`'s `DocumentEditor`.
  """

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
  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
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
  @spec from_binary(binary()) :: {:ok, t()} | {:error, term()}
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
  Serialises all in-memory changes into a PDF binary.

  The result is a fully self-contained PDF that can be written to disk,
  stored in a database, or streamed over HTTP.
  """
  @spec to_binary(t()) :: {:ok, binary()} | {:error, term()}
  def to_binary(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.editor_to_bytes(ref) end)
  end

  @doc """
  Serialises all in-memory changes into a PDF binary, raising an error if it fails.
  """
  @spec to_binary!(t()) :: binary()
  def to_binary!(%__MODULE__{} = editor) do
    case to_binary(editor) do
      {:ok, bytes} -> bytes
      {:error, error} -> raise error
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Editor{source_path: path}, _opts) do
      src = if path, do: Path.basename(path), else: "<binary>"
      concat(["#PdfElixide.Editor<", src, ">"])
    end
  end
end
