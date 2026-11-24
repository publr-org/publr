# CLI: `internal`

Internal records are what a plugin keeps for itself and nobody edits: carts,
reservations, stock movements, logs. One JSON document each, in collections the plugin
declares (records with `.internal = true` in `.records`), each with the fields it is found by. They are never
content: no statuses, drafts, revisions or search, and they never appear in the admin's
content list. `version` refuses a stale write; an append-only collection refuses `save`
and `delete`. Every write runs the collection's field rules as content's: a value breaking
one is refused beside its field, and a unique value another record holds is a conflict.
A computed field ([Computed fields](../plugins.md#computed-fields)) is worked out by its
plugin: a read answers it fresh, and a value a write sends for it is ignored.

A plugin's code reaches its own records in the request's app, and nobody else's, without
asking for any permission. From the command line no plugin is running, so an
administrator names the plugin (`--plugin`) and, for an app's records, the app (`--app`;
the project's own when left out). Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `internal create --kind <k> --document <json> [--plugin <p>] [--app <a>]` | Keep a new record; its declared fields are indexed |
| `internal create_many --kind <k> --documents <json array> [--plugin <p>] [--app <a>]` | Keep up to 200 new records at once, all or none; their ids in order |
| `internal get --kind <k> --id <id> [--plugin <p>] [--app <a>]` | Read one record |
| `internal save --kind <k> --id <id> --document <json> [--expected_version <n>] [--plugin <p>] [--app <a>]` | Write the fields given; the others keep their values |
| `internal save_many --kind <k> --records '[{"id":..,"document":{..}}]' [--plugin <p>] [--app <a>]` | Write the fields given on up to 200 records at once, all or none |
| `internal find_one --kind <k> --field <f> --value <v> [--plugin <p>] [--app <a>]` | The one record whose indexed field holds the value; null if none, `conflict` if two |
| `internal find --kind <k> [--field <f> --value <v>] [--limit <n>] [--offset <n>] [--oldest true] [--after <id>] [--fields '["a","b"]'] [--ids '["…"]'] [--plugin <p>] [--app <a>]` | A page of records (50, at most 200), newest first or oldest first, optionally on one indexed field, each with only the fields named; with `--after`, a walk's page: the records after that id in the order they were made (`""` for the first), found from the index; with `--ids` (up to 200), those records instead of a page, in the order named |
| `internal count --kind <k> [--field <f> --value <v>] [--plugin <p>] [--app <a>]` | How many records there are, optionally on one indexed field; none is read |
| `internal sum --kind <k> --path <field.field> [--field <f> --value <v>] [--plugin <p>] [--app <a>]` | A whole number of every record added up, optionally on one indexed field; computed values are worked out first where stale; none is handed over |
| `internal holds_until --until_ms <ms>` | Inside a computed field's work: its answer holds until then; does nothing elsewhere |
| `internal delete --kind <k> --id <id> [--plugin <p>] [--app <a>]` | Remove a record |

```sh
$ publr --as ada@example.com internal find --plugin inventory --kind movement --field stock --value tea-jasmine
$ publr --as ada@example.com internal create --plugin inventory --kind movement --document '{"stock":"tea-jasmine","change":-2}'
```

`--document` takes the record as JSON text. A REST body sends the object itself:

```
POST /api/internal.create   {"plugin":"inventory","kind":"movement","document":{"stock":"tea-jasmine","change":-2}}
POST /api/internal.save     {"plugin":"inventory","kind":"movement","id":"…","document":{"change":-3}}
```
