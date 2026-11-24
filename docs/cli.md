# CLI reference

Every operation is a command. Nothing is hand-written per command: the CLI
derives commands, flags and output from the operation table.

## Invocation

```
publr [--db <path>] [global flags] <namespace> <verb> [--field value ...]
publr [--db <path>] [global flags] <namespace>.<verb> [--field value ...]
publr --version
```

A list flag takes its values split at commas (`--tags a,b`) or as a JSON array
(`--urls '["https://a.eu/x,1.jpg","https://a.eu/y.jpg"]'`, the way to give a value with a
comma in it); a flag that takes an object takes JSON.

Output is the operation's result as JSON on stdout. Exit code `0` on success,
`1` on failure (the error name is printed on stderr), `2` when no command is
given.

The database is `data/publr.db` by default and is created on first use.

## Sites

A site is a folder Publr runs in: `publr.zon`, `apps/`, `plugins/`, and `data/` once it
first runs. Publr gives a project its starter when it first sets it up (the first `serve`,
`project init` or any command that makes its database), if `publr.zon` names it and the
folder has no `apps/` at all: `apps/www`, one page at `/` with links to deploy and to the
docs, the site's own to change. An empty `apps/` means none, and `/` opens the admin. The
first admin is made on the admin's setup page, or with `project init`. A Publr checkout is
a site too, run by its own build. Sites on one binary share its built-in plugins; a site's
own plugins are sandboxed.

