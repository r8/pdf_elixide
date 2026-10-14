defmodule PdfElixide.Error do
  @moduledoc """
  Structured error raised or returned by `PdfElixide` operations.

  Non-bang functions return `{:error, %PdfElixide.Error{}}`; bang functions
  raise the same struct (it is an exception). Match on `:reason` to handle
  specific failures:

      case PdfElixide.Document.open(path) do
        {:ok, doc} -> doc
        {:error, %PdfElixide.Error{reason: :encrypted}} -> prompt_for_password()
        {:error, %PdfElixide.Error{reason: :invalid_pdf}} -> reject()
      end

  ## Reasons

    * `:encrypted` — the PDF needs authentication. Supply `:password` when
      opening a document or editor, or call `PdfElixide.Document.authenticate/2`
      on an open document.
    * `:wrong_password` — an open function's `:password` was rejected, or
      the password given to `PdfElixide.Signature.Certificate.parse_pkcs12/2`
      does not open the file. `PdfElixide.Document.authenticate/2` reports a
      rejected password as `{:ok, false}` instead.
    * `:invalid_pdf` — malformed or unparseable PDF data.
    * `:invalid_pattern` — the search pattern could not be parsed. Comes only
      from `PdfElixide.Document.search/2` and friends under `literal: false`.
    * `:unsupported` — an input or operation this library does not support:
      a PDF version, feature or filter, bytes of an unsupported format, or a
      call refused in the handle's current state, such as an incremental save
      after a merge. `message` says which, and what to do instead.
    * `:not_found` — a referenced object was not found; no form field carries
      the name given to `PdfElixide.Form.field/2`, `PdfElixide.Form.value/2`,
      `PdfElixide.Form.put_value/3`, `PdfElixide.Form.put_values/2` or
      `PdfElixide.Form.update_value/3`; or what a call asks for is absent, as a
      signature carrying no timestamp is to
      `PdfElixide.Signature.verify_timestamp/2`, or a file holding no
      certificate is to `PdfElixide.Signature.Certificate.parse_pem/1` and
      `PdfElixide.Signature.Certificate.parse_pkcs12/2`.
    * `:out_of_range` — the page index is outside the document or editor.
    * `:io` — an underlying IO error.
    * `:panic` — the native layer stopped on this input without reporting a
      condition of its own. A handle the call used stays usable, but a panic
      partway through an operation can leave it holding partially updated
      state, so close and reopen it if the error recurs.
    * `:lock_poisoned` — the handle's internal lock could not be acquired. A
      panic arrives as `:panic` instead, so this is not the reason to expect.
    * `:closed` — the handle was released with `PdfElixide.Document.close/1`,
      or with the counterpart on whichever handle it is.
    * `:other` — any other failure reported while handling the document;
      `message` is preserved verbatim.

  `:message` is a human-readable description.

  ## Errors versus exceptions

  This struct is reserved for PDF and runtime failures. A malformed *argument*
  raises instead, even from a non-bang function, because it is a fault in the
  call rather than a condition of the document:

    * `FunctionClauseError` when a guard rejects it — a negative page index, an
      options argument that is not a list.
    * `ArgumentError` for everything else, and the message names the offending
      key. That covers every way an option can be wrong — an unknown key
      (`detect_heading:` for `:detect_headings`), a key given twice, a value the
      native layer cannot decode, a value out of range (`{:min_overlap, 2.0}`) —
      and undecodable values outside an options map, such as a form field value
      that is none of the shapes `PdfElixide.Form.put_value/3` accepts. A *path*
      is opaque bytes and so has almost
      nothing to reject — only Windows, which cannot name a file in arbitrary
      bytes, raises here; see the "File paths" section of `PdfElixide`.

  Build option lists with `Keyword.merge/2` rather than `++`, since a duplicated
  key is rejected instead of resolved to the first occurrence. So nothing about
  the *caller* arrives as a `%PdfElixide.Error{}`; if you get one, the arguments
  were accepted and the document, the filesystem or the handle is what failed.

  A fault in the native library itself raises `ErlangError` from every
  function, predicates included, rather than returning or raising this struct.
  It is not a condition of the document; please report it.

  Predicates ending in `?` are the mirror image. They return a bare boolean, so
  a failure has nowhere to be reported, and this struct is raised instead, from
  a function with no `!` in its name. As a rule, a `false` therefore means the
  answer really is no: a predicate that cannot answer raises. Where a predicate
  can fail for a reason other than its handle, a counterpart without the `?`
  returns `{:ok, boolean}` or the error — `PdfElixide.Document.Page.has_text_layer/1`
  and `PdfElixide.Editor.marked_for_redaction/2`, for example. Predicates that
  cannot fail, such as `PdfElixide.Document.closed?/1`, never raise.

  The exceptions are `PdfElixide.Document.has_structure_tree?/1`,
  `PdfElixide.Document.has_xfa?/1` and
  `PdfElixide.Signature.document_timestamp?/1`, which treat unreadable content
  as `false`. Their counterparts without the `?` preserve the error. The first
  two still raise when the handle itself cannot be used.
  """

  # Spelled once so the typespec and the set `Wrap.call/1` accepts at runtime
  # cannot disagree.
  @reasons [
    :encrypted,
    :wrong_password,
    :invalid_pdf,
    :invalid_pattern,
    :unsupported,
    :not_found,
    :out_of_range,
    :io,
    :panic,
    :lock_poisoned,
    :closed,
    :other
  ]

  @type reason :: unquote(@reasons |> Enum.reverse() |> Enum.reduce(&{:|, [], [&1, &2]}))

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t()
        }

  defexception reason: :other, message: "unknown error"

  @doc false
  @spec __reasons__() :: [reason()]
  def __reasons__, do: @reasons

  @impl true
  def message(%__MODULE__{message: message}), do: message
end
