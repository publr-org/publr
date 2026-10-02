# CLI: `internal`

Internal records are what a plugin keeps for itself and nobody edits: carts,
reservations, stock movements, logs. One JSON document each, in collections the plugin
declares (`internal_records`), each with the fields it is found by. They are never
content: no statuses, drafts, revisions or search, and they never appear in the admin's
content list. `version` refuses a stale write; an append-only collection refuses `save`
and `delete`.

A plugin's code reaches its own records in the request's app, and nobody else's, without
asking for any permission. From the command line no plugin is running, so an
administrator names the plugin (`--plugin`) and, for an app's records, the app (`--app`;
the project's own when left out). Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `internal create --kind <k> --document <json> [--plugin <p>] [--app <a>]` | Keep a new record; its declared fields are indexed |
| `internal get --kind <k> --id <id> [--plugin <p>] [--app <a>]` | Read one record |
| `internal save --kind <k> --id <id> --document <json> [--expected_version <n>] [--plugin <p>] [--app <a>]` | Write the fields given; the others keep their values |
| `internal find_one --kind <k> --field <f> --value <v> [--plugin <p>] [--app <a>]` | The one record whose indexed field holds the value; null if none, `conflict` if two |
| `internal find --kind <k> [--field <f> --value <v>] [--limit <n>] [--offset <n>] [--plugin <p>] [--app <a>]` | A page of records, newest first, optionally on one indexed field |
| `internal delete --kind <k> --id <id> [--plugin <p>] [--app <a>]` | Remove a record |

```sh
$ publr --as ada@example.com internal find --plugin inventory --kind movement --field stock --value tea-jasmine
```
