# CLI: `apps`

The project's apps as files, for an agent with no file system of its own (a chat app over
MCP, an agent sending commands with `--site`). An agent next to the project edits `apps/`
instead. Either way a running server loads the change on its own. What an app is made of is in [Apps](../apps.md). Back
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

## `edit`

One part of a file changed: `old`, which must be in it exactly once, becomes `new`. Refused,
changing nothing, when `old` is not there or is there more than once. A small change
(a word in a heading, one rule in a stylesheet) without sending the whole file; refused to
a drafts-only device as `write` is.

```
$ publr --site example.com apps edit --path www/content/index.publr --old '<h1>Hi</h1>' --new '<h1>Hello</h1>'
{ "path": "www/content/index.publr", "bytes": 14 }
```

## `remove`

One file deleted. As `write`, refused to a drafts-only device.

## `load`

The apps read again into the running server, live at once; with no server running, only
checked, as `serve` would load them. A running server also loads them on its own, within
half a second of a file changing; this is for the answer. When they do not compile, it
fails with `NotLoaded` and why, and the apps loaded before keep serving.
`publr apps load --apps <dir>` checks another folder while no server runs.
