# Forms

`PdfElixide.Form.fields/1` reads a PDF's AcroForm fields, from a read-only
`PdfElixide.Document` or from a mutable `PdfElixide.Editor` alike. Writing needs
an editor, since a document cannot be changed.

```elixir
alias PdfElixide.Document
alias PdfElixide.Editor
alias PdfElixide.Form

doc = Document.open!("path/to/form.pdf")

Form.fields!(doc)
#=> [%PdfElixide.Form.Field.Text{name: "full_name", kind: :single_line, value: "John Doe", …},
#    %PdfElixide.Form.Field.Button{name: "subscribe", kind: :check_box, value: true, …},
#    %PdfElixide.Form.Field.Choice{name: "country", kind: :list_box, value: nil, …}]
```

The read-only examples through "Field kinds and flags" reuse this `doc`; close
it after the last one.

## Fields and their values

A field comes back as one struct per field type, so the type is what you match
on: `PdfElixide.Form.Field.Text` (`/Tx`), `.Button` (`/Btn` — push buttons, check
boxes and radio groups), `.Choice` (`/Ch`), and `.Unknown` for a field with no
recognized type, which includes the grouping parents a nested form reports.
`PdfElixide.Form.Field` is the umbrella defining the union. Which widget a
button or choice field is, the struct's `:kind` says — see below.

Every struct carries the same six keys. `:name` is the field's fully qualified
name, dotted for a field nested under a parent — `"person.first"`, not `"first"`
— and is what every other function here addresses it by. `:value` is a
plain term: a string, `true`/`false`, a list of strings, or `nil` for a field
carrying no value. `:default_value` is the reset value the field itself
declares, in the same shapes — not always what a viewer's reset would restore,
for the reason "What a nested field inherits" gives. `:tooltip` is the text a
viewer shows on hover, and `:rect` the box the field occupies on the page.
`:flags` is described under "Field kinds and flags" below, along with the `:kind`
the first three also carry; the rest of the metadata is under "What else a field
reports".

`t:PdfElixide.Form.Field.value/0` is both what a field reports and what
`PdfElixide.Form.put_value/3` accepts. Anything else raises `ArgumentError`, so a
value read from one form can be written to another. Button fields are the
exception described below.

For one field there is no need to walk the list. `PdfElixide.Form.field/2`
returns the struct and `PdfElixide.Form.value/2` just its value, from either
source:

```elixir
Form.value!(doc, "full_name")
#=> "John Doe"

Form.field(doc, "country")
#=> {:ok, %PdfElixide.Form.Field.Choice{name: "country", kind: :list_box, value: nil, …}}
```

**`{:ok, nil}` and `:not_found` are different answers.** A field that exists but
carries no value is `{:ok, nil}`; a name the form does not carry is
`{:error, %PdfElixide.Error{reason: :not_found}}`, from `field/2` and `value/2`
as much as from `put_value/3`. The bang variants raise it instead.

## Field kinds and flags

A field's `/FT` says only that it is a button, a choice field or a text field.
Which *widget* it is — a check box or a radio group, a combo box or a list box —
is decided by bits in its `/Ff` entry, and those bits are what `:kind` reports:

| Struct | `:kind` | Default |
|---|---|---|
| `PdfElixide.Form.Field.Button` | `:check_box`, `:radio`, `:push` | `:check_box` |
| `PdfElixide.Form.Field.Choice` | `:combo_box`, `:list_box` | `:list_box` |
| `PdfElixide.Form.Field.Text` | `:single_line`, `:multiline` | `:single_line` |

```elixir
case Form.field!(doc, "subscribe") do
  %Form.Field.Button{kind: :check_box, value: checked?} -> checked?
  %Form.Field.Button{kind: :radio, value: selected} -> selected
  %Form.Field.Button{kind: :push} -> nil
end
```

A field declaring no `/Ff` is not unknown. Every bit is clear, producing the
defaults above. Many real forms declare no `/Ff` at all.

