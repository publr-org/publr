# CLI: `project`

The installation itself. `publr init` (short for `publr project init`) sets a
fresh project up: it creates the first admin and marks the project as initialised,
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

Output: `{ "user_id", "roles", "password" }` (`password` only when generated).

```
$ publr init --email ada@example.com --display_name Ada
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
