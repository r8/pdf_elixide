# Forms

`PdfElixide.Form.fields/1` reads a PDF's AcroForm fields, from a read-only
`PdfElixide.Document` or from a mutable `PdfElixide.Editor` alike. Writing needs
an editor, since a document cannot be changed.

```elixir
alias PdfElixide.Document
alias PdfElixide.Editor
alias PdfElixide.Form

doc = Document.open!("path/to/form.pdf")

try do
  Form.fields!(doc)
  #=> [%PdfElixide.Form.Field.Text{name: "full_name", kind: :single_line, value: "John Doe", …},
  #    %PdfElixide.Form.Field.Button{name: "subscribe", kind: :check_box, value: true, …},
  #    %PdfElixide.Form.Field.Choice{name: "country", kind: :list_box, value: nil, …}]
after
  Document.close(doc)
end
```

## Fields and their values

A field comes back as one struct per field type, so the type is what you match
on: `PdfElixide.Form.Field.Text` (`/Tx`), `.Button` (`/Btn` — push buttons, check
boxes and radio groups), `.Choice` (`/Ch`), and `.Unknown` for a field with no
recognized type, which includes the grouping parents a nested form reports.
`PdfElixide.Form.Field` is the umbrella defining the union. Which widget a
button or choice field is, the struct's `:kind` says — see below.

**Every struct carries the same three keys.** `:name` is the field's fully
qualified name, dotted for a field nested under a parent — `"person.first"`, not
`"first"` — and is what every other function here addresses it by. `:value` is a
plain term: a string, `true`/`false`, a list of strings, or `nil` for a field
carrying no value. `:flags` is described under "Field kinds and flags" below,
along with the `:kind` the first three also carry.

**A value is written back exactly as it was read.** `t:PdfElixide.Form.Field.value/0`
is both what a field reports and what `PdfElixide.Form.put_value/3` accepts —
anything else raises `ArgumentError` — so a value read from one form goes
straight into another. Button fields are the exception, described below.

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

**A field declaring no `/Ff` is not an unknown** — every bit is clear, and the
defaults above are what the PDF specification says that means. Many real forms
declare no `/Ff` at all.

**A field inherits `/Ff` from its ancestors.** A radio group is commonly a parent
carrying the flags over kids that carry none, and each kid reports the parent's
kind. A kid declaring its own `/Ff` replaces the inherited value outright rather
than merging bit by bit, so a `:push` button under a `:radio` parent stays a push
button.

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

`PdfElixide.Document.Annotation` reports the same classification for a widget
annotation, through its `:field_type`, so the two surfaces agree about a field
that appears on both.

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

The values are the plain terms `fields/1` returns — no wrapper, no tag. Fields
are addressed by name and **only an existing field can be written**: there is no
way to add one, so a name the form does not carry is an error rather than a new
field.

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

**That is a read and then a write, not an atomic read-modify-write** — another
process holding the same editor can write in between.

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
`:linearize` and `:garbage_collect`. The exception is `to_binary/2` with
`incremental: true`, which returns
`{:error, %PdfElixide.Error{reason: :invalid_pdf}}`: an incremental update must
be appended to the original file, so use `save/3` for one.

For form filling against an existing PDF, an incremental save appends only the
field-value updates and leaves the original AcroForm structure as it was:

```elixir
{:ok, editor} = Editor.save(editor, "path/to/filled.pdf", incremental: true)
```

One asymmetry worth knowing: `to_binary/2` clears
`PdfElixide.Editor.modified?/1` even though it writes no file, while an
incremental `save/3` leaves it set.

`to_binary/2` builds the whole output in native memory before copying it into an
Elixir binary, so peak usage includes both copies on top of the editor. For a
very large document, prefer `save/3`, which writes to the file without that
second full-size buffer.

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
This is the one write the library does not protect a signature from, because
removing the form is what you asked for; note that any non-incremental write
invalidates a signature anyway.