A field inherits `/Ff` from its ancestors. A radio-group parent can therefore
supply the flags for kids that carry none, and each kid still reports `:radio`.
A kid's own `/Ff` replaces the inherited value instead of merging bit by bit, so
a `:push` button under a `:radio` parent stays a push button. "What a nested
field inherits" below lists the other inherited keys.

`:flags` carries the whole entry decoded, one boolean per bit the specification
names for that type, plus `:raw` for anything it does not:

```elixir
Form.field!(doc, "notes").flags
#=> %PdfElixide.Form.Field.Text.Flags{multiline: true, password: false,
#     read_only: false, required: false, comb: false, …, raw: 4096}

:ok = Document.close(doc)
```

Each type has its own flags struct — `PdfElixide.Form.Field.Text.Flags`,
`.Button.Flags`, `.Choice.Flags` — because the same bit means different things
on different types. `PdfElixide.Form.Field.Unknown` carries
`PdfElixide.Form.Field.Flags`, which holds the three bits every field has:
`:read_only`, `:required` and `:no_export`.

`PdfElixide.Document.Annotation` reports the same classification for a widget
annotation, through its `:field_type`, so the two surfaces agree about a field
that appears on both.

## What else a field reports

Beyond its name, value and flags, a field carries the metadata a form filler
needs to render or validate it. Which keys a struct has depends on its type:

| Key | Text | Button | Choice | Unknown |
|---|:-:|:-:|:-:|:-:|
| `:tooltip`, `:rect`, `:default_value` | ✓ | ✓ | ✓ | ✓ |
| `:max_length` | ✓ | | | |
| `:alignment` | ✓ | | ✓ | |
| `:options` | | | ✓ | |

`:max_length` is the `/MaxLen` cap on how many characters may be entered; `0` is
a declared zero, not an absence. `:alignment` is `:left`, `:center` or `:right`,
and is `nil` both for a field declaring no justification and for one declaring a
value the PDF specification does not define.

`:rect` is the field's own box, which not every field has. A field and its widget
are often one dictionary, and then `:rect` is that widget's rectangle. A field
whose widgets are separate objects — a radio group, or any field appearing on
more than one page — reports `nil`, as does a field with no widget.

`:tooltip` reports `nil` both for absent text and text that could not be decoded.

### What a nested field inherits

A field inherits its type. A leaf under a text-field parent is therefore a
`PdfElixide.Form.Field.Text`, not an `Unknown`, even when it declares no type of
its own. A field's own type takes precedence.

Four more keys are resolved the same way, so a field nested under a parent
reports the parent's value where it declares none of its own:

  * `:flags`
  * `:options`
  * `:alignment`
  * `:max_length`

A field declaring its own replaces the inherited value outright rather than
combining with it — the rule holds for all four, so a `/MaxLen 3` leaf under a
`/MaxLen 12` parent caps at 3 and a `:push` button under a `:radio` parent stays
a push button.

The PDF specification does not require `:options` to be inherited, and readers
differ. This library reports a parent's `/Opt` for a nested field that declares
none, while a strict reader may report no options. Only a field's own `/Opt` is
portable across viewers.

`:value` and `:default_value` are not inherited this way. Each comes from the
field's own dictionary, so both report `nil` when only the parent carries `/V`
or `/DV`. A viewer may still inherit that default when resetting the form. Read
a named parent directly to reach its value; a grouping level with neither a name
nor a type is not reported and its value cannot be reached.

A field written *inline* rather than as an indirect reference inherits nothing.
The PDF specification requires `/Fields` and `/Kids` entries to reference
separate objects. A hand-built form that puts a field dictionary directly in
either array is still reported, but only with what its dictionary declares. Its
referenced children remain unaffected.

### A choice field's options

`:options` is what a combo box or list box permits, in the order the PDF lists
them:

```elixir
Form.field!(doc, "country").options
#=> ["FR", {"DE", "Germany"}, "IT"]
```

