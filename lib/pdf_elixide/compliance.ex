defmodule PdfElixide.Compliance do
  @moduledoc """
  Checks a document against the PDF/A, PDF/UA and PDF/X standards, and
  converts an editor's document to PDF/A.

      {:ok, doc} = PdfElixide.Document.open("report.pdf")
      {:ok, report} = PdfElixide.Compliance.validate(doc, :pdf_a_2b)
      report.compliant?
      #=> false
      Enum.map(report.errors, & &1.code)
      #=> ["XMP-001", …]

  `validate/2` returns a `PdfElixide.Compliance.Report` listing the errors and
  warnings found. A document that fails a standard is an ordinary report with
  `compliant?: false`, not an error; `{:error, %PdfElixide.Error{}}` means the
  document could not be read far enough to check it.

  ## What a report establishes

  Validation runs this library's own checks for the requested standard, which
  cover a subset of each standard's requirements. `compliant?: true` means those
  checks found no errors; it is not a conformance certification. Use a dedicated
  conformance validator where a claim of compliance has to hold up.

  PDF/A and PDF/UA reports list checks that were only partly performed among
  their warnings, under code `"WARN-007"`, so even a report with no errors
  carries warnings.

  A PDF/A report does not compare the level a document declares with the one
  requested, so a document declaring PDF/A-2b can be reported compliant with
  PDF/A-1b. Compare `report.declared` with the standard where the declaration
  matters. Nor does it check that the document information dictionary agrees
  with the XMP metadata, or that the file carries a document identifier
  (`/ID`), both of which PDF/A requires. A PDF/A-1 report does not check that
  the XMP metadata is stored uncompressed, which PDF/A-1 also requires.

  PDF/A and PDF/X forbid encryption, so an encrypted document always fails them.
  PDF/UA-2 is not offered: this library performs no check specific to it.

  PDF/X checks read each page's boxes from the page's own dictionary. A page
  that inherits its `/MediaBox` from the page tree is reported as missing one
  (`"XBOX-004"`), and its boxes are not checked for consistency.

  ## Converting to PDF/A

  `convert/3` rewrites the document an editor holds and returns a
  `PdfElixide.Compliance.Conversion` describing what changed:

      {:ok, editor} = PdfElixide.Editor.open("report.pdf")
      {:ok, conversion} = PdfElixide.Compliance.convert(editor, :pdf_a_2b)
      if conversion.report.compliant? do
        {:ok, pdf} = PdfElixide.Editor.to_binary(editor)
      end

  Conversion fixes supported findings and reports anything left unresolved, so
  it can finish with `compliant?: false`. Convert last, then validate the bytes
  you write.

  See the [PDF/A conversion guide](guides/pdf-a-conversion.md) for the fixes,
  editor restrictions, metadata caveats and font-embedding trade-offs.

  ## Memory and locking

  Validation reads a private copy of the document, parsed from its bytes, so
  it holds about two extra copies of the file in memory for its duration. It
  takes a *shared* read on the handle, and so runs alongside other reads — with
  one exception: a document that cannot be opened without a password is
  validated in place and takes the handle *exclusively*. See the
  [Concurrency](guides/concurrency.md) guide.

  Conversion takes the editor *exclusively*. It holds several copies of the
  document at once: the written bytes it starts from, the converted document
  and the editor rebuilt from it.
  """

  alias PdfElixide.Compliance.Conversion
  alias PdfElixide.Compliance.Report
  alias PdfElixide.Document
  alias PdfElixide.Editor
  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @typedoc """
  A standard and level to validate against.

    * PDF/A: `:pdf_a_1a`, `:pdf_a_1b`, `:pdf_a_2a`, `:pdf_a_2b`, `:pdf_a_2u`,
      `:pdf_a_3a`, `:pdf_a_3b`, `:pdf_a_3u`.
    * PDF/UA: `:pdf_ua_1`.
    * PDF/X: `:pdf_x_1a_2001`, `:pdf_x_1a_2003`, `:pdf_x_3_2002`,
      `:pdf_x_3_2003`, `:pdf_x_4`, `:pdf_x_4p`, `:pdf_x_5g`, `:pdf_x_5n`,
      `:pdf_x_5pg`, `:pdf_x_6`.
  """
  @type standard ::
          pdf_a()
          | :pdf_ua_1
          | :pdf_x_1a_2001
          | :pdf_x_1a_2003
          | :pdf_x_3_2002
          | :pdf_x_3_2003
          | :pdf_x_4
          | :pdf_x_4p
          | :pdf_x_5g
          | :pdf_x_5n
          | :pdf_x_5pg
          | :pdf_x_6

  @typedoc """
  A PDF/A level: the part of `t:standard/0` that `convert/3` accepts.
  """
  @type pdf_a ::
          :pdf_a_1a
          | :pdf_a_1b
          | :pdf_a_2a
          | :pdf_a_2b
          | :pdf_a_2u
          | :pdf_a_3a
          | :pdf_a_3b
          | :pdf_a_3u

  @pdf_a [
    :pdf_a_1a,
    :pdf_a_1b,
    :pdf_a_2a,
    :pdf_a_2b,
    :pdf_a_2u,
    :pdf_a_3a,
    :pdf_a_3b,
    :pdf_a_3u
  ]

  @standards @pdf_a ++
               [
                 :pdf_ua_1,
                 :pdf_x_1a_2001,
                 :pdf_x_1a_2003,
                 :pdf_x_3_2002,
                 :pdf_x_3_2003,
                 :pdf_x_4,
                 :pdf_x_4p,
                 :pdf_x_5g,
                 :pdf_x_5n,
                 :pdf_x_5pg,
                 :pdf_x_6
               ]

  @typedoc """
  Options for `convert/3` and `convert!/3`. See `convert/3` for defaults.
  """
  @type convert_opts :: [
          embed_fonts: boolean(),
          remove_javascript: boolean(),
          remove_embedded_files: boolean(),
          icc_profile: binary() | nil
        ]

  @convert_opts_keys [:embed_fonts, :remove_javascript, :remove_embedded_files, :icc_profile]

  @doc """
  Validates the document against `standard`.

  Returns `{:ok, report}` whether or not the document complies; see
  `PdfElixide.Compliance.Report`. An atom that is not a `t:standard/0` raises
  `ArgumentError`. An encrypted document opened without its password returns
  `{:error, %PdfElixide.Error{reason: :encrypted}}` until
  `PdfElixide.Document.authenticate/2` succeeds.
  """
  @spec validate(Document.t(), standard()) :: {:ok, Report.t()} | {:error, Error.t()}
  def validate(%Document{ref: ref}, standard) when is_atom(standard) do
    standard = validate_standard!(standard)

    with {:ok, report} <- Wrap.call(fn -> Native.document_validate(ref, standard) end) do
      {:ok, Report.from_nif(report)}
    end
  end

  @doc """
  Validates the document against `standard`, raising an error if it cannot be
  checked.
  """
  @spec validate!(Document.t(), standard()) :: Report.t()
  def validate!(%Document{} = doc, standard) when is_atom(standard) do
    validate(doc, standard) |> Wrap.unwrap!()
  end

  @doc """
  Converts the editor's document to the PDF/A level `standard`.

  Returns `{:ok, conversion}` whether or not the result complies; see
  `PdfElixide.Compliance.Conversion` and
  the [PDF/A conversion guide](guides/pdf-a-conversion.md). The editor is
  changed in place, and a full write produces the converted document. A
  different declared PDF/A level, or existing XMP metadata for a PDF/A-1
  target, is refused with `:unsupported`. A standard that is not a
  `t:pdf_a/0` raises `ArgumentError`.

  ## Options

    * `:embed_fonts` — embed fonts the document uses without carrying them,
      using fonts installed on this machine. Output can vary by machine; see
      the conversion guide before enabling it. Defaults to `false`.
    * `:remove_javascript` — remove document JavaScript and JavaScript
      actions, which PDF/A forbids. Defaults to `true`.
    * `:remove_embedded_files` — remove attached files, which a PDF/A-1 or
      PDF/A-2 report lists as a violation. They are kept for a PDF/A-3 target
      whatever this says. Defaults to `true`.
    * `:icc_profile` — the ICC profile to embed in the output intent, as the
      profile's bytes. Defaults to `nil`, which embeds an sRGB profile. A
      document with an output intent refuses a supplied profile. Profiles are
      embedded without validation and identified as sRGB, so supply an RGB
      profile.
  """
  @spec convert(Editor.t(), pdf_a(), convert_opts()) ::
          {:ok, Conversion.t()} | {:error, Error.t()}
  def convert(%Editor{ref: ref}, standard, opts \\ []) when is_atom(standard) and is_list(opts) do
    standard = validate_pdf_a!(standard)
    options = build_convert_options(opts)

    native =
      if options.embed_fonts,
        do: &Native.editor_convert_to_pdf_a_embedding/3,
        else: &Native.editor_convert_to_pdf_a/3

    with {:ok, conversion} <- Wrap.call(fn -> native.(ref, standard, options) end) do
      {:ok, Conversion.from_nif(conversion)}
    end
  end

  @doc """
  Converts the editor's document to the PDF/A level `standard`, raising an
  error if the conversion cannot be carried out.

  A conversion that finishes without achieving compliance is returned like any
  other, not raised; check `conversion.report.compliant?`.
  """
  @spec convert!(Editor.t(), pdf_a(), convert_opts()) :: Conversion.t()
  def convert!(%Editor{} = editor, standard, opts \\ [])
      when is_atom(standard) and is_list(opts) do
    editor |> convert(standard, opts) |> Wrap.unwrap!()
  end

  # The NIF rejects an unknown atom too, but as a decode error rather than an
  # `ArgumentError` naming it.
  defp validate_standard!(standard) when standard in @standards, do: standard

  defp validate_standard!(other) do
    raise ArgumentError, "unsupported compliance standard #{inspect(other)}"
  end

  defp validate_pdf_a!(standard) when standard in @pdf_a, do: standard

  defp validate_pdf_a!(other) do
    raise ArgumentError, "cannot convert to #{inspect(other)}, expected a PDF/A level"
  end

  # Option contract: see `__option_defaults__/1`.
  defp build_convert_options(opts) do
    opts = Keyword.validate!(opts, @convert_opts_keys)

    %{
      embed_fonts: Keyword.get(opts, :embed_fonts, false),
      remove_javascript: Keyword.get(opts, :remove_javascript, true),
      remove_embedded_files: Keyword.get(opts, :remove_embedded_files, true),
      icc_profile: Keyword.get(opts, :icc_profile)
    }
  end

  @doc false
  @spec __option_defaults__(:convert) :: map()
  def __option_defaults__(:convert), do: build_convert_options([])
end