Both remove the form field widgets from a page's annotations and leave notes,
links and highlights as they were — with one exception worth knowing if you
hand-build PDFs: an annotation written *inline* in `/Annots` rather than as an
indirect reference is dropped whatever its type, silently.

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
widget whose appearance stream cannot be loaded. Deciding a flatten was faithful
because the list came back empty is the one thing not to do with it.

Three things it does report:

- **A newly set value containing non-Latin text or emoji that the shipped
  appearance path cannot render faithfully.** This is the one to watch. The
  field is written with wrong glyphs or none at all, the PDF is otherwise
  perfectly valid, and this warning is the only sign it happened. It applies to
  values you set in this editing session, which is to say the ordinary
  fill-then-flatten workflow, so check the list whenever you fill a form with
  text outside Latin-1 and then flatten it. A field whose appearance the
  document already carried is copied across untouched and is unaffected.

  The warning text names a build-time option of the underlying Rust library and
  tells you to rebuild with it. That is not something you can act on: this
  package ships a precompiled binary, and the option is deliberately off. Read
  the warning as "this field did not flatten legibly" and handle it in your own
  code — leave the form unflattened, substitute a value the field's font can
  render, or draw the text yourself before flattening.
- **A field with no appearance stream that could not be given one.** The warning
  names the field. If another appearance causes that page to be flattened, the
  field is removed without being drawn; if the page produces no appearances at
  all, nothing on it is drawn or removed.
- **An XFA form left as it was** after a per-page flatten, whose XFA data may
  still reference widgets that are now gone.

## An editor is a handle, not a value

**Rebinding does not fork it.** The editor a mutating call returns is the one
that went in:

```elixir
editor = Editor.open!("path/to/form.pdf")
filled = Form.put_value!(editor, "full_name", "Jane")
# `editor` and `filled` are the same handle — the original is filled too.
:ok = Editor.close(editor)
```

So a pipeline *sequences effects* rather than threading a value: an earlier
binding will not give you the document as it was before the edit. Reopen the
source for that.

## Signature fields

A signature field (`/FT /Sig`) is not a fillable field, and this API does not
have one: `fields/1` omits it, and `field/2`, `value/2` and `put_value/3` all
answer `{:error, %PdfElixide.Error{reason: :not_found}}` for its name, exactly as
they would for a name the form does not carry. `put_values/2` reports it the same
way, from the `fields/1` read it validates against.

`put_value/3` has to refuse it rather than merely fail to find it. A signature's
`/V` is a signature dictionary rather than a value, and writing *any* value over
it — `nil` included — replaces that dictionary, so a filled form would silently
come back unsigned.

Flattening is the exception: `PdfElixide.Form.flatten/1` removes the whole
AcroForm and a signature field goes with it, as "Flattening" above describes.

This holds for a field whose `/FT` is declared on an ancestor rather than on the
field itself, which the PDF specification permits.

Reading the signatures themselves is a separate capability, and
`PdfElixide.Signature` is where it lives: `PdfElixide.Signature.list/1` reports
what each signature in a document claims — signer, time, reason, the byte range
it covers, and the full name of the field it sits in, so several signatures on
one form can be told apart — from a document or an editor,
`PdfElixide.Signature.unsigned_fields/1` names the signature fields still
waiting for a signature, so that call and `list/1` between them account for
every signature field a form has,
`PdfElixide.Signature.verify/2` checks one against the bytes that range covers,
`PdfElixide.Signature.certificate/1` hands back the certificate the signature
names as its signer, as DER for `:public_key` to decode,
`PdfElixide.Signature.pades_level/2` reports which PAdES baseline level a
signature reaches and `PdfElixide.Signature.pades_level/3` adds the archival
level, which `PdfElixide.Signature.document_timestamp?/1` answers on its own,
`PdfElixide.Signature.timestamp/1` opens a signature's RFC 3161 timestamp,
`PdfElixide.Signature.signing_time_utc/1` parses the signer's claimed time, and
`PdfElixide.Signature.verify_timestamp/2` checks the token belongs to that
signature, `PdfElixide.Signature.document_timestamp/1` reaches the archival
timestamp that sits outside the form fields, and
`PdfElixide.Signature.dss/1` reads the certificates, CRLs
and OCSP responses a document carries so its signatures can still be judged once
those expire. What a verdict does and does not prove is in that module's
documentation, as is the fact that nothing in the store is validated.
None of them goes through a form write, so the write refusal above stands
either way.