An entry is a plain string when the PDF spells the option as one value, and
`{export, display}` when it spells it as a pair. This API reads and writes the
export value; the display value is what a viewer shows. `{"DE", "Germany"}` is
therefore one option, not two.

```elixir
# Every value this field will accept, whichever way each option is spelled.
Enum.map(field.options, fn
  {export, _display} -> export
  export -> export
end)
```

`nil` means the field declares no options at all; `[]` means it declares an
empty list. An entry the PDF spells as neither a string, a name nor a pair is
skipped, and the options around it are still reported.

Options follow the inheritance rules above. A field's own `/Opt` replaces the
inherited list rather than extending it.

`PdfElixide.Document.Annotation` also reports a widget's options, but as export
values only — `["FR", "DE", "IT"]` for the field above. A field's `:options` is
the one that keeps the display text.

## Filling a form

Open the file as an editor, write values, then persist. Every call that changes
an editor returns it, so the whole thing is one pipeline:

```elixir
editor = Editor.open!("path/to/form.pdf")

try do
  editor
  |> Form.put_value!("full_name", "Jane Doe")
  |> Form.put_value!("subscribe", true)
  |> Editor.save!("path/to/filled.pdf")

  :ok
after
  Editor.close(editor)
end
#=> :ok
```

The values are the plain terms `fields/1` returns — no wrapper or tag. Fields
are addressed by name, and only existing fields can be written. An unknown name
is an error; this API cannot add fields.

## The tuple-returning half

The non-bang functions are uniform in the same way — each returns
`{:ok, editor}` — so they read as one `with/1` with no shape changes in the
middle:

```elixir
with {:ok, editor} <- Editor.open("path/to/form.pdf") do
  try do
    with {:ok, editor} <- Form.put_values(editor, %{"full_name" => "Jane Doe"}),
         {:ok, _editor} <- Editor.save(editor, "path/to/filled.pdf") do
      :ok
    end
  after
    Editor.close(editor)
  end
end
#=> :ok
```

`PdfElixide.Editor.to_binary/2` and `PdfElixide.Editor.close/1` are the two ways
such a mutating pipeline ends: one hands back bytes, the other `:ok`. Every
mutating step before them hands back the editor.

## Several fields at once

`PdfElixide.Form.put_values/2` takes a map with string keys, or a list of
`{name, value}` pairs, and **validates all of them before it writes any**:
unknown names, duplicates, names that are not strings and values outside
`t:PdfElixide.Form.Field.value/0` are all caught up front, against a single
`fields/1` read.

```elixir
{:ok, editor} = Form.put_values(editor, %{"full_name" => "Jane Doe", "subscribe" => true})

# A list when the order matters — a map is applied in `Enum` order, which is unspecified.
{:ok, editor} = Form.put_values(editor, [{"full_name", "Jane Doe"}, {"country", ["Canada"]}])
```

**It is not a transaction.** A failure after validation stops at the first
error, with any earlier writes already applied. It is a convenience for
validation and composition, not an atomic batch.

`PdfElixide.Form.update_value/3` transforms a field in place, handing `fun` the
current value and writing back whatever it returns:

```elixir
{:ok, editor} = Form.update_value(editor, "full_name", &String.upcase/1)

# A field carrying no value hands `fun` a nil.
{:ok, editor} = Form.update_value(editor, "country", fn
  nil -> ["Canada"]
  other -> other
end)
```

This is not an atomic read-modify-write. Another process holding the same editor
can write between the read and the write.

## Saving

Nothing is written until `PdfElixide.Editor.save/3` writes a file or
`PdfElixide.Editor.to_binary/2` hands back the bytes, and neither consumes the
editor: keep editing and write again. `close/1` **discards unsaved edits**, so
write before you close.

```elixir
{:ok, editor} = Editor.save(editor, "path/to/filled.pdf")
{:ok, bytes} = Editor.to_binary(editor)
```

