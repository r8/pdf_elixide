# Signatures

`PdfElixide.Signature.list/1` reports what each digital signature in a document
*claims* — who signed, when, why, which bytes the signature covers and which
field it sits in — from a read-only `PdfElixide.Document` or a
`PdfElixide.Editor` alike. `PdfElixide.Signature.verify/2` is what turns one of
those claims into a finding.

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
document, so everything after it keeps answering once the document is closed —
which is why the example closes early and works from the struct and the file's
bytes from then on.

## What a signature claims

Every field `list/1` reports comes from the signature dictionary and nothing
else. A document altered after signing lists exactly as it did before:

```elixir
{:ok, [intact]} = Signature.list(Document.open!("signed.pdf"))
{:ok, [altered]} = Signature.list(Document.open!("signed-then-edited.pdf"))

altered == intact
#=> true — the claims are identical

Signature.verify(intact, File.read!("signed.pdf"))
#=> {:ok, :valid}
Signature.verify(altered, File.read!("signed-then-edited.pdf"))
#=> {:ok, :invalid}
```

That contrast is the whole reason the two halves of this guide are separate:
treat a listed field as a claim until a call below turns it into a finding. The
"What `list/1` reports are claims" section of `PdfElixide.Signature` says which
values are affected and why.

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
`:valid` verdict deliberately does not establish.

`verify_signer/1` asks a narrower question — is the blob internally consistent —
and needs no bytes at all. It is the fallback when the covered bytes are not at
hand, and its limit is worth knowing before you reach for it: the altered
document above answers `:valid` there, because nothing in the blob changed.
Prefer `verify/2` whenever you have the file.

## Whether it covers the whole file

A verdict is about the bytes in `:byte_range` and about nothing outside them, so
`covers_whole_document?/2` is the companion check rather than an optional extra
— a `:valid` signature over a file with an appended revision is the shape that
most often gets misread.

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

`:der` is the way out to OTP's `:public_key` or another certificate library,
which is where an actual trust decision gets made.
`PdfElixide.Signature.Certificate.parse/1` goes the other way, reading a
certificate you hold as DER — one out of a `dss/1` store, say. Nothing here makes one: the
"Nothing here is a trust decision" section of
`PdfElixide.Signature.Certificate` says what that means, and its "Names" section
covers how `:subject` and `:issuer` are rendered.

`Certificate.valid_at?/2` asks whether the certificate was within its validity
window at an instant **you** choose, and choosing it is the decision. The
signer's own `signing_time_utc/1` claim is unverified; a timestamp's `:time` is
a third party's account, and worth more only once you have checked both of the
questions below.

## Timestamps ask three separate questions

A timestamp raises three questions that sound alike and are not. Answering one
answers neither of the others:

| Question | Call |
|---|---|
| Is there a token at all? | `PdfElixide.Signature.timestamp/1` |
| Did the authority issue it? | `PdfElixide.Signature.Timestamp.verify/1` |
| Was it made over *this* signature? | `PdfElixide.Signature.verify_timestamp/2` |
| Is that authority one to trust? | Nothing here — yours to decide |

The second and third genuinely come apart:

```elixir
alias PdfElixide.Signature.Timestamp

{:ok, token} = Signature.timestamp(signature)

# A real token, genuinely issued by the authority …
Timestamp.verify(token)
#=> {:ok, :valid}

# … but made over something other than this signature.
Signature.verify_timestamp(signature, File.read!(path))
#=> {:ok, :invalid}
```

`timestamp/1` answers `{:ok, nil}` for a signature that carries no token — a
finding, distinct from the error a blob it cannot read produces. The
"What a verdict proves" section of `PdfElixide.Signature.Timestamp` says what
`verify/1` establishes, and its "Tokens that cannot be verified" section covers
the shapes that come back as an error rather than a verdict.

## PAdES baseline levels

The three arities of `pades_level` differ by what you have in hand, not by how
thorough they are. A lower arity is a narrower question, not a lesser document:

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

It takes a handle, so it happens **before** you close the document; everything
downstream of it is a plain value that outlives the close.

```elixir
{:ok, dss} = Signature.dss(doc)

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

`document_timestamp?/1` is the cheap yes/no; `document_timestamp/1` is what
hands the token back so its signature can be checked, and it is the one that
keeps "unreadable" apart from "absent". Finding the timestamp does not verify it —
that second step above is a separate question, exactly as it is for a
signature's own token.

## Places left to sign

`unsigned_fields/1` names the signature fields still waiting for a signature. On
a well-formed form it and `list/1` partition the named signature fields between
them, which is what answers "is this document fully executed":

```elixir
Signature.list!(doc) |> Enum.map(& &1.field_name)
#=> ["signature"]

Signature.unsigned_fields!(doc)
#=> ["countersign", "witness", "group.slot"]
```

A field whose value was cleared is a place left to sign and appears here. A
field the document gives no name is reported by neither call.

Flattening takes any signature field away with the rest of the AcroForm — the
"Flattening" section of the [Forms](forms.md) guide has that account.

## Damaged documents are refused, not stepped over

Signature reads and form reads disagree on a damaged document, deliberately.
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

`unsigned_fields/1` reads no signature at all, so that value-level strictness
does not reach it: a field pointing at something that is not a signature
dictionary is not a place left to sign, and is simply not listed. Ask `list/1`
about the value itself.

All three refuse, rather than read, a field hierarchy that is cyclic or nested
far deeper than any real form: a cycle as `:invalid_pdf`, a hierarchy past the
depth or size limit as `:unsupported`.

## Signature fields are not form fields

A signature field is not fillable and `PdfElixide.Form` omits it entirely,
signed or not, refusing to write to one rather than merely failing to find it.
The "Signature fields" section of the [Forms](forms.md) guide says why that
refusal has to be a refusal.

## Producing signatures is not offered

Nothing in this library signs a document, and that is a decision rather than
something not yet reached. A signature this library could produce would not be
attached to a form field, so `list/1` would not find it afterwards — being able
to sign a document but not to read back what you signed is not a contract worth
offering.

Sign with an external tool instead and open the result here: every call in this
guide reads a document signed elsewhere.

## What a signature call locks

`list/1`, `unsigned_fields/1`, `count/1` and `dss/1` take a *shared* read on
either source. Given an editor they read the document it was opened from, so
listing signatures does not serialize the way `PdfElixide.Form.fields/1` on an
editor does.

Everything else takes the signature struct, or the file's own bytes, rather than
a handle — so it takes no lock, cannot be delayed by other work on the document,
and keeps answering after that document is closed. See the
[Concurrency](concurrency.md) guide.
