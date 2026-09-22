# Forms

`PdfElixide.Form.fields/1` reads a PDF's AcroForm fields, from a read-only
`PdfElixide.Document` or from a mutable `PdfElixide.Editor` alike. Writing needs
an editor, since a document cannot be changed.

An **encrypted** document needs its password either way: `fields/1` reads one
through a document opened with `PdfElixide.Document.open/2`'s `:password`, and
fills through an editor opened with `PdfElixide.Editor.open/2`'s. The
[Encryption](encryption.md) guide has the workflow.

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

The read-only examples below reuse this `doc` unless they open their own; close
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
```

Each type has its own flags struct — `PdfElixide.Form.Field.Text.Flags`,
`.Button.Flags`, `.Choice.Flags` — because the same bit means different things
on different types. `PdfElixide.Form.Field.Unknown` carries
`PdfElixide.Form.Field.Flags`, which holds the three bits every field has:
`:read_only`, `:required` and `:no_export`.

`PdfElixide.Document.Annotation` classifies a widget annotation through its
`:field_type`, and for the three **button** kinds the two surfaces agree — the
reading comes from the same `/Ff` bits. They do not agree beyond that:
`:field_type` collapses combo box and list box into one `{:choice, …}` and draws
no multiline distinction on a text field.

## What else a field reports

Beyond its name, value and flags, a field carries the metadata a form filler
needs to render or validate it. Which keys a struct has depends on its type:

| Key | Text | Button | Choice | Unknown |
|---|:-:|:-:|:-:|:-:|
| `:tooltip`, `:rect`, `:default_value` | ✓ | ✓ | ✓ | ✓ |
| `:max_length` | ✓ | | | |
| `:alignment` | ✓ | | ✓ | |
| `:options` | | | ✓ | |
| `:on_states` | | ✓ | | |
| `:raw_type` | | | | ✓ |

`:max_length` is the `/MaxLen` cap on how many characters may be entered; `0` is
a declared zero, not an absence. `:alignment` is `:left`, `:center` or `:right`,
and is `nil` both for a field declaring no justification and for one declaring a
value the PDF specification does not define.

`:rect` is the field's own box, which not every field has. A field and its widget
are often one dictionary, and then `:rect` is that widget's rectangle. A field
whose widgets are separate objects — a radio group, or any field appearing on
more than one page — reports `nil`, as does a field with no widget.

`:tooltip` reports `nil` both for absent text and text that could not be decoded.

`:on_states` lists each non-`Off` appearance state declared by a button's
widgets, in widget order. `[]` means no states were found, including for a field
with no widget. "Check boxes and radio groups" below shows how to use it.

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

`:value`, `:default_value` and `:on_states` are not inherited this way. The
first two come from the field's own dictionary; `:on_states` comes from its
widgets. A viewer may still inherit a parent's default when resetting the form.
Read a named parent directly to reach its value; a grouping level with neither
a name nor a type is not reported and its value cannot be reached.

A field written *inline* rather than as an indirect reference inherits nothing.
The PDF specification requires `/Fields` and `/Kids` entries to reference
separate objects. A hand-built form that puts a field dictionary directly in
either array is still reported, but only with what its dictionary declares. Its
referenced children remain unaffected.

### A choice field's options

`:options` is what a combo box or list box permits, in the order the PDF lists
them:

```elixir
field = Form.field!(doc, "country")
field.options
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
the widget declares. Check `"Yes" in field.on_states` before writing `true`;
`["On"]` means the write will not check the box. (`/No` collapses to `false`
and writes the universal `/Off` state harmlessly.)

An empty `:on_states` decides nothing: the widget declares no states, so there
is nothing to compare `/Yes` against.

`export/3` loses it identically, and there the loss travels: an `/On` box
exports as `Yes` in both formats, so data exported from one copy of a form
cannot re-check that box in another. The same `:on_states` check predicts it.
A custom on-state survives an export because it is not collapsed to `true`.

**A box whose on-state is a *custom* name — `/Export1`, say — cannot be checked
at all.** `true` writes `/Yes`, which matches no widget state, and no other value
writes a PDF name either. `:on_states` reveals the custom name but does not make
it writable. Writing it as a string is not a workaround: it also puts a string
in the widget's `/AS`, where the PDF specification requires a name, so a reader
may not render the field as intended.

Either field needs its dictionaries edited directly, which this library does not
expose. Reading such a field is unaffected; the limitation is in the value
produced from it — written back, or exported.

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

**A cyclic or excessively large field hierarchy is refused rather than
walked.** Functions that read fields reject a cycle with
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}`; the depth and size caps
return `{:error, %PdfElixide.Error{reason: :unsupported}}`. An unreadable field
object is different: ordinary form reads step over it and return the fields they
could reach, so a successful list can still be partial. Signature reads are
stricter; see [Damaged documents are refused, not stepped over](signatures.md#damaged-documents-are-refused-not-stepped-over).

Deferred operations such as `flatten/1,2` only mark work to be done on the
next write, so this refusal guarantee does not apply to them.

## Several fields at once

`PdfElixide.Form.put_values/2` takes a map with string keys, or a list of
`{name, value}` pairs, and **validates all of them before it writes any**:
unknown names, duplicates, names that are not strings and values outside
`t:PdfElixide.Form.Field.value/0` are all caught up front.

```elixir
{:ok, editor} = Form.put_values(editor, %{"full_name" => "Jane Doe", "subscribe" => true})

