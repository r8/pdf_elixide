defmodule PdfElixide.Signature.DSS do
  @moduledoc """
  A document's security store: the material it carries for validating its own
  signatures long after they were made.

  `PdfElixide.Signature.dss/1` reads it. A signature is verifiable from the
  signature alone, but deciding whether to *trust* it needs the certificate
  chain, the revocation lists and the OCSP responses that were current when it
  was signed — evidence that would otherwise expire or go offline. A document
  built for long-term validation carries all of it in the catalog's `/DSS`, and
  this is what that holds:

      {:ok, dss} = PdfElixide.Signature.dss(doc)
      length(dss.certificates)
      #=> 1

  The "Material for validating later" section of the
  [Signatures](guides/signatures.md) guide puts this in sequence with the
  PAdES levels it lifts.

  ## Nothing here is validated

  Every blob is opaque bytes, checked against nothing. No certificate is chained
  to a root, no revocation list is consulted, no OCSP response is matched to a
  request, and no date is compared to anything. This is the material for a trust
  decision, not a trust decision — the same line `PdfElixide.Signature.verify/2`
  and `PdfElixide.Signature.certificate/1` draw, and the reason a store's mere
  presence proves nothing about the signatures it accompanies.

  A store also reads as though it were whole. An entry that is not a readable
  stream is dropped without a trace, so a short list is not evidence that the
  document is short: it may be a damaged one.

  ## Decoding a blob

  A certificate reads through `PdfElixide.Signature.Certificate.parse/1`, which
  is the same value `PdfElixide.Signature.certificate/1` returns:

      [der | _] = dss.certificates
      {:ok, certificate} = PdfElixide.Signature.Certificate.parse(der)
      certificate.subject_common_name

  CRLs decode through OTP's `:public_key`:

      [der | _] = dss.crls
      :public_key.der_decode(:CertificateList, der)

  OCSP responses stay opaque here, OTP shipping no decoder for them.

  ## Reaching one signature's material

  `:vri` holds the per-signature entries, each keyed by a digest rather than by
  anything a caller would recognize. `vri_for/2` does the lookup:

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      PdfElixide.Signature.DSS.vri_for(dss, signature)

  A store is a plain value with no handle behind it, so it survives
  `PdfElixide.Document.close/1` and can be passed between processes freely.
  """

  alias PdfElixide.Signature
  alias PdfElixide.Signature.DSS.VRI

  @enforce_keys [:certificates, :crls, :ocsp_responses, :vri]

  defstruct @enforce_keys

  @typedoc """
  One document security store.

  * `:certificates`, `:crls`, `:ocsp_responses` — the document-level `/Certs`,
    `/CRLs` and `/OCSPs` arrays, each as a list of DER blobs in document order.
    They apply to the document rather than to any one signature.
  * `:vri` — the `/VRI` entries, each scoping material to a single signature.
    Use `vri_for/2` to find the one belonging to a signature you hold.

  Any of the four may be empty; a store in which all four are empty is not
  reported at all, and `PdfElixide.Signature.dss/1` says what that means.
  """
  @type t :: %__MODULE__{
          certificates: [binary()],
          crls: [binary()],
          ocsp_responses: [binary()],
          vri: [VRI.t()]
        }

  @doc """
  The `/VRI` entry scoped to `signature`, or `nil` when the store has none.

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      {:ok, dss} = PdfElixide.Signature.dss(doc)
      PdfElixide.Signature.DSS.vri_for(dss, signature)
      #=> %PdfElixide.Signature.DSS.VRI{signature_digest: "81BAC6...", ...}

  Entries are filed under the uppercase hexadecimal SHA-1 of the signature's
  raw `:contents`, padding included, and the lookup is an exact match on that
  string. A document that spelled its key any other way — lowercase hex, or a
  digest of the trimmed DER value — will not be found, and answers `nil` as a
  store with no entry does.

  A signature with no `:contents` has no digest to look up, and also answers
  `nil`.
  """
  @spec vri_for(t(), Signature.t()) :: VRI.t() | nil
  def vri_for(%__MODULE__{}, %Signature{contents: nil}), do: nil

  def vri_for(%__MODULE__{vri: vri}, %Signature{contents: contents}) do
    digest = Base.encode16(:crypto.hash(:sha, contents))

    Enum.find(vri, &(&1.signature_digest == digest))
  end

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        certificates: certificates,
        crls: crls,
        ocsp_responses: ocsp_responses,
        vri: vri
      }) do
    %__MODULE__{
      certificates: certificates,
      crls: crls,
      ocsp_responses: ocsp_responses,
      vri: Enum.map(vri, &VRI.from_nif/1)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Signature.DSS{} = dss, _opts) do
      concat([
        "#PdfElixide.Signature.DSS<",
        to_string(length(dss.certificates)),
        " certs, ",
        to_string(length(dss.crls)),
        " crls, ",
        to_string(length(dss.ocsp_responses)),
        " ocsps, ",
        to_string(length(dss.vri)),
        " vri>"
      ])
    end
  end
end
