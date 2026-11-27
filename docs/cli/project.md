# CLI: `project`

The installation itself. `publr project init` sets a fresh project up: it creates the first admin and marks the project as initialised,
exactly once. Back to the [CLI reference](../cli.md).

## `init`

Set up a fresh installation: creates the first admin account. Works exactly
once: while no admin exists and the project has never been initialised (the fact
is recorded, so deleting users later does not reopen it). Anyone may call it,
and afterwards nobody can, not even `--as-admin`. `publr project init` is the
same command under its namespace.

| Field | Type | Default |
|---|---|---|
| `--email` | text | required |
| `--display_name` | text | required |
| `--password` | text | generated when omitted (or `PUBLR_PASSWORD`) |
| `--language` | text | empty: English |

`--language` is the site's: the admin speaks it to everyone who chose none (one of
`publr user language`'s choices). It is the first admin's own choice too, so they are
never asked; accounts added later choose theirs on their first visit.

Output: `{ "user_id", "roles", "password" }` (`password` only when generated).

```
$ publr project init --email ada@example.com --display_name Ada
{
  "user_id": "3f9c...",
  "roles": ["admin"]
}
```

## `impact`

What a change to a record rebuilds. Reads the dependency index the apps'
builds fill: every rendered page and fragment records the record ids and types
it read, and a change to a record raises `record:<id>`, `type:<handle>` and
`records`. Lists those keys for the record (without `--id`, for a record of the
type that does not exist yet) and every artifact that recorded any of them,
which is exactly what the next quiet moment rebuilds. Signed-in users may call
it; nothing is written. An empty list means no build has recorded the keys yet:
a fresh install, or apps that render live.

| Field | Type | Default |
|---|---|---|
| `--type` | text | required |
| `--id` | text | none |

Output: `{ "keys", "artifacts": [{ "name", "keys" }] }`, each artifact once,
by name (its app and its URL), with the keys it recorded.

```
$ publr project impact --type post --id a1b2c3d4e5f60718293a4b5c
{
  "keys": ["record:a1b2c3d4e5f60718293a4b5c", "type:post", "records"],
  "artifacts": []
}
```

After a build the artifacts are what the index holds:

```
  "artifacts": [
    { "name": "www:/", "keys": ["type:post", "records"] },
    { "name": "www:/_islands/latest-posts", "keys": ["type:post", "records"] },
    { "name": "www:/posts/hello", "keys": ["record:a1b2c3d4e5f60718293a4b5c", "type:post", "records"] }
  ]
```

## `move_app`

Every content type and taxonomy of one app handed to another, after the app's `.name`
changed in its `app.zon`; with no `--to`, they become Global. Types shared with the old
name are shared with the new one, and the app's design records follow. No record changes.
Administrators only.

```
$ publr --as-admin project move_app --from www --to site
{ "moved": 6 }
```

## `clock` and `set_clock`

A test site's clock, to try time-driven work end to end: "it is now 11 January", and a
payment request is overdue, a monthly job runs, a `.due` job's moment passes. Only on a test
site: one on this computer, not hosted, not a copy (`PUBLR_COPY`), served over plain http
while `serve` runs (the same switch that makes `serve` development). Everywhere else the
clock is the wall clock and `set_clock` is refused (`NotATestSite`). Administrators only.

`set_clock` takes one of: `--at_ms` (the site's time from now on, ms since 1970),
`--ahead_ms` (moved on by that many ms), `--reset true` (back to the wall clock). From then
on the site's time runs as the wall clock does. A plugin's `ctx.now()` (built-in and
installed), the moments of queued work and the queue worker read it, so whatever falls due
by then runs within a second or two. Sign-ins and sessions keep the wall clock. `clock`
says the site's time, whether it was moved and whether it may be.

```
$ publr --as-admin project set_clock --at_ms 1799668800000
{ "now_ms": 1799668800000 }
$ publr --as-admin project clock
{ "now_ms": 1799668801250, "moved": true, "test_site": true }
$ publr --as-admin project set_clock --reset true
```

## `random`

`--bytes` (1 to 64, 16 when left out) random bytes from the operating system's
cryptographic source, as lowercase hex: what a plugin's `ctx.random(&buffer)` reads, built
in and installed alike. Anyone; every plugin may call it without asking. Changes nothing.

```
$ publr project random --bytes 4
{ "hex": "9f04c2e1" }
```

## `put`

Anything the project stores put exactly as another copy of the project keeps it, with its
ids: what keeps copies (environments, branches) in sync, so a thing keeps one id in every
copy. Each unit is a `kind`, an `id` and its `rows`: its stored rows as JSON objects by
column, by table, `{}` to remove it. Its own row is updated in place, the rows hanging from
it replaced whole; a unit already as given is not written, so running a call twice changes
nothing. Only plugins call it (with `project.put`), and administrators.

| Kind | Id | Tables |
|---|---|---|
| `record` | its id | `records`, `record_values`, `record_terms` (search text made again) |
| `term` | its id | `terms`, `term_values` (search text made again) |
| `internal` | its id | `internal_records`, `internal_record_values` |
| `content_type`, `taxonomy` | its id | its row, its `field_groups` row |
| `field_group` | its handle | its `field_groups` row (scope `custom_fields`) |
| `role` | its name | `roles`, `role_grants` |
| `user` | its id | `users`, `user_roles`, `user_values`, `user_search`, `identities` |
| `plugin` | its name | its `sandboxed_plugins` row: versions and grants, never its files |

A BLOB travels as hex. Records and terms then land as the same change made by a person:
slugs and unique values free, references live, the replaced live document kept as a
revision, its events raised; a refused check fails the whole call. The answer lists every
unit with its outcome: `added`, `replaced`, `removed` or `unchanged`, and a content
type's or taxonomy's `handle`. Files (plugins' modules, apps, `publr.zon`) are not put.

```
$ publr --as-admin project put --units '[{"kind":"role","id":"reviewer","rows":{}}]'
{ "put": [{ "kind": "role", "id": "reviewer", "outcome": "removed", "handle": "" }] }
```

## `get`

The read half of `put`: each unit of one `kind` named in `--ids` with its stored rows by
table, exactly as `put` takes them, `{}` for one that is not there. Kinds, ids and tables are
`put`'s; search text is never read, since `put` makes it again. With `--every true`, also
the id of every unit of the kind in order, a content type's or taxonomy's `handle` beside
it, 10,000 at a time: `--after` the answer's `next` continues. At most 1,024 ids a call.
Changes nothing. Only plugins call it (with `project.put`), and administrators.

```
$ publr --as-admin project get --kind role --ids '["reviewer"]'
{ "units": [{ "id": "reviewer", "handle": "", "rows": { "roles": [{ "name": "reviewer", … }],
  "role_grants": [] } }], "every": [], "next": "" }
```
