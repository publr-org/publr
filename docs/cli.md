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
                          [--apps <dir>]
```

Starts the HTTP server on `127.0.0.1` and runs until the process is stopped.
Without `--port` it starts at `8080` and, if that port is taken, walks up to
the next free one (at most 20 tries) and prints the port it took. With
`--port <n>` it uses exactly that port or fails with a one-line message;
`--port 0` picks any free port. The routes it serves are in
[REST API](rest.md); the apps it serves are in [Apps](apps.md).

| Flag | Meaning |
|---|---|
| `--static` | Bring every app's build under `--out` up to date at startup, then serve the files: nothing when nothing changed, the changed pages when some did, the whole app when there is no build or another version of it made it (see [`build`](cli/build.md)). |
| `--full` | With `--static`: build every page again. |
| `--dev` | Render every page on request, cache nothing, tint every island. |
| `--out <dir>` | The built apps to serve when they exist, one folder each (default `output`). |
| `--url <base>` | The project's public address: the apps' sitemaps, and the domain subdomain apps hang from (default `http://127.0.0.1:8080`). |
| `--apps <dir>` | Where each app's public files are read from, `<dir>/<folder>/public` (default `apps`). |

## Building

```
publr [--db <path>] build [--full] [--out <dir>] [--url <base>] [--apps <dir>]
publr check-apps
```

Writes every app as files, one folder each, only what changed since the last build
unless `--full`; see [`build`](cli/build.md). `check-apps` compiles every app the binary
carries and exits 1 naming the one that does not load; `zig build` runs it.

## Apps

```
publr apps load [--apps <dir>]
```

Reads the project's apps again from the folder the running server was started with and
swaps them in, so a changed template is live when it returns, and says which folder; a
template that does not load is named with the reason, and the apps answer 503 until a load
succeeds. With no server running, it only checks the apps: those in `--apps <dir>`, else
the project's own `apps/`, else the build's folder. `--apps` is refused while a server
runs, since the server reads only its own folder. See [Apps](apps.md).

## The compiler

```
publr [--db <path>] zig <args>
```

Zig 0.16.0, carried in the binary, with the arguments as given and its exit code. It builds
WebAssembly only, the way sandboxed plugins are built (it has no LLVM), so no Zig needs to
be installed.

```
publr [--db <path>] plugin build --name <name> [--dir <folder>] [--out <file>]
```

Builds the plugin whose source is `<folder>/main.zig` (default
`plugins/<name>`) with that compiler, reads its manifest from the module and
writes it in, then adds and enables it, or applies it as the next version of the one
already there. The compiler's messages print as they are; built again unchanged, it says
the plugin is up to date. `--out <file>` only builds it, into that file, and installs
nothing. See [Plugins](plugins.md).

`init` and `serve` write the compiler and the SDK plugins build against out once per
machine (about 35 MB), into `$PUBLR_CACHE_DIR`, else `$XDG_CACHE_HOME/publr`, else
`~/.cache/publr`; every project on the machine shares them. When they cannot be written,
they warn and carry on: only compiling needs them. A binary built with `-Dcompiler=false`
carries neither, and `publr zig` and `plugin build` say so.

## For agents

```
publr agents
```

Prints the guide for an agent building on this Publr ([Agents](agents.md), built into the
binary so it always matches it), then where the SDK's source is on this machine and every
permission a plugin may ask for, with its tier. `publr --help` points agents to it.

## While a server runs

`publr serve` owns its project while it runs. It writes its port and a fresh key beside the
database (`<db>.serve`, readable by its user only), and removes them when it stops. Every
other command then goes to it and runs there, as the admin's changes do: a plugin added,
enabled or updated from the CLI is live when the command returns, and its hooks and events
fire in the server. Output, errors and the exit code are the same as run here; a file named
with `--file` is sent as an absolute path. A second `serve` for the same database is
refused. When the file is there but nothing answers (the server was killed), the command
removes it and runs here.

## Global flags

| Flag | Meaning |
|---|---|
| `--db <path>` | Use this database file. Must come first. |
| `--as <user>` | Run as that user, by id or email; the user's roles apply. |
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
| list of text or of names | comma-separated: `a,b,c` |
| any other list, a structure | JSON, in quotes: `'[{"x":1}]'` |

An installed plugin's commands read their flags the same way, answer `--help` the same
way and refuse a wrong value with the same words as a built-in one's.

## Commands

Commands are grouped in namespaces; each namespace has its own reference page.
`publr --help` lists everything, `publr <namespace> --help` explains a
namespace, `publr <namespace> <verb> --help` documents one command with a
runnable example.

| Namespace | What it covers |
|---|---|
| [`heartbeat`](cli/heartbeat.md) | Liveness and version checks |
| [`project`](cli/project.md) | The installation itself: `publr init`, and what a change rebuilds |
| [`user`](cli/user.md) | Accounts, roles, passwords and signing in |
| [`role`](cli/role.md) | What each role lets its accounts call |
| [`identity`](cli/identity.md) | Signing in with a provider: which accounts, and whether sign-up is open |
| [`content_type`](cli/content_type.md) | Content types: the shapes records are made of |
| [`record`](cli/record.md) | The content itself: documents, statuses, lists |
| [`taxonomy`](cli/taxonomy.md) | Taxonomies: the classifications records are filed under |
| [`term`](cli/term.md) | The terms of the taxonomies, with a record's lifecycle and a parent |
| [`status`](cli/status.md) | The lifecycle states a record can be in |
| [`snapshot`](cli/snapshot.md) | Frozen copies of records: revisions and other archives |
| [`view`](cli/view.md) | Saved views: the content list's filters, named and kept per user |
| [`activity`](cli/activity.md) | What was done: every completed write, kept forever |
| [`errors`](cli/activity.md) | What was refused or failed, kept forever |
| [`internal`](cli/internal.md) | A plugin's internal records: what it keeps for itself, never content |
| [`plugin`](cli/plugin.md) | Installed plugins: install from a file, grant, update, remove |

Plugins add namespaces of their own (for example `revisions`), listed by
`publr --help` and documented by `publr <namespace> --help` like the core. A runtime
plugin's operations are commands too once it is installed (`publr greeter greet --note
hi`), their flags read by the field shapes in its manifest; `publr greeter greet --help`
lists them. What an app
calls is namespaced `app.<feature>`: `publr app.newsletter subscribe`.

