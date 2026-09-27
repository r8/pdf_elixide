# PDF/A conversion

`PdfElixide.Compliance.convert/3` converts the document held by an editor and
reports what it changed and what remains unresolved:

```elixir
alias PdfElixide.Compliance
alias PdfElixide.Editor

editor = Editor.open!("path/to/report.pdf")

try do
  conversion = Compliance.convert!(editor, :pdf_a_2b)

  if conversion.report.compliant? do
    Editor.save!(editor, "report-pdfa.pdf")
  end
after
  Editor.close(editor)
end
```

Conversion validates the document, applies the fixes it supports, and validates
the result again. `conversion.report` is that second report. It is subject to
the limitations described by `PdfElixide.Compliance` and is not a conformance
certification.

## What conversion fixes

Conversion can declare the requested level in XMP metadata, add an sRGB output
intent, remove JavaScript, remove attachments where the level forbids them, and
set the document language to `en` for a level `a` target that declares none. The
options to `PdfElixide.Compliance.convert/3` can disable some of these fixes.

Anything else stays in the report. In particular:

  * Missing fonts remain unembedded unless `embed_fonts: true` is given.
  * A level `a` target needs a tagged document, and conversion adds no tags.
  * Transparent content can remain in a PDF/A-1 result because the transparency
    check is partial and conversion does not flatten it.

The conversion succeeds even when findings remain. Check
`conversion.report.compliant?`, `conversion.actions` and
`conversion.failures`.

## Convert last

Conversion starts from what a full write of the editor would produce, including
pending page edits, field values and attachments. It then replaces the editor's
document with the converted result. `PdfElixide.Editor.modified?/1` remains
`true` until a full write.

Convert after merging, extracting pages and making other edits:

  * Incremental saves are refused after conversion. Write a full rewrite.
  * Encryption is refused while the document declares PDF/A.
  * A PDF/A-1 editor must be written with `compress: false`.
  * Merging into a PDF/A-1 editor is refused. Merge first, then convert.
    Merging into a PDF/A-2 or PDF/A-3 editor keeps the declaration and its
    restrictions.
  * Extracted pages keep the PDF/A declaration, but PDF/A-1 extraction
    compresses their XMP metadata. Extract first and convert each output.

If edits after conversion are unavoidable, validate the bytes you write rather
than relying on the conversion report.

Sanitizing with `scrub_metadata: true` removes the PDF/A declaration and lifts
the associated write restrictions.

An editor opened with a password converts to an unencrypted document. Conversion
is refused, without changing the editor, when the editor has no pages, when
rebuilding would lose a pending redaction, or when an encrypted source carries
unencrypted XMP metadata.

## Existing XMP and metadata

Conversion does not replace a PDF/A level already declared in XMP. If the level
differs from the requested target, remove the metadata or convert to the
declared level.

PDF/A-1 conversion is also refused whenever the document already carries XMP
metadata, because the existing stream would remain compressed. Remove it first
when replacing its properties is acceptable:

```elixir
Editor.sanitize!(editor,
  scrub_metadata: true,
  remove_javascript: false,
  remove_embedded_files: false
)
```

When conversion changes the document, its information dictionary is not
carried over, so `PdfElixide.Editor.metadata/1` no longer reports its title or
author. When no action is needed, the dictionary is kept. Do not add it back
without keeping it consistent with the XMP metadata; validation does not compare
the two.

A full rewrite also produces no document identifier (`/ID`). PDF/A requires
one, so a dedicated conformance validator can reject a file even when
`conversion.report.compliant?` is `true`. Add the identifier with another tool
when external conformance validation requires it. See
[XMP and document identifiers](editing.md#xmp-and-document-identifiers).

## Embedded fonts

With `embed_fonts: true`, conversion searches the fonts installed on the
machine and embeds the entire matching font file. It may substitute a similar
family for a standard PDF font.

The result can vary by machine, grow by megabytes per font, or contain a font
collection or format that another tool rejects despite a compliant report. The
first embedding conversion in a running node also scans installed fonts and can
take several seconds. Prefer embedding fonts when producing the source PDF.
