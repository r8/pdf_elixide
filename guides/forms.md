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
#=> [%PdfElixide.Form.Field.Text{name: "full_name", value: "John Doe"},
#    %PdfElixide.Form.Field.Button{name: "subscribe", value: true},
#    %PdfElixide.Form.Field.Choice{name: "country", value: nil}]
```

## Fields and their values

A field comes back as one struct per field type, so the type is what you match
on: `PdfElixide.Form.Field.Text` (`/Tx`), `.Button` (`/Btn` — push buttons, check
boxes and radio groups), `.Choice` (`/Ch`), and `.Unknown` for a field with no
recognized type, which includes the grouping parents a nested form reports.
`PdfElixide.Form.Field` is the umbrella defining the union.

**Every struct carries the same two keys.** `:name` is the field's fully
qualified name, dotted for a field nested under a parent — `"person.first"`, not
`"first"` — and is what every other function here addresses it by. `:value` is a
plain term: a string, `true`/`false`, a list of strings, or `nil` for a field
carrying no value.

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
#=> {:ok, %PdfElixide.Form.Field.Choice{name: "country", value: nil}}
```

**`{:ok, nil}` and `:not_found` are different answers.** A field that exists but
carries no value is `{:ok, nil}`; a name the form does not carry is
`{:error, %PdfElixide.Error{reason: :not_found}}`, from `field/2` and `value/2`
as much as from `put_value/3`. The bang variants raise it instead.

## Filling a form

Open the file as an editor, write values, then persist. Every call that changes
an editor returns it, so the whole thing is one pipeline:

```elixir
"path/to/form.pdf"
|> Editor.open!()
|> Form.put_value!("full_name", "Jane Doe")
|> Form.put_value!("subscribe", true)
|> Editor.save!("path/to/filled.pdf")
|> Editor.close()
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
values = %{"full_name" => "Jane Doe", "subscribe" => true}

with {:ok, editor} <- Editor.open("path/to/form.pdf"),
     {:ok, editor} <- Form.put_values(editor, values),
     {:ok, editor} <- Editor.save(editor, "path/to/filled.pdf") do
  Editor.close(editor)
end
#=> :ok
```

`PdfElixide.Editor.to_binary/2` and `PdfElixide.Editor.close/1` are the two ways
such a pipeline ends: one hands back bytes, the other `:ok`. Everything before
them hands back the editor.

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

Both take the same options (`t:PdfElixide.Editor.save_opts/0`): `:incremental`,
`:compress`, `:linearize` and `:garbage_collect`. For form filling against an
existing PDF, an incremental save appends only the field-value updates and
leaves the original AcroForm structure as it was:

```elixir
{:ok, editor} = Editor.save(editor, "path/to/filled.pdf", incremental: true)
```

One asymmetry worth knowing: `to_binary/2` clears
`PdfElixide.Editor.modified?/1` even though it writes no file, while an
incremental `save/3` leaves it set.

## An editor is a handle, not a value

**Rebinding does not fork it.** The editor a mutating call returns is the one
that went in:

```elixir
editor = Editor.open!("path/to/form.pdf")
filled = Form.put_value!(editor, "full_name", "Jane")
# `editor` and `filled` are the same handle — the original is filled too.
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

This holds for a field whose `/FT` is declared on an ancestor rather than on the
field itself, which the PDF specification permits. Reading, verifying and
producing signatures is a separate capability, and not one this library offers.

## Check boxes and radio groups

Setting a button field writes `/Yes` for `true` and `/Off` for `false`, and those
are the only two states `put_value/3` can produce. That makes the read-then-write
round trip lossy for some check boxes and radio groups, in two ways.

**A box whose on-state is `/On` rather than `/Yes` comes back unchecked.** It
reads as `true`, since both names mean "checked", but writing that `true` back
emits `/Yes` — which is not the state the widget declares. Nothing in the value
reveals this; the two spellings are indistinguishable once read. (`/No` collapses
to `false` and writes `/Off` in the same way, but harmlessly: `/Off` is the off
state for every check box.)

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
