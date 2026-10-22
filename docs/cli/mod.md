# CLI: `mod`

Mods let plugins change a value wherever its owner makes it, as WordPress's filters do. The
owner applies a value under a name (`ctx.mod("checkout.methods", methods)` in a plugin;
core applies every record's title as `<type>.title`), shown or about to be saved, and every
plugin's `publr.modify("checkout.methods", …)` changes it in turn: compiled-in plugins first,
then installed ones as they were loaded. A modifier's name may hold `*` for one whole part
(`*.title`, `checkout.*`). Nothing is declared ahead: a name nobody modifies comes back as it
went. Modifiers only read: no writes, no outside calls. An installed plugin's modifier is one
of its requests (`modify:checkout.methods`), granted like any other. Back to the
[CLI reference](../cli.md).

| Command | What |
|---|---|
| `mod list` | Every modifier: the plugin, the name it takes, why (its function's `///`) |
| `mod apply --name <n> --values <json>` | Pass a JSON array of values through every modifier of the name; they come back in the same order. What `ctx.mod` calls |

```
$ publr --as-admin mod list
{ "modifiers": [ { "plugin": "products", "name": "variant.title",
  "reason": "Shows each variant with its product's name, as Earl Grey, 50 g" } ] }
$ publr --as-admin mod apply --name greeter.count --values '[2]'
{ "values": "[3]" }
```
