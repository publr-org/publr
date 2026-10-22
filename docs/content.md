# Content

How Publr models what it stores. The operations are documented in the CLI
reference ([content_type](adapters/cli/content_type.md), [record](adapters/cli/record.md),
[taxonomy](adapters/cli/taxonomy.md), [term](adapters/cli/term.md),
[status](adapters/cli/status.md)); the tables in [Database schema](schema.md).

A content type is data: a name and a list of fields, stored in the database,
editable at runtime. It has a kind: a **record type** holds any number of
records (posts, hotels, players); a **settings type** holds exactly one (the
homepage, the header, general options), created the first time it is opened; a
**component** holds none, its fields are a set for other types to reuse; a **media
type** holds files (below). (The
`settings` table is something else: the project's own key/value settings.) A
record type with a `url` (`posts`) must have a slug field, and its records live at
`/<url>/<slug>` in the apps that route them. A type is Public (any visitor reads its live
records) or Private (only people signed in, as their roles allow); either may have a URL,
a Private type's pages being gated. A type lives in one app or is Global, and is shared
with other apps or not: an app reaches the types living in it and the ones shared with it
([Apps](apps.md#where-a-type-lives)). A
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

A **text** field holds plain text or, with `options.text.format` `markdown`, Markdown: the
admin edits it with a preview, and a template prints it as HTML with `set:markdown`.

A **rich text** field holds HTML and says which formatting its editor offers
(`options.richtext.formats`: any of `bold`, `italic`, `link`; all three when unset, none for
plain paragraphs). The block editor keeps its own annotations in the value (`data-pb-*`
attributes, a block's settings in a `<script>`); a page that prints the value with
`set:html` gets it through the sanitizer, which drops them, so pages see plain markup.

A type is edited in a **form** (`editor` `form`, the default: one control per field) or
**visually** (`editor` `visual`): the block editor over one rich text field, the one
`editor_config` names (`{"field": "body"}`) or else the type's first. A visual type without
a single rich text field is refused. The block editor is being rebuilt (`../editor`); until
it lands, a visual type's records open in the form and rich text in a plain box.

A record is one record of one type in one status. Its document is a JSON
object shaped by the type's fields. It is validated on every write and stored
as rows, one row per field value (`records` + `record_values`). So every
field can be filtered and sorted (a `many` field is a list of values of its
kind, one row each), references and media are pointers to the
records they name, and Publr always knows where something is referenced. Reads
put the document back together from its rows. A field may be `unique`: no two
records of the type hold the same value, checked on every write like a slug. A
reference field says what purging the record it points at does to the pointer:
kept, refused, or cleared. Whether lists can filter and sort by a field is the field's
own: `filterable` (on unless turned off) and `sortable` (numbers, money, dates and times
by default, text and choices when asked), set in the field's settings or by its plugin. A
list's views only choose among them.

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
the order they were made; only those the reader may read, one level deep, and the first 50
of them. A record with more lists the rest with a query of their type (`*[_type ==
"variant" && product == $id]`), a page at a time.

The editor shows it as a multiple reference: a card per record, reordered, removed,
linked or created in the drawer. Saving the list writes the difference into the records
it names, each as the caller would save it: one left out has its reference cleared (or
this record taken out of a multiple one), one added points here. A record a single
reference holds elsewhere moves here after a confirmation. The reference changes in the
record's own status: a published variant moves at once, a draft stays a draft. A record
whose reference is required and single cannot be left without one: removing it from the
list moves it to the trash (restorable), after a confirmation.

Everything that has fields is a record of some type, in the same two tables:
records, authors, later media items. A type may be private
(`public: false`): only signed-in callers see it. A plugin declares the types
it needs in code (`.records`, each made with `publr.record.define`) and they are created when the
database opens; it may also keep state in fields on its own types. Plugins
extend storage by adding types and fields, never tables.

Publr records who created a record and who last changed it. Who gets credited
is content: a reference field to an `author` record, chosen by editors; only
users who have an author record can be picked.

Files are records too, of a **media type**: a content type of kind `media`, declared
only by core or a plugin, with a `title` field and, optionally, the file families it
takes (`families`: `image`, `pdf`...). Every file is a published record of one, with the
file's own facts (name, type, size, dimensions, key, hash) beside it in the `media` table,
written only on upload. The library is the core `media` type (title, alt text, caption,
credit, focal point), filed in at most one `media_folders` term and under any
`media_tags` terms. Others keep files apart from it: core's `ai_picture` holds the
pictures pasted into a conversation with the agent. Media types are kept out of Content,
its lists and the type list, and one type's files never show among another's: each shows
only where its owner draws it (the library on the Media page, chat pictures in their
conversation). A file of a Private media type other than the library is private: only
signed-in callers who may read the type open it (`media read`). A media field points at
a record of the library. The editor's file chooser and picker offer only the
families a field takes; the other rules a media field carries (file size, image
dimensions) are not checked on save yet. See
[CLI: media](cli/media.md).

An app's design is records too, of three core types kept out of Content's lists the same
way (the Design area is their admin, see [Apps](apps.md#templates-parts-and-patterns)):
`template` (`route`, the route's file such as `content/posts/[slug].publr`, its title;
`html`, what the block editor reopens; `output`, what the route's pages print),
`template_part` (`name`, `label`, `html`, `output`) and `pattern` (`name`, `label`,
`category`, `description`, `html`). Each record belongs to the app it overrides, and an
override counts only while it is published. An app's moodboard is the same: each card a
`moodboard_item` record of the app (`kind`, its place `x`, `y`, `w`, `h` as numbers, and
what its kind shows: `note`, `text`, `url`, `src`, `value`, `title`, `alt`, `family`,
`file`, `thumbnail`, `status`, `error`; a font's `weight` and `weight_max` as numbers and
`italic` as a yes or no; and `colors` and `fonts` as lists of text), read
and saved whole through [`design`](cli/design.md).

Two axes describe where a record is. **Status** is publication: a registry,
`draft`, `published`, `archived`, `trashed` in the core, moved by named transitions
(`publish`, `archive`; a plugin's own like `submit`; `trash`, `restore` and `destroy`
in every flow); `restore` takes a record back to the status it had (a published one to
where records start), `destroy` (or `record purge`) removes for good. **Changed** is editing: saving a live record
parks the document as a pending copy (`slot = pending` in the same value
rows) and marks the record `changed`; the live document stays until
`record publish` applies the copy or `record discard_changes` drops it.
Unpublish, archive and delete keep pending edits as they are, so nothing is
ever lost by moving status. Readers get both fields; "published with changes"
is `status = published, changed = true`, and a rule of thumb for plugins: if
it is about whether or when the record is live, it is a status; if it is a
grouping or an editing state, it is derived from records (release membership
via references, pending edits via `changed`).

## Languages and other variants

A field may hold a value per **variant** beside its own (`variants: true`): the value in a
variant is stored under the field's name with the variant's code appended, `name@pl` beside
`name`, in the same rows as any value; the plain name holds the main value. A nested field
carries the code on its own segment (`faq.question@pl`), a group or repeater marked as a
whole on its own (`sections@pl`, its items then a structure of their own). A record is
one record in every variant: a field not marked holds one value for all of them.

What a variant is belongs to the plugin that declares the dimension; the languages plugin
makes each language a variant, and labels the field setting Translate. The core stores,
validates (a variant's value by the field's own rules, never required), reads and picks
them:

- Read whole (the admin, the API, `record get`), a document carries every variant beside
  its field.
- Read in a variant (`record get --variant pl`, `record list --variant pl`, and every page
  drawn under a language's address), each field gives the variant's value, else the code
  without its region's (`en-gb` reads `en`), else the main value; the listed title and
  slug follow. `--slug` with `--variant` matches the variant's slug first.
- A type's `variant_fallback` (default true) says what a record with nothing written in a
  variant does there: shows in its main values, or is left out (not listed; not found).
- Changing a type keeps every variant's value; turning a field's variants off drops them,
  asked first as removing a field with content is (`--drop_content`).

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