Producing signatures is not offered, and that is a decision rather than
something not yet reached. A signature this library could produce would not be
attached to a form field, so `PdfElixide.Signature.list/1` would not find it
afterwards — being able to sign a document but not to read back what you signed
is not a contract worth offering. Sign with an external tool instead and open
the result here: every call named above reads a document signed elsewhere.

### Reading signatures is stricter than reading fields

The two disagree on a damaged document, deliberately. `fields/1` steps over a
field it cannot read and returns the ones it reached, so a form whose `/Fields`
names an object the file does not contain still answers `{:ok, []}`.
`PdfElixide.Signature.list/1` refuses that same document as
`%PdfElixide.Error{reason: :invalid_pdf}`: "no signatures" is an answer callers
act on, and a damaged file must not be able to fake it.

The same rule reaches the value a signature field points at. A `/V` that is not
a signature dictionary is refused, including one naming an object the file does
not contain. The single exception is a `/V` of `null`, which is how a cleared
field is spelled — that field is unsigned, so `list/1` skips it and
`PdfElixide.Signature.unsigned_fields/1` names it.

`PdfElixide.Signature.unsigned_fields/1` reads no signature at all, so that
value-level strictness does not reach it: a field pointing at something that is
not a signature dictionary is not a place left to sign, and is simply not
listed. Ask `list/1` about the value itself.

All three refuse, rather than read, a field hierarchy that is cyclic or
nested far deeper than any real form: a cycle as `:invalid_pdf`, a hierarchy
past the depth or size limit as `:unsupported`.

## Check boxes and radio groups

`:kind` tells the two apart, per "Field kinds and flags" above. What follows
applies to both, and to writing rather than reading.

Setting a button field writes `/Yes` for `true` and `/Off` for `false`, and those
are the only two states `put_value/3` can produce. That makes the read-then-write
round trip lossy for some check boxes and radio groups, in two ways.

**A box whose on-state is `/On` rather than `/Yes` becomes unchecked after a
read-then-write round trip.** It reads as `true`, since both names mean
"checked", but writing that `true` back emits `/Yes` — which is not the state
the widget declares. Nothing in the value reveals this; the two spellings are
indistinguishable once read. (`/No` collapses to `false` and writes `/Off` in the
same way, but harmlessly: `/Off` is the off state for every check box.)

**A box whose on-state is a *custom* name — `/Export1`, say — cannot be checked
at all.** `true` writes `/Yes`, which matches no widget state, and no other value
writes a PDF name either. Writing the on-state's name as a string is not a
workaround and makes matters worse: it goes into `/V` *and* is copied into the
widget's `/AS`, where the PDF specification requires a name, so a reader may
render the field wrongly.

Either field needs its dictionaries edited directly, which this library does not
expose. Reading such a field is unaffected — only writing one back is.

## What a form call locks

Reading follows the source: `fields/1` on a `PdfElixide.Document` takes the
handle's lock shared, like every other document read, while `fields/1` on an
editor takes the editor's lock *exclusively* — the same lock a write takes — so
concurrent form work on one editor serializes even when it only reads. `field/2`
and `value/2` are `fields/1` filtered in Elixir, so reading several fields one at
a time costs more than one `fields/1`. Give each process its own editor if you
need them to work at once; see the [Concurrency](concurrency.md) guide.
