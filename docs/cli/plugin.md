# CLI: `plugin`

Every plugin is either **built-in** (compiled into the binary: always enabled, full access,
changed only by a new build) or **installed** (a `.wasm` file loaded at runtime into the
sandbox, where it can do only what an administrator granted it). `plugin list` shows both;
every other command manages installed ones. See
[Plugins](../plugins.md#installed-plugins-dlp) for how one is written and built. Every
command here is for administrators. Back to the [CLI reference](../cli.md).

An installed plugin is **added** first: listed, running nothing. **Enabling** it creates its
content types and grants what it asks for at the low and medium tiers; high-tier requests
wait. A module added for a plugin already there becomes its **next version**; **update**
applies it and keeps the version it replaces, which **rollback** goes back to. The admin
does the same from Settings > Plugins, where Upload plugin adds a module and opens the screen
to enable it, or to update it.

| Command | What |
|---|---|
| `plugin list` | Every plugin, built-in and installed (`mode` native or sandboxed): version, enabled or not, what waits for approval, an update waiting |
| `plugin get --name <n>` | Every request with its tier and state, the content access, the versions |
| `plugin add --file <path>` | Add a module from this machine (`--as-admin` only); a new plugin, or the next version of one |
| `plugin upload --file <name> --data <base64> [--offset <n>] [--last false]` | Add a module sent a piece at a time: what the admin's Upload plugin button sends |
| `plugin enable --name <n> [--content_access public\|all\|specific] [--types <t,...>]` | Start it: its content types created, low and medium granted, high pending |
| `plugin disable --name <n>` | Stop it; its grants, content types and records stay |
| `plugin update --name <n>` | Apply the next version, granting what it asks for; the current one is kept |
| `plugin rollback --name <n>` | Go back to the version the last update replaced |
| `plugin cancel_update --name <n>` | Drop the next version |
| `plugin grant --name <n> --key <k>` | Grant one request: a permission, a hook, a raised limit |
| `plugin revoke --name <n> --key <k>` | Take one back; the plugin's next call answers denied |
| `plugin deny --name <n> --key <k>` | Refuse one; enabling again does not grant it |
| `plugin set_content_access --name <n> --scope <s> [--types <t,...>]` | Which content types its content permissions reach |
| `plugin remove --name <n>` | Take it off the list; its content types and records stay |

A request's key is the permission's (`content.write`), a hook's (`after:record.save`,
`before:record.save`, `event:record.published`) or a raised limit's (`limit.cpu_ms`). A key
nothing installed provides (`newsletter.send` without a newsletter plugin) is unavailable:
the plugin runs without it.

```
$ publr --as-admin plugin add --file ./zig-out/sandboxed-plugins/greeter.wasm
{ "name": "greeter", "version": "0.1.0", "update": false }
$ publr --as-admin plugin enable --name greeter
{ "name": "greeter", "active": true, "requests": [ { "key": "users.names", "state": "granted", … } ], … }
$ publr --as-admin greeter greet --note hello
{ "total": 1 }
$ publr --as-admin plugin add --file ./greeter-0.2.0.wasm
{ "name": "greeter", "version": "0.2.0", "update": true }
$ publr --as-admin plugin update --name greeter
{ "version": "0.2.0", "previous": "0.1.0", … }
$ publr --as-admin plugin rollback --name greeter
{ "version": "0.1.0", "previous": "0.2.0", … }
```
