defmodule PdfElixide.Signature.DSS.VRI do
  @moduledoc """
  The validation material a document security store scopes to one signature.

  A `/VRI` entry is the same three kinds of DER blob the store carries at
  document level, narrowed to a single signature and keyed by a digest of that
  signature's `:contents`. `PdfElixide.Signature.DSS.vri_for/2` is how you reach
  the entry belonging to a signature you hold.

  Nothing here is validated, parsed or checked; see `PdfElixide.Signature.DSS`
  for what that means and how to decode a blob.
  """

  @enforce_keys [:signature_digest, :certificates, :crls, :ocsp_responses, :timestamp]

  defstruct @enforce_keys

  @typedoc """
  One `/VRI` entry.

  * `:signature_digest` — the key this entry was filed under: the uppercase
    hexadecimal SHA-1 of a signature's `:contents`, over the raw padded bytes
    rather than the DER value inside them. It is reported exactly as the
    document spelled it, so a document that wrote the key in lowercase will not
    match a lookup.
  * `:certificates`, `:crls`, `:ocsp_responses` — DER blobs scoped to that one
    signature, in document order.
  * `:timestamp` — the entry's `/TU` validation time as a raw PDF date string
    such as `"D:20240102030405+02'00'"`, or `nil` when the entry carries none.
    Not parsed into a `DateTime`, matching `PdfElixide.Signature`'s
    `:signing_time`. It is decoded as UTF-8, so bytes that are not (which a
    conforming date string does not contain) come back as replacement
    characters.
  """
  @type t :: %__MODULE__{
          signature_digest: String.t(),
          certificates: [binary()],
          crls: [binary()],
          ocsp_responses: [binary()],
          timestamp: String.t() | nil
        }

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        signature_digest: signature_digest,
        certificates: certificates,
        crls: crls,
        ocsp_responses: ocsp_responses,
        timestamp: timestamp
      }) do
    %__MODULE__{
      signature_digest: signature_digest,
      certificates: certificates,
      crls: crls,
      ocsp_responses: ocsp_responses,
      timestamp: timestamp
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Signature.DSS.VRI{} = vri, _opts) do
      concat([
        "#PdfElixide.Signature.DSS.VRI<",
        Kernel.inspect(vri.signature_digest),
        " ",
        to_string(length(vri.certificates)),
        "c/",
        to_string(length(vri.crls)),
        "r/",
        to_string(length(vri.ocsp_responses)),
        "o>"
      ])
    end
  end
end