# A list when the order matters — a map is applied in `Enum` order, which is unspecified.
{:ok, editor} = Form.put_values(editor, [{"full_name", "Jane Doe"}, {"country", ["Canada"]}])
```

The editor is held exclusively while the batch is applied, so concurrent calls
see the form before or after it, never partway through it. An unexpected runtime
failure during application may leave earlier writes applied. The
[Concurrency](concurrency.md) guide covers the locking model.

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

This is not an atomic read-modify-write; see the [Concurrency](concurrency.md)
guide.

## Saving

Nothing is written until `PdfElixide.Editor.save/3` writes a file or
`PdfElixide.Editor.to_binary/2` hands back the bytes, and neither consumes the
editor: keep editing and write again. `close/1` **discards unsaved edits**, so
write before you close.

```elixir
{:ok, editor} = Editor.save(editor, "path/to/filled.pdf")
{:ok, bytes} = Editor.to_binary(editor)
```

Both accept `t:PdfElixide.Editor.save_opts/0`: `:incremental`, `:compress`,
`:garbage_collect` and `:encryption`, which writes the filled form
password-protected; see [Encryption](encryption.md). `:encryption` cannot be
combined with `incremental: true`, which raises `ArgumentError`. The exception is `to_binary/2` with
`incremental: true`, which returns
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}`: an incremental update must
be appended to the original file, so use `save/3` for one.

For form filling against an existing PDF, an incremental save appends only the
field-value updates and leaves the original AcroForm structure as it was:

```elixir
{:ok, editor} = Editor.save(editor, "path/to/filled.pdf", incremental: true)
```

Field values and document information are the only changes an incremental update
carries. If the editor holds any other pending change — a flatten mark included —
the save is refused with
`{:error, %PdfElixide.Error{reason: :unsupported}}` naming it, rather than writing a
file without it. See [Saving edits](editing.md#saving-edits).

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

try do
  editor
  |> Form.put_value!("full_name", "Jane Doe")
  |> Form.put_value!("subscribe", true)

  File.write!("path/to/data.xfdf", Form.export!(editor, :xfdf))
after
  Editor.close(editor)
end
```

It reads from either source, like `fields/1`. From an editor it includes values
written but **not yet saved**, so filling and exporting need no write in between;
from a document it reports what the file holds.

```elixir
export_doc = Document.open!("path/to/form.pdf")

try do
  Form.export!(export_doc, :fdf)
after
  Document.close(export_doc)
end
```

What comes out is exactly what `PdfElixide.Form.fields/1` reports for the same
source, under the same fully qualified names — `person.first`, not `first`. That
is also the limit: an exported check box value is not always faithful, per
"Check boxes and radio groups" above.

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

:ok = Document.close(doc)
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

**Neither works on an encrypted source.** Both calls return
`{:error, %PdfElixide.Error{reason: :unsupported}}`. Write the document out
first and flatten the result — see
[What an encrypted source cannot do](encryption.md#what-an-encrypted-source-cannot-do).
Filling is unaffected.

**Nothing happens until the next full write.** Both calls only *mark* what to
flatten; the drawing happens inside `PdfElixide.Editor.save/3` or
`PdfElixide.Editor.to_binary/2`. Until then `Form.fields/1` still reports every
field, because the editor is unchanged — what changes is the file you write.
`PdfElixide.Editor.modified?/1` does go true at mark time.

**An incremental save is refused once a page is marked.**
`save(editor, path, incremental: true)` returns
`{:error, %PdfElixide.Error{reason: :unsupported}}` and writes nothing: an
incremental update appends to the original, whose fields are still there, so it
could only produce an unflattened file. Write with `save/3` without
`:incremental`, or with `to_binary/2`. Because a mark cannot be removed, filling
and flattening in one session means writing a full rewrite.

**A mark cannot be removed, and it applies to every later write.** There is no
unflatten; reopen the source if you need an unflattened document. Writing twice
gives you two flattened files.

**A flatten is drawn above a redaction box on the same page.** A page the write
actually redacts also loses its widgets — along with every other annotation on
it — and a flatten on the same editor paints the field appearances over the box.
A page that was only marked, with no `/Redact` annotation and no queued region,
keeps them. See
[Redaction](redaction.md) for the order and the workflow that avoids it.

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

`Editor.flatten_annotations/1,2` has broader, page-wide removal behavior; its
API documentation describes what happens when an appearance cannot be produced.
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

- **A newly set value containing non-Latin text or emoji that this library
  cannot draw into an appearance.** The field may contain incorrect glyphs or
  none at all while the PDF remains valid. Check the warnings after filling and
  flattening text outside Latin-1. Existing appearance streams are copied
  unchanged and are unaffected.

  Such a warning may mention a build-time option for wider font support. This
  package ships precompiled, so that option is not available here. Take the
  warning to mean the field did not flatten legibly, and handle it in your own
  code — leave the form unflattened, substitute a value the field's font can
  render, or draw the text yourself before flattening.
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
