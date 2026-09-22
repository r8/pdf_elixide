# Encryption

`PdfElixide.Editor.save/3` and `PdfElixide.Editor.to_binary/2` take an
`:encryption` option that writes a password-protected PDF. It is the only way
this library produces encryption; opening a document that is *already*
encrypted is the `:password` option of `PdfElixide.Document.open/2` and
`PdfElixide.Editor.open/2`, which is unrelated and takes different values — see
[Editing a document that is already encrypted](#editing-a-document-that-is-already-encrypted).

```elixir
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

## Editing a document that is already encrypted

`PdfElixide.Editor.open/2` and `PdfElixide.Editor.from_binary/2` take a
`:password`, so an encrypted document can be edited, re-keyed, or written out
without its encryption. Without one, only the empty password is tried. A
document that needs another password returns `:encrypted`; a wrong password
returns `:wrong_password`.

The password authenticates the *source*. Omitting `:encryption` from a write
removes encryption; supplying new passwords re-keys the output.

```elixir
alias PdfElixide.Editor

editor = Editor.open!("path/to/locked.pdf", password: "open-me")

try do
  Editor.save!(editor, "path/to/decrypted.pdf")

  Editor.save!(editor, "path/to/rekeyed.pdf",
    encryption: [user_password: "new-password", owner_password: "new-owner"]
  )
after
  Editor.close(editor)
end
```

The source password is a *byte string*, like
`PdfElixide.Document.open/2`'s. The `:user_password` and `:owner_password` of
`:encryption` are `t:String.t/0` — see [Passwords](#passwords), which explains
the difference.

## What an encrypted source cannot do

These operations return `{:error, %PdfElixide.Error{reason: :unsupported}}`:

  * `PdfElixide.Editor.apply_redactions/1,2`, and `PdfElixide.Editor.add_redaction/3,4`
    with it
  * `PdfElixide.Editor.flatten_annotations/1,2`
  * `PdfElixide.Form.flatten/1,2`
  * a save with `incremental: true`; see [Incremental saves](#incremental-saves)

A rewrite is also refused when an encrypted source stores its XMP metadata in
the clear. Remove the metadata deliberately before writing:

```elixir
editor = Editor.open!("path/to/searchable-metadata.pdf", password: "open-me")
Editor.sanitize!(editor,
  scrub_metadata: true,
  remove_javascript: false,
  remove_embedded_files: false
)
Editor.save!(editor, "path/to/out.pdf")
Editor.close(editor)
```

`scrub_metadata: true` also empties the document information dictionary, so the
title, author and dates go with the XMP. Read anything you need with
`PdfElixide.Document.xmp_metadata/1` or `PdfElixide.Document.metadata/1` first.

Nothing is changed when one of these is refused, and the editor stays usable.
Other edits, including form filling, document information and ordinary page
changes, work normally. Redaction marking is also unaffected.

To redact or flatten, first make a full rewrite, reopen it, and repeat the
operation. Prefer an in-memory intermediate and keep it only as long as needed,
because that intermediate is decrypted. Add `:encryption` when writing the
final result if it should remain protected.

## Algorithms

`:algorithm` chooses the cipher. Use `:aes128` unless a legacy reader requires
`:rc4_128`.

| Value | Dictionary | Needs | Notes |
|---|---|---|---|
| `:aes128` | `/V 4 /R 4 /CFM /AESV2` | PDF 1.6 | The default. The strongest algorithm available here. |
| `:rc4_128` | `/V 2 /R 3` | PDF 1.4 | RC4 is broken. Legacy readers only. |

`:aes256` and `:rc4_40` raise `ArgumentError`. RC4-40 cannot express the
supported permission combinations, and AES-256 output is not interoperable
with all conforming readers. This concerns output only: an AES-256 document
produced elsewhere opens here normally, permission flags included.

### The declared version is not raised to match

The output keeps `PdfElixide.Editor.version/1`, with no version override.
Encrypting a PDF 1.4 document with `:aes128` therefore declares PDF 1.4 while
using a feature that requires PDF 1.6.

Common readers accept this output, but conformance validators may reject the
mismatch. PDF/A forbids encryption regardless of the version declaration.

This library cannot change the declared version. If a downstream tool requires
it to match, use a source document of the required version or adjust the version
with another tool. `:rc4_128` matches PDF 1.4 and later, but RC4 is
cryptographically broken, so it is not a security-equivalent way to reach that
version.

## Passwords

  * `:user_password` is required to open the document.
  * `:owner_password` grants full access and the right to change the security
    settings.

Both are UTF-8 `t:String.t/0`; `PdfElixide.Document.open/2`'s `:password` accepts
arbitrary bytes. Non-ASCII passwords written here can be used to reopen the
document here, but may not match another tool's PDFDocEncoding representation
of the same characters. **Use ASCII passwords for anything another tool has to
open.**

Only the first 32 bytes of a password are used; a longer one is truncated, with
no error.

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

Reopening the output with its password is only a partial check:

  * Under `:aes128`, a **stream** written in the clear normally fails to
    decrypt. Page text may then be empty or incomplete while extraction still
    returns `{:ok, _}` — see the `:on_page_error` section of
    `t:PdfElixide.Document.text_opts/0`. `PdfElixide.Logging` reports the
    rejection at `:error` as `Decryption failed for object N`.
  * Under `:aes128`, a **string** written in the clear reads back unchanged; an
    encrypted string looks the same. Under `:rc4_128`, the cleartext string
    instead reads back as garbage. Reading a title, form value, annotation
    comment or outline entry therefore does not verify its encryption.

Neither says anything about an object the reader did not touch.

## Incremental saves

`save/3`'s `:encryption` cannot be combined with `incremental: true`, and the
pair raises `ArgumentError`. Use a full rewrite, which is `save/3`'s default,
to encrypt the output.

An encrypted *source* cannot be saved incrementally either, whatever the
options. An incremental update is appended to the original file rather than
rewritten, and this library does not encrypt what it appends, so the result
would not open. `incremental: true` returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` on such an editor, whether
it was opened from a path or from a binary; write a full rewrite instead.

For other incremental-save restrictions, see [Saving edits](editing.md#saving-edits).

## What a rewrite changes

Encrypting takes the full-rewrite path, which rebuilds the file rather than
appending to it. Three consequences are worth knowing:

  * The trailer gains a freshly generated `/ID`.
  * Metadata is encrypted along with everything else, with no option to leave
    an XMP packet in the clear — and `PdfElixide.Document.xmp_metadata/1`
    cannot read the result back. It reports a stream decoding error even when
    given the correct password, so read XMP from the source document rather
    than from the encrypted output.
  * The `/Info` dictionary is carried over and its strings are encrypted like
    every other; `/Trapped` is dropped, as it is on every write. See
    [Document information](editing.md#document-information).

Existing digital signatures do not survive a rewrite — encrypted or not — since
a signature covers the exact bytes of the file it was made over.
