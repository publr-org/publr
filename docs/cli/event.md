# CLI: `event`

The events plugins declare (`publr.event.define`, listed in `.events`), compiled in and
installed, each with its payload: what a plugin hooking one (`publr.remote.event`, then
`publr.on` or `publr.after`) writes its own words against. Administrators only. Back to the
[CLI reference](../cli.md).

| Command | What |
|---|---|
| `event list [--plugin <name>]` | Every declared event: its name, the plugin emitting it, whether it is installed, and its payload's fields (path, kind, whether it may be null or left out, an enumeration's values) |
| `event get --name <event>` | One event as `event list` gives it, and each hook on it: plugin, stage (`after` or `on`), reason, its last failed run |

Every operation also emits an event under its own name, carrying its answer: `operation get
--name <operation>` and `publr <namespace> <verb> --help` describe those.

```sh
publr event list --plugin orders
publr event get --name orders.paid
```