Making sites, running them in the background, signing in to a Publr elsewhere, cloning,
pulling and pushing, packing a site into one file, deploying to Publr Cloud, building
plugins and setting up an agent's tool are the `publr` command's, which runs each site on
the Publr release it pins: [The publr command](#the-publr-command).

## Serving

```
publr [--db <path>] serve [--port <n>] [--static [--full]] [--dev] [--out <dir>] [--url <base>]
                          [--admin-url <url>] [--sync-url <url>] [--apps <dir>] [--idle-stop <s>]
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
| `--idle-stop <s>` | Stop after this many seconds without a request (default: never): a server started on demand that goes away when nobody uses it. |
| `--admin-url <url>` | The admin's own address, on another host or port than the site's; by default `admin.<the site's host>` on its port (`http://admin.localhost:8080` for a site on this machine), and a site on a bare IP address must name one. A path under it (`https://cloud.publr.app/spaces/ada/shop`) is for a host shared by several admins: the proxy in front takes the path off, and every address and cookie the admin sends back carries it. The site's host then sends `/admin` there, the admin's host sends the site's pages back, and a signed-in administrator sees the site as it is, with no frame ([apps.md](apps.md#the-toolbar)). |
| `--sync-url <url>` | Where other computers clone, pull and push this site when that is not its own address: a host that keeps sync traffic away from the CDN in front of its pages (Publr Cloud: `https://sync.cloud.publr.app:8443/<site>--admin`). `/api/health` says it as `sync`; the `publr` command syncs there when it is given. |
| `--url <base>` | The project's public address: the apps' sitemaps, and the domain subdomain apps hang from (default `http://127.0.0.1:8080`). A path in it (`https://example.com/site`) is where the whole project is served: requests are answered under it, and every address it sends back (pages, assets, redirects, cookies) carries it. |
| `--apps <dir>` | Where each app's public files are read from, `<dir>/<folder>/public` (default `apps`). |
| `--plugin <file>` | A transient plugin: this sandboxed plugin's `.wasm`, loaded for this server alone and never installed; what it keeps lives in memory and goes when the server stops. Repeat for more, up to eight. See [Transient plugins](plugins.md#transient-plugins). |

## Building

```
publr [--db <path>] build [--full] [--out <dir>] [--url <base>] [--apps <dir>]
publr check-apps
publr check-plugins
```

Writes every app as files, one folder each, only what changed since the last build
unless `--full`; see [`build`](cli/build.md). `check-apps` compiles every app the binary
carries and exits 1 naming the one that does not load; `zig build` runs it.
`check-plugins` prints a note for each compiled-in plugin's remote that another
compiled-in plugin switches off, and why (`note: stocktake: shelf.count is switched off:
shelf 0.2.0 has no operation shelf.count`); it always exits 0, and `zig build` runs it too.

## Apps

```
publr apps load [--apps <dir>]
```

Reads the project's apps again from the folder the running server was started with and
swaps them in, so a changed template is live when it returns, and says which folder. The
server also does this on its own whenever a file in the folder changes. A template that does
not compile is named with the reason and the apps loaded before keep serving. (A device, or `--as`, reaches the same as the operation `apps.load`.) With no server running, it only checks the apps: those in `--apps <dir>`, else
the project's own `apps/`, else the build's folder. `--apps` is refused while a server
runs, since the server reads only its own folder. See [Apps](apps.md).

## Plugins built elsewhere

```
publr plugin prepare --name <name> [--dir <folder>] --out <folder> [--with <x.wasm>]...
                     [--interfaces <file>]
publr plugin check --file <module.wasm> --dir <folder> [--views <folder>] [--with <x.wasm>]...
                   [--types] [--no-examples]
publr plugin sdk --out <folder>
publr plugin check --dir <folder>
```

Publr carries no compiler; the `publr` command compiles a sandboxed plugin against this
release, around these. `prepare` checks the plugin's source and writes what the compile
takes into a new or empty folder: this release's SDK, the plugin's docs module, its
lowered views and the published interfaces it builds against (the site's, those
`--interfaces` holds, or this binary's), then prints the compiler's arguments as JSON
(`args`, `module`, `views`, `dir`). `check --file` makes the compiled module whole (its
manifest read by running it and written in, with its source and its views' browser code),
says what its sandboxed build left out and runs its examples beside the site's plugins
(`--no-examples` leaves them; `--types` writes its types beside its views). It installs
nothing: `plugin add --file` does. `sdk` writes this release's SDK alone. `check --dir`
runs the plugin checks over a source and prints each problem with its file and line. See
[Plugins](plugins.md).

## For agents

```
publr agents
publr --commands
```

`publr --commands` lists every command at once, one line each with its exact flags (a flag
in brackets may be left out) and what it does, the installed plugins' included. A
conversation's agent starts every turn with it and the guide below, so it works from them
instead of exploring with `--help`.

Prints the guide for an agent building on this Publr ([Agents](agents.md), built into the
binary so it always matches it), then how to get the SDK's source and every permission a
plugin may ask for, with its tier. `publr --help` points agents to it.

```
publr agent --conversation <id>
```

One conversation's turn ([`ai`](cli/ai.md)), in a process of its own: the server starts it
when someone asks, never a person. It takes the device the turn runs as, runs the model's
loop, reports each step and ends the turn, all through the server beside it. What it did
goes to `data/agents/<id>.log`.

## Seeding

```
publr [--as-admin | --as <who>] seed --type <type> --file <path> [--publish]
```

Makes a record of the type from every document in the file: a JSON array of objects, or one
object a line. It sends them in calls of `record create_many`, 200 at a time (fewer when
they pass 512 KiB together), printing how many are in. Each call is all or nothing; a refused one stops the seed and says which document. Who
runs it goes with every call.

## The publr command

The `publr` command (`brew install publr-org/tap/publr`, `curl -fsSL
https://publr.dev/install.sh | sh`, or inside Publr Desktop) works around Publr from
outside: `new` and `init` make sites, `start`, `stop`, `open` and `logs` run them,
`login`, `logout`, `whoami` and `--site` reach a Publr elsewhere as a device, `clone`,
`pull` and `push` keep a folder's copy of a site and send its work up as a branch, `pack`
and `unpack` write a site as one file and back, `cloud login` and `deploy` make a site a
Publr Cloud project, `plugin build` builds a plugin, and `mcp`, `setup` and `skill` give
an agent's tool Publr. In a site's folder every other word goes to that site's Publr.

What it reaches on a site: `POST /api/cli` runs the words it sends as the device whose
token comes with them ([REST](rest.md)); the device operations sign it in
([`device`](cli/device.md)); a site hands its data to a clone (`GET /api/sites/size`,
`POST /api/sites/pack`), packing itself in a process of its own (`publr clone-pack-run`,
which the server starts without waiting) so a large database never runs the server out of
SQLite memory and the site keeps answering; and `site export`, `site import`, `site
state` and `site placeholders` below do the data work of a pack, a clone, a pull and a
push in the folder.

`--env <name>` runs a command in that environment or branch of this Publr, through the
plugin that keeps the copies. Copies are made as any are: `publr environments create
--kind branch --name <what>`. A device without **Write on production** may make one, but
every other write to production is refused with `WorksOnCopies`. On this computer,
`--device <id>` runs a command as a device approved here, with its access and under its
name in the activity log, as `--as` does for an account.

## While a server runs

`publr serve` owns its project while it runs. It writes its port, a fresh key, a stamp
of the binary it runs (the file's modification time, which a rebuild changes), its
address (`--url`, else `http://127.0.0.1:<port>`) and its admin's origin, where the `publr`
command's `mcp` reaches it, beside the database (`<db>.serve`,
readable by its user only), and removes them when it stops. `publr agents` says that
address while it answers. Every
other command then goes to it and runs there, as the admin's changes do: a plugin added,
enabled or updated from the CLI is live when the command returns, and its hooks and events
fire in the server. Output, errors and the exit code are the same as run here; a file named
with `--file` is sent as an absolute path. A second `serve` for the same database is
refused. When the file is there but nothing answers (the server was killed), the command
removes it and runs here.

## The database and its backups

`publr db check` says what this release would find opening the database (the release that
last opened it, migrations to run, every way its shape differs) and exits 1 when it would
refuse it. `publr db verify` reads the whole file and exits 1 when it is damaged.
`publr db tables` counts every table's rows. `publr backups` lists the backups
taken before each update and `publr restore <name>` puts one back, once `serve` is stopped.
They open the database without the gate. See [Updates](updates.md) and [`update`](cli/update.md).

## A site's data, moved

`publr site export --to <folder>` writes the site into a new or empty folder, for the
`publr` command to move it (its pack, push, deploy and clone): a manifest
(`publr-site.json`: format, version, the Publr that exported it, the release that last
opened the database, name, time), `data/` (a consistent snapshot of the database, media,
installed plugins, the secrets' key) and `site/` (`publr.zon`, `apps/`, `plugins/`). What is
only this computer's stays behind: sessions, devices, used sign-on tokens and whom the site
trusts to sign people in, live agents, the build index, caches, backups, agents' logs,
plugin builds, built pages and the serve marker. It is safe while `serve` runs, and refused
into the site's data folder. `--clone` leaves what a
clone leaves (the activity, error and plugin logs, secrets and their key, internal records),
`--no-media` leaves the media files (their records stay), and `--placeholders <file>` names
media storage keys, one a line, whose files stay behind (the manifest lists them).
`publr site import --from <folder> [--no-media]` takes such a folder into this one, with
every check: refused while `serve` runs, into a folder with a site, from a
newer format, past the size cap, for a link or a name outside the site; nothing is left
behind when it is refused. `--keep-local <database>` carries this computer's rows from
another database into the imported one (whom it trusts to sign people in, the sessions and
devices of the accounts it still has), as a pull keeps them. Both exit 1 when refused, 2 for
wrong words.

`publr site state [--until <ms>]` says, as JSON, what tooling needs of the site's own data:
`release` (this Publr), `latest_change` (the newest activity entry), `latest_write` (the
newest write to the site, made by `<ms>` when given; sign-ins, devices, views and the like
are not writes) and `media` (every media record's storage key and hash). `publr site
placeholders` writes a stand-in for every media record whose file is missing (a grey
picture of its size and type, an SVG of its size; nothing for other files) and prints each
one's storage key and bytes, a tab between, one a line; refused while `serve` runs.

## Global flags

| Flag | Meaning |
|---|---|
| `--db <path>` | Use this database file. Must come first. |
| `--env <name>` | Run the command in that environment or branch. See [The publr command](#the-publr-command). |
| `--device <id>` | Run as a device approved here, with its access and its name. Refused from elsewhere. |
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
| a record (an operation that takes one by reference) | its id: `--variant 01a1…` |
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
| [`project`](cli/project.md) | The installation itself: `project init`, what a change rebuilds, and a test site's clock |
| [`user`](cli/user.md) | Accounts, roles, passwords and signing in |
| [`role`](cli/role.md) | The roles, what each lets its accounts call, and changing them |
| [`user_type`](cli/user_type.md) | Types of user plugins register, and the apps each may sign in to |
| [`identity`](cli/identity.md) | Signing in with a provider: which accounts, and whether sign-up is open |
| [`device`](cli/device.md) | Agents and tools acting for an account, signed in by link |
| [`apps`](cli/apps.md) | The project's apps as files, for agents with no file system |
| [`content_type`](cli/content_type.md) | Content types: the shapes records are made of |
| [`record`](cli/record.md) | The content itself: documents, statuses, lists |
| [`taxonomy`](cli/taxonomy.md) | Taxonomies: the classifications records are filed under |
| [`term`](cli/term.md) | The terms of the taxonomies, with a record's lifecycle and a parent |
| [`media`](cli/media.md) | The media library: files, their folders and tags |
| [`status`](cli/status.md) | The lifecycle states a record can be in |
| [`job`](cli/job.md) | The work plugins queued, waiting or failed |
| [`operation`](cli/operation.md) | Every operation, as its code declares it and as this site overrides it |
| [`event`](cli/event.md) | The events plugins declare, with their payloads and the hooks on them |
| [`snapshot`](cli/snapshot.md) | Frozen copies of records: revisions and other archives |
| [`view`](cli/view.md) | Views of the content list: saved by name, and the default each type starts at |
| [`rail`](cli/rail.md) | The pages a person pins to their rail |
| [`money`](cli/money.md) | Amounts written as the site writes them |
| [`ledger`](cli/ledger.md) | The double-entry ledger plugins keep, read only: accounts, history, totals, the check |
| [`mod`](cli/mod.md) | Values plugins change: applied under a name, modified by whoever hooks it |
| [`ai`](cli/ai.md) | Conversations with a model: a person asks, an agent builds as their device |
| [`secret`](cli/secret.md) | Secrets plugins name but never hold: API keys, set by an administrator |
| [`removal`](cli/removal.md) | Removal lists: what an agent asked to remove for good, for its person to confirm |
| [`trash`](cli/trash.md) | The trash: what was removed, restorable until it goes for good |
| [`health`](cli/health.md) | Site Health: broken references to review case by case |
| [`design`](cli/design.md) | An app's design system and moodboard |
| [`http`](cli/http.md) | Requests a plugin sends out, its secrets filled in as they leave |
| [`mail`](cli/mail.md) | Email a plugin hands to a mail server over SMTP |
| [`update`](cli/update.md) | Updating this site's Publr to a newer release, and stepping back; `db check`, `backups`, `restore` |
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

