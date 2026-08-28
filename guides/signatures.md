# Signatures

`PdfElixide.Signature.list/1` reports what each digital signature in a document
*claims* — who signed, when, why, which bytes the signature covers and which
field it sits in — from a read-only `PdfElixide.Document` or a
`PdfElixide.Editor` alike. `PdfElixide.Signature.verify/2` checks one of those
claims against the signed bytes.

```elixir
alias PdfElixide.Document
alias PdfElixide.Signature

path = "path/to/signed.pdf"
doc = Document.open!(path)

signature =
  try do
    [signature] = Signature.list!(doc)
    signature
  after
    Document.close(doc)
  end

signature.signer_name
#=> "Alice Example"
signature.reason
#=> "Approval"

# The claim is checked against the bytes it covers.
Signature.verify!(signature, File.read!(path))
#=> :valid

# And separately: does it cover the whole file?
Signature.covers_whole_document?(signature, File.stat!(path).size)
#=> true
```

The struct outlives the handle. `list/1` is the only step above that touches the
document; subsequent calls use the struct and the file's bytes after the example
closes the document.

## What a signature claims

Every field `list/1` reports comes from the signature dictionary and nothing
else. A document altered after signing lists exactly as it did before:

```elixir
intact_doc = Document.open!("signed.pdf")
altered_doc = Document.open!("signed-then-edited.pdf")

{intact, altered} =
  try do
    {:ok, [intact]} = Signature.list(intact_doc)
    {:ok, [altered]} = Signature.list(altered_doc)
    {intact, altered}
  after
    Document.close(intact_doc)
    Document.close(altered_doc)
  end

altered == intact
#=> true — the claims are identical

Signature.verify(intact, File.read!("signed.pdf"))
#=> {:ok, :valid}
Signature.verify(altered, File.read!("signed-then-edited.pdf"))
#=> {:ok, :invalid}
```

Treat listed fields as claims until they are verified. The "What `list/1`
reports are claims" section of `PdfElixide.Signature` identifies the affected
values.

`signing_time_utc/1` parses the signer's claimed `:signing_time` into a
`DateTime`, answering `{:ok, nil}` rather than a wrong date when the claim is
not a well-formed one. `count/1` answers how many signatures a document carries
without building their metadata.

## Verifying one

`verify/2` needs the bytes of the file the signature came from. A handle does
not carry them, so read them yourself — `File.read!/1` for a document opened
from a path, or the binary you handed `from_binary/2`.

```elixir
case Signature.verify(signature, bytes) do
  {:ok, :valid} -> :covered_bytes_are_intact
  {:ok, :invalid} -> :do_not_trust
  {:ok, :unknown} -> :could_not_check
  {:error, error} -> {:unreadable, error}
end
```

`:unknown` is the absence of a finding, not a mild failure — the blob parsed but
the check could not run. Treat it as unverified rather than as a weak `:valid`.
The "What verification proves" section of `PdfElixide.Signature` lists the
algorithms that can be checked, the causes of `:unknown`, and the three things a
`:valid` verdict does not establish.

`verify_signer/1` checks only whether the blob is internally consistent and
needs no document bytes. It cannot detect appended document changes: the altered
document above still answers `:valid` because its signature blob did not change.
Use `verify/2` whenever the file is available.

## Whether it covers the whole file

A verdict covers only the bytes in `:byte_range`. Check
`covers_whole_document?/2` separately to detect content appended after a valid
signature.

```elixir
Signature.covers_whole_document?(signature, File.stat!(path).size)
```

The size is yours to supply, which is what lets the call work from a struct with
no handle behind it. `false` is one answer to several situations — content
appended after signing, a truncated file, a malformed range, or simply the wrong
size passed in — and it answers rather than raising.

## The signer's certificate

`certificate/1` reads the signer's certificate out of the blob as a
`PdfElixide.Signature.Certificate`:

```elixir
{:ok, certificate} = Signature.certificate(signature)

certificate.subject_common_name
#=> "Alice Example"
certificate.not_after
#=> ~U[2027-01-01 00:00:00Z]
```

Use `:der` with OTP's `:public_key` or another certificate library to make a
trust decision. `PdfElixide.Signature.Certificate.parse/1` reads a certificate
held as DER, such as one from a `dss/1` store. Nothing here makes a trust
decision: the "Nothing here is a trust decision" section of
`PdfElixide.Signature.Certificate` says what that means, and its "Names" section
covers how `:subject` and `:issuer` are rendered.

`Certificate.valid_at?/2` checks the certificate's validity window at a
caller-supplied instant. The signer's `signing_time_utc/1` is an unverified
claim. A timestamp's `:time` comes from a third party but is useful only after
the checks below succeed.

## Timestamp checks are independent

A timestamp involves three technical checks plus a separate trust decision:

| Question | Call |
|---|---|
| Is there a token at all? | `PdfElixide.Signature.timestamp/1` |
| Did the authority issue it? | `PdfElixide.Signature.Timestamp.verify/1` |
| Was it made over *this* signature? | `PdfElixide.Signature.verify_timestamp/2` |
| Is that authority one to trust? | Nothing here — yours to decide |

Authority validation and signature-imprint validation are independent:

```elixir
alias PdfElixide.Signature.Timestamp

{:ok, token} = Signature.timestamp(signature)

# The authority issued the token.
Timestamp.verify(token)
#=> {:ok, :valid}

# The token covers something other than this signature.
Signature.verify_timestamp(signature, File.read!(path))
#=> {:ok, :invalid}
```

`timestamp/1` answers `{:ok, nil}` for a signature that carries no token — a
finding, distinct from the error a blob it cannot read produces. The
"What a verdict proves" section of `PdfElixide.Signature.Timestamp` says what
`verify/1` establishes, and its "Tokens that cannot be verified" section covers
the shapes that come back as an error rather than a verdict.

## PAdES baseline levels

The three arities of `pades_level` differ by available input. Lower arities can
report fewer levels:

```elixir
doc = Document.open!(path)
{:ok, [signature]} = Signature.list(doc)
{:ok, dss} = Signature.dss(doc)
:ok = Document.close(doc)

bytes = File.read!(path)

Signature.pades_level(signature)               #=> {:ok, :b_t}    — signature alone
Signature.pades_level(signature, dss)          #=> {:ok, :b_lt}   — plus the store
Signature.pades_level(signature, dss, bytes)   #=> {:ok, :b_lta}  — plus the bytes
```

So `pades_level/1` cannot report above `:b_t` however archival the document is,
and `/2` cannot reach `:b_lta`. `t:PdfElixide.Signature.pades_level/0` says what
each level means and how much of it is a structural observation rather than a
verification result.

## Material for validating later

A document built for long-term validation carries the certificates, CRLs and
OCSP responses that were current when it was signed. `dss/1` reads them.

`dss/1` takes a handle and must run before the document is closed. Its result is
a plain value that outlives the handle.

```elixir
doc = Document.open!(path)
{:ok, dss} = Signature.dss(doc)
:ok = Document.close(doc)

dss.certificates
#=> [<<48, 130, ...>>]

# One signature's slice of the store.
PdfElixide.Signature.DSS.vri_for(dss, signature)
#=> %PdfElixide.Signature.DSS.VRI{...}
```

`{:ok, nil}` means no material reached the reader, which is not the same as the
document carrying none — `dss/1`'s own documentation separates the cases. A
store is also read tolerantly, so a short list is not evidence that the document
is short. Nothing in it is validated: the "Nothing here is validated" section of
`PdfElixide.Signature.DSS` says what that means, and "Decoding a blob" covers
getting a certificate or CRL out of one.

## The document's archival timestamp

An archival timestamp is a document-level object rather than a form field, so
`list/1` never reports it and `timestamp/1` — which answers about a signature —
does not reach it. It comes from the file's bytes:

```elixir
bytes = File.read!(path)

Signature.document_timestamp?(bytes)
#=> true

{:ok, token} = Signature.document_timestamp(bytes)
Timestamp.verify(token)
#=> {:ok, :valid}
```

`document_timestamp?/1` is the tolerant boolean form: unreadable bytes and an
absent timestamp both answer `false`. `document_timestamp/1` hands the token
back so its signature can be checked and keeps those two cases apart. Both
inspect the document bytes, so use the predicate for its return shape rather
than as a cheaper scan. Finding the timestamp does not verify it — that second
step above remains separate, as it is for a signature's own token.

## Places left to sign

`unsigned_fields/1` names the signature fields still waiting for a signature. On
a well-formed form, it and `list/1` partition the named signature fields and can
be used together to determine whether every such field is signed:

```elixir
doc = Document.open!(path)

try do
  Signature.list!(doc) |> Enum.map(& &1.field_name)
  #=> ["signature"]

  Signature.unsigned_fields!(doc)
  #=> ["countersign", "witness", "group.slot"]
after
  Document.close(doc)
end
```

A field whose value was cleared is a place left to sign and appears here. A
field the document gives no name is reported by neither call.

Flattening takes any signature field away with the rest of the AcroForm — the
"Flattening" section of the [Forms](forms.md) guide has that account.

## Damaged documents are refused, not stepped over

Signature reads are stricter than form reads on a damaged document.
`PdfElixide.Form.fields/1` steps over a field it cannot read and returns the
ones it reached, so a form whose `/Fields` names an object the file does not
contain still answers `{:ok, []}`. `list/1` refuses that same document as
`%PdfElixide.Error{reason: :invalid_pdf}`: "no signatures" is an answer callers
act on, and a damaged file must not be able to fake it.

The same rule reaches the value a signature field points at. A `/V` that is not
a signature dictionary is refused, including one naming an object the file does
not contain. The single exception is a `/V` of `null`, which is how a cleared
field is spelled — that field is unsigned, so `list/1` skips it and
`unsigned_fields/1` names it.

`unsigned_fields/1` reads no signature value, so it does not apply that
value-level validation. A field pointing at something other than a signature
dictionary is omitted; use `list/1` to validate the value.

All three reject a cyclic or excessively deep field hierarchy: cycles return
`:invalid_pdf`, while depth or size limits return `:unsupported`.

## Signature fields are not form fields

A signature field is not fillable. `PdfElixide.Form` omits it whether signed or
unsigned and reports it as not found. The "Signature fields" section of the
[Forms](forms.md) guide describes that boundary.

## Producing signatures is not offered

Nothing in this library signs a document. Sign with an external tool instead and
open the result here: every call in this guide reads a document signed elsewhere.
The [Concurrency](concurrency.md) guide describes which signature calls touch a
handle and which continue working independently after it is closed.
