defmodule PdfElixide.Document do
  @moduledoc """
  Read-only representation of a PDF document.
  """

  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap
  alias PdfElixide.Page

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
      `{:error, "Authentication failed: wrong password"}` (or raises,
      for the bang variants). When omitted or `nil`, no authentication
      attempt is made beyond `pdf_oxide`'s built-in empty-password try.
  """
  @type open_opts :: [password: String.t()]

  @doc """
  Opens a PDF document from the specified file path.
  """
  @spec open(Path.t(), open_opts()) :: {:ok, t()} | {:error, term()}
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
  @spec from_binary(binary(), open_opts()) :: {:ok, t()} | {:error, term()}
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
  Returns the number of pages in the given PDF document.
  """
  @spec page_count(t()) :: {:ok, non_neg_integer()} | {:error, term()}
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
    Native.document_has_structure_tree(ref)
  end

  @doc """
  Returns whether the PDF document is encrypted.
  """
  @spec encrypted?(t()) :: boolean()
  def encrypted?(%__MODULE__{ref: ref}) do
    Native.document_is_encrypted(ref)
  end

  @doc """
  Authenticates against the document's encryption with the given password.

  Returns `{:ok, true}` if authentication succeeded (or the PDF is not encrypted),
  `{:ok, false}` if the password was wrong, or `{:error, reason}` on a PDF/crypto error.
  """
  @spec authenticate(t(), binary()) :: {:ok, boolean()} | {:error, term()}
  def authenticate(%__MODULE__{ref: ref}, password) when is_binary(password) do
    Wrap.call(fn -> Native.document_authenticate(ref, password) end)
  end

  @doc """
  Same as `authenticate/2` but raises on error.

  Still returns `false` (does not raise) for a wrong password.
  """
  @spec authenticate!(t(), binary()) :: boolean()
  def authenticate!(doc, password) when is_binary(password) do
    case authenticate(doc, password) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text content of the whole document.

  Returns every page's text concatenated in order, separated by a form-feed
  (`\\f`) page separator.
  """
  @spec text(t()) :: {:ok, binary()} | {:error, term()}
  def text(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.document_extract_all_text(ref) end)
  end

  @doc """
  Extracts the text content of the whole document, raising an error if it fails.
  """
  @spec text!(t()) :: binary()
  def text!(%__MODULE__{} = doc) do
    case text(doc) do
      {:ok, text} -> text
      {:error, error} -> raise error
    end
  end

  @doc """
  Extracts the text content of the page at the given zero-based index.
  """
  @spec text(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def text(%__MODULE__{ref: ref}, page_index)
      when is_integer(page_index) and page_index >= 0 do
    Wrap.call(fn -> Native.document_extract_text(ref, page_index) end)
  end

  @doc """
  Extracts the text content of the page at the given zero-based index,
  raising an error if it fails.
  """
  @spec text!(t(), non_neg_integer()) :: binary()
  def text!(doc, page_index)
      when is_integer(page_index) and page_index >= 0 do
    case text(doc, page_index) do
      {:ok, text} -> text
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
  @spec page(t(), non_neg_integer()) :: {:ok, Page.t()} | {:error, term()}
  def page(%__MODULE__{} = doc, index) when is_integer(index) and index >= 0 do
    case page_count(doc) do
      {:ok, count} when index < count -> {:ok, %Page{doc: doc, index: index}}
      {:ok, _count} -> {:error, "Page index out of range"}
      {:error, _} = error -> error
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
      src = if path, do: Path.basename(path), else: "<binary>"
      concat(["#PdfElixide.Document<", src, " v", to_string(maj), ".", to_string(min), ">"])
    end
  end

  defimpl Enumerable do
    alias PdfElixide.{Document, Page}

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
