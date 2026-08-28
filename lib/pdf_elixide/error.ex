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

    * `:encrypted` — the PDF is encrypted and needs a password first.
    * `:wrong_password` — the supplied password was rejected. Comes only from
      the `:password` option of `PdfElixide.Document.open/2`,
      `PdfElixide.Document.open!/2`, `PdfElixide.Document.from_binary/2` and
      `PdfElixide.Document.from_binary!/2`;
      `PdfElixide.Document.authenticate/2` reports a wrong password as
      `{:ok, false}` instead.
    * `:invalid_pdf` — malformed or unparseable PDF data.
    * `:invalid_pattern` — the search pattern could not be parsed. Comes only
      from `PdfElixide.Document.search/2` and friends under `literal: false`.
    * `:unsupported` — an unsupported PDF version, feature, or filter.
    * `:not_found` — a referenced object was not found; no form field carries
      the name given to `PdfElixide.Form.field/2`, `PdfElixide.Form.value/2`,
      `PdfElixide.Form.put_value/3`, `PdfElixide.Form.put_values/2` or
      `PdfElixide.Form.update_value/3`; or what a call asks for is absent, as a
      signature carrying no timestamp is to
      `PdfElixide.Signature.verify_timestamp/2`.
    * `:out_of_range` — the page index is outside the document or editor.
    * `:io` — an underlying IO error.
    * `:panic` — the native library panicked on this input, i.e. hit a bug
      rather than a condition it reports. The handle stays usable, but a panic
      partway through an operation can leave it holding partially updated
      state, so close and reopen it if the error recurs.
    * `:lock_poisoned` — the internal resource lock was poisoned. Should not
      occur; a native panic is contained and reported as `:panic` instead.
    * `:closed` — the handle was released with `PdfElixide.Document.close/1`,
      or with the counterpart on whichever handle it is.
    * `:other` — any error not covered above; `message` is preserved verbatim.

  `:message` is a human-readable description. `:details` is reserved for future
  structured payloads and is currently always `nil`.

  ## Errors versus exceptions

  This struct is reserved for PDF and runtime failures. A malformed *argument*
  raises instead, even from a non-bang function, because that is a bug in the
  calling code rather than a condition of the document:

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

  Predicates ending in `?` are the mirror image: they return a bare boolean, so
  a failure has nowhere to be reported and this struct is raised instead, from a
  function with no `!` in its name. `PdfElixide.Document.has_structure_tree?/1`
  and `PdfElixide.Document.has_xfa?/1` answer `false` for a feature that cannot
  be read, so only a failure of the *handle* raises — their strict counterparts
  `PdfElixide.Document.has_structure_tree/1` and `PdfElixide.Document.has_xfa/1`
  return the error instead. `PdfElixide.Signature.document_timestamp?/1`
  degrades the same way and takes bytes rather than a handle, so nothing can
  raise from it at all; its strict counterpart
  `PdfElixide.Signature.document_timestamp/1` reports bytes that are not a PDF.
  `PdfElixide.Document.Page.has_text_layer?/1` raises
  for *everything*, since answering `false` would invert the meaning callers act
  on. `PdfElixide.Document.encrypted?/1` asks something that cannot fail, so
  only the handle can raise, and `PdfElixide.Document.closed?/1` never raises
  at all.
  """

  @type reason ::
          :encrypted
          | :wrong_password
          | :invalid_pdf
          | :invalid_pattern
          | :unsupported
          | :not_found
          | :out_of_range
          | :io
          | :panic
          | :lock_poisoned
          | :closed
          | :other

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          details: map() | nil
        }

  defexception reason: :other, message: "unknown error", details: nil

  @impl true
  def message(%__MODULE__{message: message}), do: message
end
