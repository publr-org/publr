# Content

How Publr models what it stores. The operations are documented in the CLI
reference ([content_type](adapters/cli/content_type.md), [record](adapters/cli/record.md),
[taxonomy](adapters/cli/taxonomy.md), [term](adapters/cli/term.md),
[status](adapters/cli/status.md)); the tables in [Database schema](schema.md).

A content type is data: a name and a list of fields, stored in the database,
editable at runtime. It has a kind: a **record type** holds any number of
records (posts, hotels, players); a **settings type** holds exactly one (the
homepage, the header, general options), created the first time it is opened; a
**component** holds none, its fields are a set for other types to reuse. (The
`settings` table is something else: the project's own key/value settings.) A
record type with a `url` (`posts`) is public, must have a slug field, and its records
live at `/<url>/<slug>` in the apps that route them; a type without one is internal, read by
signed-in users only. A
type may have no fields yet: it is built up one field at a time. Any field but
a slug or a group may hold a list of values (`many`), a repeater a list of
field sets. Records take their title from the type's `title_field` when a
field of that name exists (a string, slug or email field, or a plugin kind that
allows titles); without one they are listed by id.

Field kinds are a registry, not a closed list: each kind is a descriptor (its
label and icon, the storage class its values take, which validation and
option controls it has, whether a field of it may be unique, title records or start records
with a default, its own check over a value, which kinds it converts from).
The core brings sixteen; a plugin adds its own (`pub const
field_kinds`, named `<plugin>.<kind>`), and the validator, the store, the
type editor and the record form read the descriptor. A value of any kind is
stored as one of five classes (`text`, `int`, `real`, `ref`, `long`), so the
tables never learn about a kind.

A **money** field holds an amount per currency, each in minor units of an ISO 4217
currency: `{ "GBP": 850, "EUR": 990 }` is £8.50 and €9.90. Each amount is its own integer
value at `price.GBP`, so lists filter and sort by `price.GBP` like any field. The site's
currencies (`project set_currencies`, the default first) are the only ones a money field
takes; until they are set, any ISO 4217 code is taken. They are set in the admin under
Settings, System settings, Currencies, or with `project set_currencies`. The site says how
each is written:
a symbol, a format such as `{symbol}{amount}` or `{amount} {code}`, the decimal separator
(`.` or `,`) and the thousands one (`,`, `.`, `'`, a space or none). The number of decimals is the currency's own (JPY none, KWD three).
The admin shows one input per currency, and templates write an amount with
`money(product.data.price)`.

A record is one record of one type in one status. Its document is a JSON
object shaped by the type's fields. It is validated on every write and stored
as rows, one row per field value (`records` + `record_values`). So every
field can be filtered and sorted (a `many` field is a list of values of its
kind, one row each), references and media are pointers to the
records they name, and Publr always knows where something is referenced. Reads
put the document back together from its rows. A field may be `unique`: no two
records of the type hold the same value, checked on every write like a slug. A
reference field says what purging the record it points at does to the pointer:
kept, refused, or cleared.

A **virtual** field is shown and read as if the record stored it, but works it out from
other records. The one kind so far, `referenced_by`, is the records of a type whose
reference field points here: a product's `variants` is every variant whose `product` is
the product.

```zig
.{ .name = "variants", .label = "Variants", .kind = "virtual", .many = true,
   .options = .{ .virtual = "referenced_by", .to = &.{"variant"}, .via = "product" } }
```

The variant's reference is the only truth: a variant made anywhere joins its product, and
one whose reference is cleared leaves it. What the field keeps is the order, the variants'
ids, saved like a multiple reference. Reads (`record get`, `record list` with documents,
queries, templates) give the full records in that order, the ones not yet ordered after in
the order they were made; only those the reader may read, one level deep.

The editor shows it as a multiple reference: a card per record, reordered, removed,
linked or created in the drawer. Saving the list writes the difference into the records
it names, each as the caller would save it: one left out has its reference cleared (or
this record taken out of a multiple one), one added points here. A record a single
reference holds elsewhere moves here after a confirmation. The reference changes in the
record's own status: a published variant moves at once, a draft stays a draft. A record
whose reference is required and single cannot be left without one: removing it from the
list deletes it (moves it to `deleted`, restorable), after a confirmation.

Everything that has fields is a record of some type, in the same two tables:
records, authors, later media items. A type may be private
(`public: false`): only signed-in callers see it. A plugin declares the types
it needs in code (`pub const content_types`) and they are created when the
database opens; it may also keep state in fields on its own types. Plugins
extend storage by adding types and fields, never tables.

Publr records who created a record and who last changed it. Who gets credited
is content: a reference field to an `author` record, chosen by editors; only
users who have an author record can be picked.

Media will be a record type too. A media field points at a media record;
caption, alt and credit are its fields. The rules a media field carries (file
size, file family, image dimensions) wait on that library to be checked.

Two axes describe where a record is. **Status** is publication: a registry,
`draft`, `published`, `archived`, `deleted` in the core, moved by transitions
(a plugin can add `scheduled` or `in_review`); every move is reversible,
`record purge` removes for good. **Changed** is editing: saving a live record
parks the document as a pending copy (`slot = pending` in the same value
rows) and marks the record `changed`; the live document stays until
`record publish` applies the copy or `record discard_changes` drops it.
Unpublish, archive and delete keep pending edits as they are, so nothing is
ever lost by moving status. Readers get both fields; "published with changes"
is `status = published, changed = true`, and a rule of thumb for plugins: if
it is about whether or when the record is live, it is a status; if it is a
grouping or an editing state, it is derived from records (release membership
via references, pending edits via `changed`).

## Taxonomies

Classification is its own domain, apart from the content. A **taxonomy** is
the schema of its **terms**, as a content type is the schema of its records:
a handle, a name, whether it is public, and the fields a term carries (a name
and a slug to start with, and anything else: a colour, a cover image, a
description). Terms are documents with the lifecycle of records (statuses,
pending edits, revisions, versions), on their own tables (`taxonomies`,
`terms`, `term_values`), served by the same store and operation machinery:
`term create/get/save/list/publish/...` mirror `record ...`, and the admin
edits a term in the record editor. What a term has that a record has not is a
**parent**: in a `hierarchical` taxonomy terms form a tree (categories, up to
16 levels); a flat one is a list (tags).

A taxonomy says which content types it classifies: `applies_to` lists their
handles, `single` makes records take one term instead of several. Every type
it applies to gains an implicit, locked field of kind `terms` named after the
taxonomy; the type's own definition never stores it, it is added whenever the
definition is read and dropped whenever one is written. The record's document
holds the selected term ids under that field, as a reference holds record
ids. Detaching a type drops those values and memberships. A `terms` field can
also be authored on a type by hand (`"options":{"taxonomy":"topics"}`), at
any depth, inside a group or a repeater: that is a form control like any
other, for composing terms with other fields, not the way a taxonomy is
attached. Filing a record under a term files it under every
ancestor as well: selecting `C` in `A > B > C` makes the record a member of
`A`, `B` and `C`, and filtering the type's records by `A` finds it. The
membership index (`record_terms`) keeps the selected terms and the ancestors
apart, follows the document's slot (pending edits, publish), and is rebuilt
for the records concerned when a term moves under another parent. A term
with children, or with records filed under it, cannot be purged.

In the admin the taxonomy's settings page ticks the types it applies to (the
types the apps give pages first, every record type behind a switch).
The terms of a record sit in the editor's sidebar, one section per taxonomy
that applies: a tree of checkboxes for a hierarchical taxonomy (ticking a
term ticks its ancestors, unticking one unticks what was filed below it), a
combobox for a flat one, a dropdown when the taxonomy takes one term. A
hand-authored `terms` field is drawn in the form itself, as checkboxes or a
dropdown.

Whenever a live document is replaced, the old one is kept as a **snapshot**
of kind `revision`: a frozen, read-only copy in its own table, never queried
by field, never edited, restored by a normal save. Plugins take snapshots of
their own kinds (`snapshot take`), prune them, and build releases, schedules
and environments on the same pieces: slots for parked copies, snapshots for
history, system types for their own records. They never add columns to the
core.
