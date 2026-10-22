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
| `plugin list [--limit <n>] [--offset <n>]` | The plugins, built-in then installed by name (`mode` native or sandboxed), 50 a page (`--limit` up to 200): version, enabled or not, what waits for approval, an update waiting; `total` counts them all |
| `plugin get --name <n>` | A built-in plugin too (`mode` native: every request granted, nothing to update). Every request with its tier, its state, the types it names and each flag it asked for as set now; the versions; why it can't be enabled (`blocked`) and which remotes are off (`off`), in words; an update's `stops` and `switches_off` |
| `plugin add --file <path>` | Add a module from this machine (`--as-admin` only); a new plugin, or the next version of one |
| `plugin upload --file <name> --data <base64> [--offset <n>] [--last false]` | Add a module sent a piece at a time: what the admin's Upload plugin button sends |
| `plugin enable --names <a,b> [--grants <json>]` | Start one or several: their content types created, low and medium granted, high pending; for one plugin, `--grants` sets what its review left (`[{ "key", "on", "publish": false }]`: a key on is granted whatever its tier, off denied, each flag it asked for on or off). Refused while one depends on a plugin that is not running and not among them, naming the command that starts them together |
| `plugin disable --names <a,b>` | Stop one or several; their grants, content types and records stay. Refused while an enabled plugin depends on one, naming it and the command that stops them together |
| `plugin update --name <n>` | Apply the next version, granting what it asks for; the current one is kept |
| `plugin rollback --name <n>` | Go back to the version the last update replaced |
| `plugin cancel_update --name <n>` | Drop the next version |
| `plugin grant --name <n> --key <k>` | Grant one request: a permission, a hook, a raised limit, an added status |
| `plugin revoke --name <n> --key <k>` | Take one back; the plugin's next call answers denied |
| `plugin deny --name <n> --key <k>` | Refuse one; enabling again does not grant it |
| `plugin set_grant --name <n> --key <k> [--on true\|false] [--drafts\|--private\|--internal\|--publish true\|false] [--domains <list>]` | Switch a permission or one of the flags it asked for on or off, never past what it asked for; `--domains` replaces the domains `http.fetch` may reach |
| `plugin remove --name <n>` | Take it off the list, into the trash; its data stays, except the pieces chosen to go with it, which go into the same entry after its `uninstall` write runs. Refused, like disable, while an enabled plugin depends on it |
| `plugin data --name <n>` | What it manages, built-in or installed: its content types (with their records), internal record collections and custom field groups, each with a key and whether it goes with the plugin |
| `plugin choose_removal --name <n> --remove <keys>` | Which pieces go with it when it is removed (`type:<handle>`, `internal:<collection>`, `fields:<group>`, `role:<name>`); none, keeping everything, until someone chooses |
| `plugin build --name <n> --files <json>` | For an agent with no file system: each `{ "path", "content" }` written to `plugins/<n>/`, then the build started on its own beside the running server, which installs it when built (added and enabled, or updated). Needs `serve` and a binary carrying the compiler; refused to a drafts-only device. Without `--files`, `publr plugin build` builds the sources already there, here |
| `plugin scaffold --name <n> [--page list\|form]` | The files of a new plugin with a page of its own in the admin, `{ path, content }`, ready for `plugin build --files`; writes nothing |
| `plugin check --dir <folder>` | The plugin checks over a plugin's source, here, before or without a build: money, times and references kept as plain numbers or text, JSON in text, an untrusted write taking facts the server owns, an import outside the folder. Each problem with its file and line; exits 1 when there is any. A `Why:` line in the field's `///` passes a name check. `plugin build` runs the same checks first for a plugin on `define` |
| `plugin build_log --name <n>` | What that build printed so far: the compiler's messages, then what installing answered |

A request's key is the permission's (`records.write`), a hook's (`after:record.save`,
`before:record.save`, `event:post.transitioned`), a raised limit's (`limit.cpu_ms`) or a status
the plugin adds to another's flow (`status:inventory.awaiting_stock`; its records leave by the
plugin's own transition out of it before it is revoked or denied). A key
nothing installed provides (`newsletter.send` without a newsletter plugin) is unavailable:
the plugin runs without it.

```
$ publr --as-admin plugin add --file ./zig-out/sandboxed-plugins/greeter.wasm
{ "name": "greeter", "version": "0.1.0", "update": false }
$ publr --as-admin plugin enable --names greeter
{ "plugins": [ { "name": "greeter", "enabled": true, "requests": [ { "key": "users.names", "state": "granted", … } ], … } ] }
$ publr --as-admin greeter greet --note hello
{ "total": 1 }
$ publr --as-admin plugin add --file ./greeter-0.2.0.wasm
{ "name": "greeter", "version": "0.2.0", "update": true }
$ publr --as-admin plugin update --name greeter
{ "version": "0.2.0", "previous": "0.1.0", … }
$ publr --as-admin plugin rollback --name greeter
{ "version": "0.1.0", "previous": "0.2.0", … }
```
