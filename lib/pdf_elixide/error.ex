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
      the `:password` option of `open/2`, `open!/2`, `from_binary/2` and
      `from_binary!/2`; `PdfElixide.Document.authenticate/2` reports a wrong
      password as `{:ok, false}` instead.
    * `:invalid_pdf` — malformed or unparseable PDF data.
    * `:unsupported` — an unsupported PDF version, feature, or filter.
    * `:not_found` — a referenced object was not found.
    * `:out_of_range` — the page index is outside the document.
    * `:io` — an underlying IO error.
    * `:panic` — the native library or upstream `pdf_oxide` panicked on this
      input, i.e. hit a bug rather than a condition it reports. The handle stays
      usable, but a panic partway through an operation can leave it holding
      partially updated state, so `close/1` it and reopen if the error recurs.
    * `:lock_poisoned` — the internal resource lock was poisoned. Should no
      longer occur: a native panic is contained before it can poison a lock and
      is reported as `:panic` instead.
    * `:closed` — the handle was released with `close/1`.
    * `:other` — any error not covered above; `message` is preserved verbatim.

  `:message` is a human-readable description. `:details` is reserved for future
  structured payloads and is currently always `nil`.

  ## Errors versus exceptions

  This struct is reserved for PDF and runtime failures. A malformed *argument*
  raises instead, even from a non-bang function, because that is a bug in the
  calling code rather than a condition of the document:

    * `FunctionClauseError` when a guard rejects it — a negative page index, an
      options argument that is not a keyword list.
    * `ArgumentError` for everything else, including every way an option can be
      wrong: an unknown key (`detect_heading:` for `:detect_headings`), a key
      given twice, a declared key given a value the native layer cannot decode,
      and a declared key whose value is out of range (`{:min_overlap, 2.0}`). A
      value the native layer cannot decode outside an options map — a form
      field value that is not a tagged tuple — raises the same way.

  The message always names the offending key, so a typo is reported rather than
  silently ignored and a wrong value is reported rather than silently applied.
  Build option lists with `Keyword.merge/2` rather than `++`, since a duplicated
  key is rejected instead of resolved to the first occurrence.

  Nothing about the *caller* therefore arrives as a `%PdfElixide.Error{}`; if
  you get one, the arguments were accepted and the document, the filesystem or
  the handle is what failed.
  """

  @type reason ::
          :encrypted
          | :wrong_password
          | :invalid_pdf
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