Both accept `t:PdfElixide.Editor.save_opts/0`: `:incremental`, `:compress`
and `:garbage_collect`. The exception is `to_binary/2` with
`incremental: true`, which returns
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}`: an incremental update must
be appended to the original file, so use `save/3` for one.

For form filling against an existing PDF, an incremental save appends only the
field-value updates and leaves the original AcroForm structure as it was:

```elixir
{:ok, editor} = Editor.save(editor, "path/to/filled.pdf", incremental: true)
```

`to_binary/2` clears `PdfElixide.Editor.modified?/1` even though it writes no
file; an incremental `save/3` leaves it set.

`to_binary/2` builds the whole output in native memory before copying it into an
Elixir binary, so peak usage includes both copies on top of the editor. For a
very large document, prefer `save/3`, which writes to the file without that
second full-size buffer.

## Exporting field data

`PdfElixide.Form.export/3` hands the form's values back on their own, as FDF or
XFDF bytes, so filled data can go somewhere the PDF around it is not needed — a
batch process, a web form, another document.

```elixir
editor = Editor.open!("path/to/form.pdf")

editor
|> Form.put_value!("full_name", "Jane Doe")
|> Form.put_value!("subscribe", true)

File.write!("path/to/data.xfdf", Form.export!(editor, :xfdf))
```

It reads from either source, like `fields/1`. From an editor it includes values
written but **not yet saved**, so filling and exporting need no write in between;
from a document it reports what the file holds.

```elixir
doc = Document.open!("path/to/form.pdf")
Form.export!(doc, :fdf)
```

What comes out is exactly what `PdfElixide.Form.fields/1` reports for the same
source, under the same fully qualified names — `person.first`, not `first`. That
is also the limit: an exported check box value is not always faithful, per
"Check boxes and radio groups" below.

### Which format

`:fdf` is the binary Forms Data Format of ISO 32000-1 §12.7.7. `:xfdf` is its
XML counterpart. Both name every field and carry its value; they differ in what
they can carry faithfully.

**`:fdf` cannot represent a value outside ASCII.** It writes the value as UTF-8
inside a PDF literal string, where a conforming reader decodes it as
PDFDocEncoded — so even a Latin-1 name like `"Müller"` arrives as `MÃ¼ller`.
`:xfdf` is UTF-8 XML with a declared encoding and carries any value correctly.

**Prefer `:xfdf` unless every value is certainly ASCII**, or unless the tool
receiving the data reads only FDF.

**Neither format escapes a control character.** A value or field name holding
one XML forbids — `NUL`, the rest of `0x01`–`0x1F` apart from tab, newline and
carriage return, and `U+FFFE`/`U+FFFF` — is written through verbatim, which
makes the XFDF not well-formed XML even though the export reports success. A
`:file_spec` carrying one raises, since you supplied it and can fix it. One
already in the PDF's own field names or values does not, since refusing it would
make a document you cannot edit un-exportable.

Two XFDF shapes to know before parsing it back. A multi-select field's values
are joined into one `<value>` element separated by commas, so a value containing
a comma cannot be told from two values. And a field whose value is the empty
string emits no `<value>` element, which is what a field with no value emits
too. FDF keeps both distinctions — an array stays an array, and only a valueless
field omits `/V`.

### Naming the source file

`:file_spec` writes the name of the PDF the data came from into the output, so a
reader opening the exported file can pair the two:

```elixir
Form.export!(doc, :fdf, file_spec: "form.pdf")
#=> "%FDF-1.2\n…/F (form.pdf)…"

