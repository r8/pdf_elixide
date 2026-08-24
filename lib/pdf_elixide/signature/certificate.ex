defmodule PdfElixide.Signature.Certificate do
  @moduledoc """
  An X.509 certificate: who a signature names as its signer, and the window the
  issuer vouched for that name.

  `PdfElixide.Signature.certificate/1` reads the one a signature carries;
  `parse/1` reads DER from another source:

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      {:ok, certificate} = PdfElixide.Signature.certificate(signature)
      certificate.subject_common_name
      #=> "pdf_elixide test signer"

  ## Nothing here is a trust decision

  The fields are claims read from the certificate. They are not checked against
  a trusted root, a revocation source or a list of accepted signers. Use `:der`
  with `:public_key` or another library to make those decisions.

  ## Names

  `:subject` and `:issuer` use [RFC
  4514](https://datatracker.ietf.org/doc/html/rfc4514) form, with the most
  specific attribute first. Values that cannot be rendered as text appear as
  `oid=#hex` rather than being dropped.

  `:subject_common_name` is the unescaped common name nearest the leaf. It is
  `nil` when the subject has no textual common name and may contain text that
  the full `:subject` renders as hexadecimal.

  A certificate is a plain value with no handle behind it, so it survives
  `PdfElixide.Document.close/1` and can be passed between processes freely.
  """

  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [
    :der,
    :subject,
    :subject_common_name,
    :issuer,
    :serial,
    :not_before,
    :not_after
  ]

  defstruct @enforce_keys

  @typedoc """
  One parsed X.509 certificate.

    * `:der` — the certificate's DER without trailing padding, suitable for
      OTP's `:public_key` or another certificate library.
    * `:subject` — who the certificate is about, in RFC 4514 form. `nil` for a
      certificate that names no subject at all, which is legal for one
      identified only by an extension.
    * `:subject_common_name` — the common name nearest the leaf of `:subject`,
      unescaped. See "Names" in the module documentation for when it is `nil`.
    * `:issuer` — who issued it, in RFC 4514 form. `nil` only for a
      certificate that names no issuer, which is not a conforming one.
    * `:serial` — the issuer's serial number as uppercase hexadecimal DER
      content bytes, without a `0x` prefix or fixed width. Any sign octet is
      preserved. This matches `PdfElixide.Signature.Timestamp`'s `:serial`.
    * `:not_before`, `:not_after` — the window the issuer vouched for, as
      `DateTime`s in UTC with one-second resolution. `valid_at?/2` compares an
      instant against them.
  """
  @type t :: %__MODULE__{
          der: binary(),
          subject: String.t() | nil,
          subject_common_name: String.t() | nil,
          issuer: String.t() | nil,
          serial: String.t(),
          not_before: DateTime.t(),
          not_after: DateTime.t()
        }

  @doc """
  Parses a DER-encoded X.509 certificate.

  Tolerates trailing zero padding, so a `PdfElixide.Signature.DSS` entry can be
  passed straight in:

      {:ok, dss} = PdfElixide.Signature.dss(doc)
      [der | _] = dss.certificates
      {:ok, certificate} = PdfElixide.Signature.Certificate.parse(der)
      certificate.issuer
      #=> "CN=pdf_elixide test signer,O=pdf_elixide,C=UA"

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` for a malformed or
  unsupported certificate, an unrepresentable validity date, or trailing bytes
  other than zero padding. A second concatenated certificate is a trailing
  value, not a chain, and is rejected.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, Error.t()}
  def parse(der) when is_binary(der) do
    with {:ok, certificate} <- Wrap.call(fn -> Native.certificate_parse(der) end) do
      {:ok, from_nif(certificate)}
    end
  end

  @doc """
  Same as `parse/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec parse!(binary()) :: t()
  def parse!(der), do: der |> parse() |> Wrap.unwrap!()

  @doc """
  Whether the certificate's validity window covers `instant`.

  Both ends are inclusive.

      PdfElixide.Signature.Certificate.valid_at?(certificate, DateTime.utc_now())
      #=> true

  For a signature, compare against its claimed signing time from
  `PdfElixide.Signature.signing_time_utc/1`, or against the `:time` of a
  `PdfElixide.Signature.Timestamp` whose attachment was confirmed by
  `PdfElixide.Signature.verify_timestamp/2` and whose authenticity was checked
  by `PdfElixide.Signature.Timestamp.verify/1`. Only the latter is evidence
  rather than the signer's claim, and it is still only as trustworthy as the
  timestamp authority. A `true` result does not establish trust or rule out
  revocation.
  """
  @spec valid_at?(t(), DateTime.t()) :: boolean()
  def valid_at?(%__MODULE__{not_before: not_before, not_after: not_after}, %DateTime{} = instant) do
    DateTime.compare(instant, not_before) != :lt and DateTime.compare(instant, not_after) != :gt
  end

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        der: der,
        subject: subject,
        subject_common_name: subject_common_name,
        issuer: issuer,
        serial: serial,
        not_before: not_before,
        not_after: not_after
      }) do
    %__MODULE__{
      der: der,
      subject: subject,
      subject_common_name: subject_common_name,
      issuer: issuer,
      serial: serial,
      # Total because the NIF refuses a validity date outside the window this
      # accepts, rather than letting one raise from here.
      not_before: DateTime.from_unix!(not_before),
      not_after: DateTime.from_unix!(not_after)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Signature.Certificate{} = certificate, _opts) do
      name = certificate.subject_common_name || certificate.subject

      concat([
        "#PdfElixide.Signature.Certificate<",
        Kernel.inspect(name),
        ", ",
        Kernel.inspect(certificate.serial),
        ">"
      ])
    end
  end
end
