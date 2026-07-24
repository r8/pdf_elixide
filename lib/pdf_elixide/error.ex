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
    * `:wrong_password` — the supplied password was rejected.
    * `:invalid_pdf` — malformed or unparseable PDF data.
    * `:unsupported` — an unsupported PDF version, feature, or filter.
    * `:not_found` — a referenced object was not found.
    * `:out_of_range` — the page index is outside the document.
    * `:io` — an underlying IO error.
    * `:lock_poisoned` — the internal resource lock was poisoned.
    * `:other` — any error not covered above; `message` is preserved verbatim.

  `:message` is a human-readable description. `:details` is reserved for future
  structured payloads and is currently always `nil`.
  """

  @type reason ::
          :encrypted
          | :wrong_password
          | :invalid_pdf
          | :unsupported
          | :not_found
          | :out_of_range
          | :io
          | :lock_poisoned
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
