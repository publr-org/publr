# CLI reference

Every operation is a command. Nothing is hand-written per command: the CLI
derives commands, flags and output from the operation table.

## Invocation

```
publr [--db <path>] [global flags] <namespace> <verb> [--field value ...]
publr [--db <path>] [global flags] <namespace>.<verb> [--field value ...]
publr --version
```

Output is the operation's result as JSON on stdout. Exit code `0` on success,
`1` on failure (the error name is printed on stderr), `2` when no command is
given.

The database is `data/publr.db` by default and is created on first use.

## Serving

```
publr [--db <path>] serve [--port <n>] [--static [--full]] [--dev] [--out <dir>] [--url <base>]
```

Starts the HTTP server on `127.0.0.1` and runs until the process is stopped.
Without `--port` it starts at `8080` and, if that port is taken, walks up to
the next free one (at most 20 tries) and prints the port it took. With
`--port <n>` it uses exactly that port or fails with a one-line message;
`--port 0` picks any free port. The routes it serves are in
[REST API](rest.md); the public site it serves from the theme is in
[The site](site.md).

| Flag | Meaning |
|---|---|
| `--static` | Bring the built site under `--out` up to date at startup, then serve the files: nothing when nothing changed, the changed pages when some did, everything when there is no build or another theme made it (see [`build`](cli/build.md)). |
| `--full` | With `--static`: build every page again. |
| `--dev` | Render every page on request, cache nothing, tint every island. |
| `--out <dir>` | The built site to serve when it exists (default `output`). |
| `--url <base>` | The site's public address, for the sitemap. |

## Building

```
publr [--db <path>] build [--full] [--out <dir>] [--url <base>]
```

Writes the site as files, only what changed since the last build unless
`--full`; see [`build`](cli/build.md).

## Global flags

| Flag | Meaning |
|---|---|
| `--db <path>` | Use this database file. Must come first. |
| `--as <user>` | Run as that user, by id or email; the user's role applies. |
| `--as-admin` | Run as the local operator (`system`), unrestricted. |
| `-h`, `--help` | Print usage, options and every command. After a namespace (`publr user --help`, or just `publr user`), explain the namespace and list its commands. After a command, print its explanation, every field with its meaning, the output shape, and a runnable example with its output. |
| `--version` | Print the version and exit. |

Without `--as` or `--as-admin` the caller is **anonymous** (read-only, live and
public content only).

## Passwords

Any `--password` flag may be taken from the `PUBLR_PASSWORD` environment
variable instead, so the password does not appear in shell history or `ps`.
On `init` and `user create` it may also be omitted entirely: a
random password is generated and printed once in the output. Or create the
account without any password (`--password_link true`): it stays inactive and
you get a one-hour set-password link to hand to the person; `user
password_link` issues a fresh one at any time.

## Field flags

Each field of the operation's input is a flag named after the field:
`--<field> <value>`. Fields with a default may be omitted; fields without a
default are required.

| Field type | Value syntax |
|---|---|
| text | as-is |
| integer / decimal | `42`, `3.5` |
| boolean | `true` / `false` |
| choice (enum) | one of the listed names (help shows them, e.g. `admin\|editor`) |
| optional | the value, or `null` |
| list | comma-separated: `a,b,c` |

## Commands

Commands are grouped in namespaces; each namespace has its own reference page.
`publr --help` lists everything, `publr <namespace> --help` explains a
namespace, `publr <namespace> <verb> --help` documents one command with a
runnable example.

| Namespace | What it covers |
|---|---|
| [`heartbeat`](adapters/cli/heartbeat.md) | Liveness and version checks |
| [`site`](adapters/cli/site.md) | The installation itself: `publr init` |
| [`user`](adapters/cli/user.md) | Accounts, roles, passwords and signing in |
| [`content_type`](adapters/cli/content_type.md) | Content types: the shapes records are made of |
| [`record`](adapters/cli/record.md) | The content itself: documents, statuses, lists |
| [`taxonomy`](adapters/cli/taxonomy.md) | Taxonomies: the classifications records are filed under |
| [`term`](adapters/cli/term.md) | The terms of the taxonomies, with a record's lifecycle and a parent |
| [`status`](adapters/cli/status.md) | The lifecycle states a record can be in |
| [`snapshot`](adapters/cli/snapshot.md) | Frozen copies of records: revisions and other archives |
| [`view`](adapters/cli/view.md) | Saved views: the content list's filters, named and kept per user |

Plugins add namespaces of their own (for example `revisions`), listed by
`publr --help` and documented by `publr <namespace> --help` like the core.

