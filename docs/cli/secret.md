# CLI: `secret`

Secrets plugins name but never hold: API keys and the like. A plugin declares the ones it
uses in `.secrets` (not a permission) and writes `{secret:NAME}` where the value goes in a
request it sends with `http.fetch`; the value is filled in as the request leaves. Names are
site-wide: plugins declaring the same one share its value. A
value comes from the environment variable of the same name when one is set, else from what
an administrator set here, sealed with the project's key: `PUBLR_SECRET_KEY` (64 hex
digits), else `secret.key` beside the database (mode 0600, made when the first secret is
set). Back the key up with the database: without it, what was set cannot be read again. A
value is never answered back. Administrators only; no plugin reaches these. Back to the
[CLI reference](../cli.md).

| Command | What |
|---|---|
| `secret list [--limit <n>] [--offset <n>]` | The secrets set (by name), then those declared and not set, 50 a page (`--limit` up to 200): where each value comes from (`environment`, `kept`, `missing`) and the plugins that declare it, installed and built in; `key` says where the key is, `total` counts them all |
| `secret set --name <NAME> --value <value>` | Set a value, replacing any; up to 8 KiB. Masked in the activity log |
| `secret remove --name <NAME>` | Forget a value into the trash (`trash restore` puts it back in use); an environment variable of the same name is left as it is |

```
$ publr --as ada@example.com secret set --name STOCKS_API_KEY --value sk-...
{ "name": "STOCKS_API_KEY", "source": "kept", "used_by": ["stocks"], ... }
```
