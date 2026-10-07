# CLI: `apps`

The project's apps as files, for an agent with no file system of its own (a chat app over
MCP, an agent sending commands with `--site`). An agent next to the project edits `apps/`
and runs `publr apps load` instead. What an app is made of is in [Apps](../apps.md). Back
to the [CLI reference](../cli.md).

Administrators only. With `publr serve` running they act on its apps folder, else on the
project's `apps/`. Paths are `<app>/<path>` inside the apps
folder: plain segments, no `..`, no hidden files.

## `files`

Every file of every app, sorted, with its size.

## `read`

One file, as text, up to 1 MiB.

## `write`

One file, created with its folders or replaced, as text up to 1 MiB. It changes what
visitors see once loaded, so a device that may save drafts only is refused.

```
$ publr --site example.com apps write --path www/content/index.publr --content '<h1>Hi</h1>'
{ "path": "www/content/index.publr", "bytes": 11 }
```

## `remove`

One file deleted. As `write`, refused to a drafts-only device.

## `load`

The apps read again into the running server, live at once; with no server running, only
checked, as `serve` would load them. When they do not load, it fails with `NotLoaded` and
why, and a running server's apps stay unavailable (the admin up) until a load succeeds.
`publr apps load --apps <dir>` checks another folder while no server runs.
