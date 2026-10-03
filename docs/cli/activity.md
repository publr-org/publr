# `activity` and `errors`

Two logs of what happened, kept forever and never changed: `activity` has one entry per
completed write, `errors` one per call refused or failed, reads included. Administrators
read them; nothing writes them but the calls themselves. Inputs are stored with secrets
replaced by `•`.

| Command | What |
|---|---|
| `activity list [--actor <a>] [--operation <op>] [--unit <u>] [--since <ms>] [--until <ms>] [--before <id>] [--limit <n>]` | What was done, newest first |
| `errors list [--actor <a>] [--operation <op>] [--since <ms>] [--until <ms>] [--before <id>] [--limit <n>]` | What was refused or failed, newest first |

An entry names its top-level operation, who called it (a user id, `system`, `anonymous`,
`plugin:<name>`), the app, the input, and for activity what it changed (`record:<id>`,
`plugin:<name>`, `content_type:<handle>`) and the operations it set off inside. An error
entry has the error's name, its message, and the inner operation it came from.

```
$ publr --as-admin plugin disable --names cart,inventory
$ publr --as-admin activity list --operation plugin.disable --limit 1
{ "entries": [ { "id": 41, "operation": "plugin.disable",
  "input": "{\"names\":[\"cart\",\"inventory\"]}",
  "units": [ "plugin:cart", "plugin:inventory" ], "calls": [], … } ] }
$ publr --as-admin plugin enable --names cart,inventory
```

Page back with `--before`, the id of the oldest entry shown.
