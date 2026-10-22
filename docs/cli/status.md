# CLI: `status`

Publr ships `draft` (initial), `published` (live) and `archived` (not listed);
a type can have a flow of its own, with its own statuses and transitions, kept in its
definition. Core reads only three properties of a status, `live`, `listed` and
`initial`, never its name. Transitions are the named changes between statuses
that become buttons. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `status list` | Every status and transition, core and plugins together |
