defmodule PdfElixide.Signature.Timestamp do
  @moduledoc """
  An RFC 3161 timestamp token: a time-stamping authority's assertion that some
  bytes existed when it saw them.

  `PdfElixide.Signature.timestamp/1` reaches the one a signature carries, and
  `parse/1` takes a token from anywhere else. A signature's own `:signing_time`
  is the signer's unverifiable claim; a timestamp is a third party's, and
  `verify/1` is what checks the authority actually made it — while
  `PdfElixide.Signature.verify_timestamp/2` checks that it was made over the
  signature carrying it, which is a separate question with a separate answer:

      {:ok, [signature]} = PdfElixide.Signature.list(doc)
      {:ok, timestamp} = PdfElixide.Signature.timestamp(signature)
      PdfElixide.Signature.Timestamp.verify(timestamp)
      #=> {:ok, :valid}

  ## What a verdict proves

  `verify/1` checks one thing: that the token carries an authentic signature
  from the certificate embedded in it, over the time and imprint it states. Four
  things it does not establish:

    * **That the timestamp covers anything in particular.** `:message_imprint`
      is a digest of whatever was timestamped, and it is compared here to
      nothing at all: until it is matched against something, a `:valid` timestamp
      is a valid timestamp over unknown bytes.
      `PdfElixide.Signature.verify_timestamp/2` performs that match for a token
      reached from a signature.
    * **That the authority is who the token says.** No certificate is chained to
      a root, checked against a revocation list, or compared to any list of
      trusted authorities. `:tsa_name` is the token's own claim and is not
      checked against the certificate that signed it.
    * **That the stated time is right.** A timestamp authority that signs a time
      of its choosing produces a token that verifies.
    * **That the certificate was valid then.** Its validity window is compared to
      nothing, so an expired or not-yet-valid certificate verifies exactly like a
      current one.

  ## Tokens that cannot be verified

  A token comes in two shapes, and `parse/1` reads both: a full CMS-wrapped
  `TimeStampToken`, and a bare `TSTInfo`. Only the first carries an authority's
  signature, so `verify/1` reports `%PdfElixide.Error{reason: :invalid_pdf}` for
  a bare one rather than a verdict — there is nothing there to check. The same
  reason covers a token whose authority signed with an algorithm this library
  cannot verify, which is why the answer is `:valid` or `:invalid` and never the
  third state `PdfElixide.Signature.verify/2` reports.

  A timestamp is a plain value with no handle behind it, so it survives
  `PdfElixide.Document.close/1` and can be passed between processes freely.
  """

  alias PdfElixide.Error
  alias PdfElixide.Native
  alias PdfElixide.Native.Wrap

  @enforce_keys [
    :token,
    :time,
    :serial,
    :policy_oid,
    :tsa_name,
    :hash_algorithm,
    :message_imprint
  ]

  defstruct @enforce_keys

  @typedoc """
  The digest algorithm the timestamped imprint was made with.

  `:unknown` is an algorithm identifier this library does not recognize, which
  leaves `:message_imprint` uninterpretable rather than wrong.
  """
  @type hash_algorithm :: :sha1 | :sha256 | :sha384 | :sha512 | :unknown

  @typedoc """
  What a `verify/1` call concluded. "What a verdict proves" in the module
  documentation says what `:valid` does and does not establish.
  """
  @type verdict :: :valid | :invalid

  @typedoc """
  One parsed timestamp token.

    * `:token` — the DER the timestamp was parsed from, with any trailing
      padding removed. `verify/1` reads it, and it is what to hand to another
      decoder or to whatever embeds it; nothing here writes one back into a
      document.
    * `:time` — the time the authority says it issued the token. Unlike
      `PdfElixide.Signature`'s `:signing_time`, which is a raw PDF date string,
      this is a `DateTime` in UTC: a timestamp's generation time is a parsed
      value where a signature's `/M` is a string the document supplied.
      Resolution is one second.
    * `:serial` — the authority's serial number for this token, as uppercase
      hexadecimal with no `0x` prefix and no fixed width.
    * `:policy_oid` — the timestamping policy the token was issued under, in
      dotted-decimal form.
    * `:tsa_name` — the name the authority gave itself in the token. A
      distinguished name for the usual directory-name form, otherwise the raw
      URI, DNS or email value. `nil` covers two cases that cannot be told apart
      here: a token naming no authority at all, and one naming it in a form this
      library does not render — an `otherName`, an `ediPartyName`, an IP address
      or a registered identifier. Reaching the certificate that actually signed
      the token is possible only for a document timestamp, whose blob *is* the
      token: `PdfElixide.Signature.certificate/1` returns it for an `:rfc3161`
      signature, and for one carried in a signature's unsigned attributes
      returns that signature's signer instead.
    * `:hash_algorithm`, `:message_imprint` — the digest that was timestamped and
      the algorithm that produced it. `verify/1` does not compare it to content;
      see "What a verdict proves".
  """
  @type t :: %__MODULE__{
          token: binary(),
          time: DateTime.t(),
          serial: String.t(),
          policy_oid: String.t(),
          tsa_name: String.t() | nil,
          hash_algorithm: hash_algorithm(),
          message_imprint: binary()
        }

  @doc """
  Parses a DER-encoded RFC 3161 timestamp token.

  Reads both a full CMS-wrapped `TimeStampToken` and a bare `TSTInfo`, and
  tolerates the zero padding a token stored in a PDF carries — so the
  `:contents` of an `:rfc3161` signature can be passed straight in, though
  `PdfElixide.Signature.timestamp/1` is the shorter way to the same place.

      {:ok, timestamp} = PdfElixide.Signature.Timestamp.parse(der)
      timestamp.time
      #=> ~U[2026-08-23 07:50:03Z]

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` when the bytes are neither
  shape, carry trailing bytes other than zero padding, or state a generation
  time no date can represent.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, Error.t()}
  def parse(token) when is_binary(token) do
    with {:ok, timestamp} <- Wrap.call(fn -> Native.timestamp_parse(token) end) do
      {:ok, from_nif(timestamp)}
    end
  end

  @doc """
  Same as `parse/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec parse!(binary()) :: t()
  def parse!(token), do: token |> parse() |> Wrap.unwrap!()

  @doc """
  Verifies the timestamp authority's signature over the token.

  `{:ok, :valid}` means the token is authentically the authority's and has not
  been altered since. It says nothing about *what* was timestamped: see "What a
  verdict proves" in the module documentation, which is also where the trust,
  time and certificate-validity limits are.

      PdfElixide.Signature.Timestamp.verify(timestamp)
      #=> {:ok, :valid}

  Reports `%PdfElixide.Error{reason: :invalid_pdf}` rather than a verdict when
  the token is a bare `TSTInfo` and so carries no signature to check, and when
  the authority signed it with an algorithm this library cannot verify.
  """
  @spec verify(t()) :: {:ok, verdict()} | {:error, Error.t()}
  def verify(%__MODULE__{token: token}) do
    Wrap.call(fn -> Native.timestamp_verify(token) end)
  end

  @doc """
  Same as `verify/1`, but raises `PdfElixide.Error` on failure.
  """
  @spec verify!(t()) :: verdict()
  def verify!(timestamp), do: timestamp |> verify() |> Wrap.unwrap!()

  @doc false
  @spec from_nif(map()) :: t()
  def from_nif(%{
        token: token,
        time: time,
        serial: serial,
        policy_oid: policy_oid,
        tsa_name: tsa_name,
        hash_algorithm: hash_algorithm,
        message_imprint: message_imprint
      }) do
    %__MODULE__{
      token: token,
      # Total because the NIF refuses a generation time outside the window this
      # accepts, rather than letting one raise from here.
      time: DateTime.from_unix!(time),
      serial: serial,
      policy_oid: policy_oid,
      tsa_name: tsa_name,
      hash_algorithm: hash_algorithm,
      message_imprint: message_imprint
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%PdfElixide.Signature.Timestamp{} = timestamp, _opts) do
      concat([
        "#PdfElixide.Signature.Timestamp<",
        DateTime.to_iso8601(timestamp.time),
        ", ",
        Kernel.inspect(timestamp.serial),
        ">"
      ])
    end
  end
end
