# CLI: `operation`

Every operation, core's, built-in plugins' and installed plugins', as its code declares it
and as this site overrides it. Administrators only. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `operation list` | Every operation, with who may call it and its limit |
| `operation get --name <name>` | Everything an operation says of itself: its words, how it fails, whether it destroys, who may call it and its limit |
| `operation authorize --name <name> --answer <answer>` | Who may call a plugin's operation on this site |
| `operation limit --name <name> --per_minute <n>` | Calls a minute one untrusted caller may make to it |

Who may call and the limit each come as `declared` (the code's), `override` (this site's)
and `in_effect`.

- `--answer` is `plugin_calls`, `roles:editor,author`, `signed_in` (only where the
  operation takes untrusted callers), or `default` to go back to the code's. An operation
  taking untrusted callers with no answer of its own shows `anyone`. It reaches
  operations a plugin made with `publr.operation.define`; core's keep their grants and
  roles. Where the code checks callers with a function of its own (`declared: custom`),
  that check still runs, so the override can only narrow who may call, and the answer
  carries a `warning` saying so.
- `--per_minute` counts untrusted callers: a site's pages, and anyone calling without
  credentials (per account, else visitor, else address), on top of the general limit of
  600 calls a minute that counts everyone; `0` goes back to the code's `.limit`. Any
  operation, core's too.

```sh
publr operation authorize --name guestbook.sign --answer signed_in
publr operation limit --name guestbook.sign --per_minute 5
```