Form.export!(doc, :xfdf, file_spec: "form.pdf")
#=> ~s(…<f href="form.pdf"/>…)
```

It is a label carried in the exported bytes, not a path this library reads or
writes, and nothing fills it in from the handle. A non-ASCII `:file_spec` carries
the same FDF caveat as a non-ASCII value.

### What is left out, and what is not

Signature fields are omitted, in both formats and from both sources, exactly as
`fields/1` omits them.

A field flagged **NoExport** is *not* omitted. The PDF specification defines
that flag for submit-form actions, and this API exports every field it reports.
`:no_export` on the field's flags struct is what identifies them:

```elixir
Form.fields!(doc) |> Enum.reject(& &1.flags.no_export)
```

### There is no import

Nothing here reads FDF or XFDF back. `PdfElixide.Form.put_values/2` is how data
comes into a form.

## Flattening

Flattening draws a field's appearance into the page content and takes the
interactive field away, so the written PDF shows the filled values but can no
longer be edited. `PdfElixide.Form.flatten/1` covers the whole document,
`flatten/2` one page:

```elixir
editor
|> Form.put_value!("full_name", "Jane Roe")
|> Form.flatten!()
|> Editor.to_binary!()
```

`PdfElixide.Editor.flatten_annotations/1,2` is the same idea for annotations —
notes, highlights, stamps — and is a separate mark from the form one.

**Nothing happens until the next full write.** Both calls only *mark* what to
flatten; the drawing happens inside `PdfElixide.Editor.save/3` or
`PdfElixide.Editor.to_binary/2`. Until then `Form.fields/1` still reports every
field, because the editor is unchanged — what changes is the file you write.
`PdfElixide.Editor.modified?/1` does go true at mark time.

**An incremental save does not flatten.** `save(editor, path, incremental: true)`
writes an unflattened file, reports no error and produces no warnings. An
incremental update appends to the original, and the original's fields are still
there. Write with `save/3` without `:incremental`, or with `to_binary/2`.

**A mark cannot be removed, and it applies to every later write.** There is no
unflatten; reopen the source if you need an unflattened document. Writing twice
gives you two flattened files.

### What each one leaves behind

`Form.flatten/1` removes the document's AcroForm outright. `Form.flatten/2`
keeps it, rebuilt to hold only the fields that still have a widget on a page you
left alone. A field whose widgets do not say which page they are on is kept by a
partial flatten regardless of the selected page. **`Form.flatten/1` takes any
signature field with the AcroForm**, so a signed document comes back unsigned —
the signature dictionary is still in the file, but nothing points at it.
`flatten/2` keeps a signature field whose widgets are not on a page you flattened.
Any non-incremental write invalidates a signature whether or not it also removes
the field.

Both remove form-field widgets from a page's annotations while leaving notes,
links, and highlights unchanged. In hand-built PDFs, however, an annotation
written *inline* in `/Annots` rather than as an indirect reference is silently
dropped regardless of type.

`Editor.flatten_annotations/1,2` is blunter. On a page where at least one
annotation appearance can be produced, it removes **every annotation entry**,
including form field widgets and annotations it could not draw. A skipped
annotation can therefore be deleted without being rendered or reported. If no
annotation on the page produces an appearance, the write creates no flatten data
for that page and draws or removes nothing.

Do not mark both kinds of flattening on the same page: where appearances are
produced, the two marks are applied independently and fields can be drawn twice.

### Check the warnings

`PdfElixide.Editor.flatten_warnings/1` lists what could not be flattened
faithfully. It is empty until a write has happened, and it accumulates for the
life of the editor rather than being cleared per write — so read it after the
write you care about:

```elixir
{:ok, bytes} = editor |> Form.flatten!() |> Editor.to_binary()

for warning <- Editor.flatten_warnings!(editor) do
  Logger.warning("flatten: #{warning}")
