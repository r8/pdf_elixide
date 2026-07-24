defmodule PdfElixide.Document.Font do
  @moduledoc """
  A font referenced by a PDF page, with its zero-based page index, the page's
  font resource name, and metadata describing the face.

  The `:base_font` name has any six-letter subset prefix (`ABCDEF+`) stripped;
  `:subset?` records whether one was present. `:subtype` is the PDF font type
  (`"Type1"`, `"TrueType"`, `"Type0"`), and `:encoding` is `:identity`,
  `:custom`, or `{:standard, name}` for a named base encoding such as
  `"WinAnsiEncoding"`.

  The raw embedded font program is not carried on the struct; instead `:ref` is a
  handle to the font, and `data/1` pulls the bytes on demand:

      {:ok, bytes} = PdfElixide.Document.Font.data(font)   # embedded TTF/OTF bytes

  For a non-embedded font (`:embedded?` is `false`, e.g. one of the standard 14)
  `data/1` returns `{:ok, nil}`.
  """
  alias PdfElixide.Document.Font
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @typedoc """
  A font's character encoding: `{:standard, name}` for a named base encoding,
  or `:custom` / `:identity`.
  """
  @type encoding :: {:standard, String.t()} | :custom | :identity

  @enforce_keys [
    :page,
    :resource_name,
    :base_font,
    :subtype,
    :encoding,
    :embedded?,
    :subset?,
    :weight,
    :bold?,
    :italic?,
    :ref
  ]

  defstruct [
    :page,
    :resource_name,
    :base_font,
    :subtype,
    :encoding,
    :embedded?,
    :subset?,
    :weight,
    :bold?,
    :italic?,
    :ref
  ]

  @type t :: %__MODULE__{
          page: non_neg_integer(),
          resource_name: String.t(),
          base_font: String.t(),
          subtype: String.t(),
          encoding: encoding(),
          embedded?: boolean(),
          subset?: boolean(),
          weight: integer() | nil,
          bold?: boolean(),
          italic?: boolean(),
          ref: reference()
        }

  @doc false
  # Builds a `Font` from the raw map returned by the NIF. Every field already
  # arrives in its final shape (encoding as a tagged term, the font itself as a
  # resource handle under `resource`); the boolean fields are renamed to the
  # trailing-`?` convention and `resource` to `ref`.
  @spec from_nif(map()) :: t()
  def from_nif(%{
        page: page,
        resource_name: resource_name,
        base_font: base_font,
        subtype: subtype,
        encoding: encoding,
        embedded: embedded,
        subset: subset,
        weight: weight,
        bold: bold,
        italic: italic,
        resource: ref
      }) do
    %__MODULE__{
      page: page,
      resource_name: resource_name,
      base_font: base_font,
      subtype: subtype,
      encoding: encoding,
      embedded?: embedded,
      subset?: subset,
      weight: weight,
      bold?: bold,
      italic?: italic,
      ref: ref
    }
  end

  @doc """
  Returns the font's raw embedded font-program bytes — the TrueType / OpenType
  file, suitable for re-embedding elsewhere.

  Returns `{:ok, nil}` for a non-embedded font (`:embedded?` is `false`).
  """
  @spec data(t()) :: {:ok, binary() | nil} | {:error, Error.t()}
  def data(%__MODULE__{ref: ref}) do
    Wrap.call(fn -> Native.font_data(ref) end)
  end

  @doc """
  Same as `data/1` but returns the bytes directly, raising on error.
  """
  @spec data!(t()) :: binary() | nil
  def data!(%__MODULE__{} = font) do
    case data(font) do
      {:ok, bytes} -> bytes
      {:error, error} -> raise error
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Font{page: page, base_font: base_font, subtype: subtype}, _opts) do
      concat([
        "#PdfElixide.Document.Font<p",
        to_string(page),
        " ",
        base_font,
        " (",
        subtype,
        ")>"
      ])
    end
  end
end
