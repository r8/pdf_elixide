# Encryption

`PdfElixide.Editor.save/3` and `PdfElixide.Editor.to_binary/2` take an
`:encryption` option that writes a password-protected PDF. It is the only way
this library produces encryption; reading an encrypted document is
`PdfElixide.Document.open/2`'s `:password` option, which is unrelated and takes
different values.

```elixir
alias PdfElixide.Document
alias PdfElixide.Editor

editor = Editor.open!("path/to/in.pdf")

try do
  Editor.save!(editor, "path/to/out.pdf",
    encryption: [
      user_password: "open-me",
      owner_password: "change-security-settings",
      permissions: [copy: false, modify: false]
    ]
  )
after
  Editor.close(editor)
end
```

The result opens in any conforming reader with the user password, and
`PdfElixide.Document.permissions/1` reads back exactly the flags that were
written.

Encryption is applied by the writer, so it is a property of the *output*, not of
the editor: the same editor can write an encrypted file and an unencrypted one,
and nothing about the source document is changed.

This only ever *adds* encryption. `PdfElixide.Editor.open/1` and
`PdfElixide.Editor.from_binary/1` refuse an already-encrypted document with
`{:error, %PdfElixide.Error{reason: :encrypted}}` — the editor takes no password
and cannot decrypt — so there is no way to change, re-key or remove the
encryption a document already carries.

Both calls take the editor's exclusive lock, like every other write — see the
[Concurrency](concurrency.md) guide.

## Algorithms

`:algorithm` chooses the cipher. Use `:aes128` unless a legacy reader requires
`:rc4_128`.

| Value | Dictionary | Needs | Notes |
|---|---|---|---|
| `:aes128` | `/V 4 /R 4 /CFM /AESV2` | PDF 1.6 | The default. The strongest algorithm available here. |
| `:rc4_128` | `/V 2 /R 3` | PDF 1.4 | RC4 is broken. Legacy readers only. |

`:aes256` and `:rc4_40` raise `ArgumentError`. AES-256 output would be
unreadable even with the correct password; RC4-40 cannot express the supported
permission combinations.

### The declared version is not raised to match

The output keeps `PdfElixide.Editor.version/1`, with no version override.
Encrypting a PDF 1.4 document with `:aes128` therefore declares PDF 1.4 while
using a feature that requires PDF 1.6.

Common readers accept this output, but conformance validators may reject the
mismatch. PDF/A forbids encryption regardless of the version declaration.

This library cannot change the declared version. If a downstream tool requires
it to match, use a source document of the required version or adjust the version
with another tool. `:rc4_128` matches PDF 1.4 and later, but its broken cipher
makes it a poor substitute for AES merely to satisfy a version check.

## Passwords

  * `:user_password` is required to open the document.
  * `:owner_password` grants full access and the right to change the security
    settings.

Both are UTF-8 `t:String.t/0`; `PdfElixide.Document.open/2`'s `:password` accepts
arbitrary bytes. Non-ASCII passwords written here can be used to reopen the
document here, but may not match another tool's PDFDocEncoding representation
of the same characters. **Use ASCII passwords for anything another tool has to
open.**

Only the first 32 bytes of a password are used; a longer one is truncated
without complaint.

Both default to `""`, and each empty value means something distinct:

  * An empty `:user_password` produces a document that opens with no prompt but
    still carries the permission flags. This is the ordinary shape for
    "anyone may read it, but not print it".
  * An empty `:owner_password` makes the **user password serve as the owner
    password**. Everyone who can open the document then holds owner rights and
    can lift the restrictions, which is almost never what a caller setting
    permissions intends. Set both.
  * Both empty encrypts the document under the empty password, which protects
    nothing.

## Permissions

`:permissions` takes the eight flags of `PdfElixide.Document.Permissions`, each
defaulting to `true`. They are written into the `/P` entry of the encryption
dictionary.

Per the PDF specification these flags are **advisory**. A conforming reader is
asked to honour them; nothing enforces them, and a reader that holds the user
password holds everything needed to ignore them. Treat them as a statement of
intent, not as access control. Encryption protects the bytes from someone
without the password; permissions do not protect them from someone with it.

`PdfElixide.Document.permissions/1` returns `nil` for an unencrypted document,
so flags without a password are not expressible — writing them means encrypting.

### They are independent, with one exception

`:fill_forms` permits form filling even when `:annotate` is `false`;
`:assemble` permits assembly even when `:modify` is `false`. Likewise,
`copy: false, accessibility: true` denies general extraction while permitting
assistive technology to extract content.

High-resolution printing requires both `:print_low_res` and `:print_high_res`
to be `true`. Setting `print_low_res: false` denies printing altogether.

## A failed encryption is not reported

If the platform's cipher or random source fails during encryption, an affected
string or stream may be written in the clear while the write continues.

Nothing in the result distinguishes such a file from a fully encrypted one:
`save/3` still returns `{:ok, editor}`, the file still declares itself
encrypted, `PdfElixide.Document.encrypted?/1` is still `true`, and the password
still authenticates. The consequence runs the other way — an object left in the
clear is readable by someone **without** the password.

For security-critical output, reopen it and read from it:

```elixir
doc = PdfElixide.Document.open!("locked.pdf", password: "open-me")
PdfElixide.Document.text!(doc, 0)
```

An object left in the clear is decrypted anyway on the way out, so it comes back
as garbage. Text that reads back correctly is therefore evidence that the
content was encrypted, not proof, and it says nothing about an object the reader
did not touch.

## Incremental saves

`save/3`'s `:encryption` cannot be combined with `incremental: true`, and the
pair raises `ArgumentError`. Use a full rewrite, which is `save/3`'s default,
to encrypt the output.

## What a rewrite changes

Encrypting takes the full-rewrite path, which rebuilds the file rather than
appending to it. Three consequences are worth knowing:

  * The trailer gains a freshly generated `/ID`.
  * Metadata is encrypted along with everything else, with no option to leave
    an XMP packet in the clear — and `PdfElixide.Document.xmp_metadata/1`
    cannot read the result back. It reports a stream decoding error even when
    given the correct password, so read XMP from the source document rather
    than from the encrypted output.
  * The `/Info` dictionary is dropped, as it is on every write. The "Document
    information is not carried over" section of `PdfElixide.Editor` has that in
    full.

Existing digital signatures do not survive a rewrite — encrypted or not — since
a signature covers the exact bytes of the file it was made over.