end
```

**Treat an empty list as "nothing was reported", not as "nothing was lost".** The
list is a best effort: an inline annotation is dropped with no entry, and so is a
widget whose appearance stream cannot be loaded. An empty list cannot establish
that flattening was faithful.

Reported cases include:

- **A newly set value containing non-Latin text or emoji that the shipped
  appearance path cannot render faithfully.** The field may contain incorrect
  glyphs or none at all while the PDF remains valid. Check the warnings after
  filling and flattening text outside Latin-1. Existing appearance streams are
  copied unchanged and are unaffected.

  The warning may tell you to rebuild with an optional feature. The installed
  package is precompiled and cannot be reconfigured that way. Read the warning
  as "this field did not flatten legibly" and handle it in your own code — leave
  the form unflattened, substitute a value the field's font can render, or draw
  the text yourself before flattening.
- **A field with no appearance stream that could not be given one.** The warning
  names the field. If another appearance causes that page to be flattened, the
  field is removed without being drawn; if the page produces no appearances at
  all, nothing on it is drawn or removed.
- **An XFA form left as it was** after a per-page flatten, whose XFA data may
  still reference widgets that are now gone.

## An editor is a handle, not a value

The editor returned by a mutating call is the same handle that went in:

```elixir
editor = Editor.open!("path/to/form.pdf")
filled = Form.put_value!(editor, "full_name", "Jane")
# `editor` and `filled` are the same handle — the original is filled too.
:ok = Editor.close(editor)
```

A pipeline therefore sequences effects; an earlier binding does not preserve
the document's previous state. Reopen the source when a separate state is
needed. The [Concurrency](concurrency.md) guide describes sharing editor and
form handles across processes.

## Signature fields

A signature field (`/FT /Sig`) is not a fillable field, and this API does not
have one: `fields/1` omits it, and `field/2`, `value/2` and `put_value/3` all
answer `{:error, %PdfElixide.Error{reason: :not_found}}` for its name, the same
result as an unknown field name. `put_values/2` reports it the same way, from the
`fields/1` read it validates against.

A signature's `/V` is a signature dictionary rather than a form value. This API
never writes over it; doing so — with `nil` included — would replace that
dictionary and silently remove the signature.

Flattening is the exception: `PdfElixide.Form.flatten/1` removes the whole
AcroForm and a signature field goes with it, as "Flattening" above describes.

This holds for a field whose `/FT` is declared on an ancestor rather than on the
field itself, which the PDF specification permits.

Reading the signatures themselves is a separate capability, and
`PdfElixide.Signature` is where it lives. The [Signatures](signatures.md)
guide covers listing, byte verification, certificates, timestamps, and damaged
documents that signature reads reject but field reads tolerate.

## Check boxes and radio groups

`:kind` tells the two apart, per "Field kinds and flags" above. What follows
applies to both, and to producing a value rather than reading one — writing one
back with `put_value/3`, or exporting one with `export/3`.

Setting a button field writes `/Yes` for `true` and `/Off` for `false`, and those
are the only two states `put_value/3` can produce. That makes the read-then-write
round trip lossy for some check boxes and radio groups, in two ways.

**A box whose on-state is `/On` rather than `/Yes` becomes unchecked after a
read-then-write round trip.** It reads as `true`, since both names mean
"checked", but writing that `true` back emits `/Yes` — which is not the state
the widget declares. Nothing in the value reveals this; the two spellings are
indistinguishable once read. (`/No` collapses to `false` and writes `/Off` in the
same way, but harmlessly: `/Off` is the off state for every check box.)

`export/3` loses it identically, and there the loss travels: an `/On` box
exports as `Yes` in both formats, so data exported from one copy of a form
cannot re-check that box in another. A custom on-state survives an export, since
it is never collapsed to `true` in the first place.

**A box whose on-state is a *custom* name — `/Export1`, say — cannot be checked
at all.** `true` writes `/Yes`, which matches no widget state, and no other value
writes a PDF name either. Writing the on-state's name as a string is not a
workaround and makes matters worse: it goes into `/V` *and* is copied into the
widget's `/AS`, where the PDF specification requires a name, so a reader may
render the field wrongly.

Either field needs its dictionaries edited directly, which this library does not
expose. Reading such a field is unaffected; it is only the value produced from
it — written back, or exported — that is wrong.
