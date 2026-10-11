# CLI: `update`

Updating this site's Publr to a newer release, and stepping back. Administrators only, on a
running server: the commands reach it through the CLI next to it. What an update does, step
by step, is in [Updates](../updates.md). Where Publr Cloud runs the site, it keeps Publr up
to date, and `apply` and `rollback` answer `Managed`.
Back to the [CLI reference](../cli.md).

## `update status`

The release running, what the last update did, the release kept to go back to, and the
backups taken before updates.

Output: `{ "version", "managed", "step", "target", "message", "previous", "backups" }`.
`step` is `idle`, the step an update is on (`downloading`, `verifying`, `rehearsing`,
`swapping`, `restarting`), then `done` or `failed`.

```
$ publr --as-admin update status
{
  "version": "0.4.0",
  "managed": false,
  "step": "done",
  "target": "0.4.0",
  "message": "Updated to 0.4.0 (from 0.3.2)",
  "previous": "0.3.2",
  "backups": [{ "name": "2026-11-02T100000-0.3.2-to-0.4.0", "from": "0.3.2", "to": "0.4.0", "at_ms": 1793613600000 }]
}
```

## `update check`

The releases newer than this one, newest first, each with its kind against this release
(`patch`, `minor`, `major`) and its notes. Fails `Unreachable` when GitHub cannot be reached.

## `update apply`

| Field | Type | Default |
|---|---|---|
| `--version` | text | required |

Starts the update and answers at once (`{ "started", "kind" }`); `update status` follows it.
The release is downloaded, checked against the checksums Publr signed, rehearsed on a copy
of the database, swapped in, and the server restarts as it. If it cannot open the site, the
release before comes back by itself.

## `update rollback`

Goes back to the release this one replaced (`{ "started", "to" }`): the kept binary is
swapped back and the server restarts. The data stays, unless this release's migration was
one-way (a major's): then the backup taken before the update is put back.

## Not operations

These open the database without the gate, so they work on one it refuses:

| Command | What it does |
|---|---|
| `publr db check` | What this release would find opening the database; exit 1 when it would refuse it |
| `publr db tables` | Every table, its rows, and whether it is core's |
| `publr db draft <schema.sql>` | The next migration, drafted from what this build's schema adds to that one |
| `publr backups` | The backups taken before each update, newest first |
| `publr restore <name>` | Put the site back as a backup holds it; stop `serve` first |
