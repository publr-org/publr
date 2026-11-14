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

```
publr new <name> [--admin-only]
```

A site is a folder `publr` runs in: `publr.zon`, `apps/`, `plugins/`, and `data/` once it
first runs. Several sites may share one binary, each a folder beside it:

```
sites/
  publr          the binary (the installer puts it here; nothing goes on the PATH)
  blog/          publr.zon, apps/, plugins/, data/
  shop/
```

`new` makes `<name>/` in the current folder, with a `publr.zon` naming it and Publr's
starter in `apps/www`: one page at `/` with links to deploy and to the docs, the site's own
to change. `--admin-only` leaves `apps/` empty, so `/` opens the admin. Where the
binary is not one of the places agents look first (`publr`, `../publr`,
`zig-out/bin/publr`, `../zig-out/bin/publr`, from the site), `publr.zon` also names it
(`.binary`), relative when near and absolute when far. Then `cd <name>` and `serve`; the
first admin is made on the admin's setup page, or with `init`. A Publr checkout is a site
too, run by its own build. Sites on one binary share its built-in plugins; a site's own
plugins are sandboxed.

## Serving

```
publr [--db <path>] serve [--port <n>] [--static [--full]] [--dev] [--out <dir>] [--url <base>]
                          [--admin-url <url>] [--apps <dir>] [--idle-stop <s>]
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
| `--url <base>` | The project's public address: the apps' sitemaps, and the domain subdomain apps hang from (default `http://127.0.0.1:8080`). A path in it (`https://example.com/site`) is where the whole project is served: requests are answered under it, and every address it sends back (pages, assets, redirects, cookies) carries it. |
| `--apps <dir>` | Where each app's public files are read from, `<dir>/<folder>/public` (default `apps`). |

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

## The compiler

```
publr [--db <path>] zig <args>
```

Zig 0.16.0, carried in the binary, with the arguments as given and its exit code. It builds
WebAssembly only, the way sandboxed plugins are built (it has no LLVM), so no Zig needs to
be installed.

```
publr [--db <path>] plugin build --name <name> [--dir <folder>] [--out <file>]
publr plugin check --dir <folder>
```

Builds the plugin whose source is `<folder>/main.zig` (default
`plugins/<name>`) with that compiler, reads its manifest from the module and
writes it in, then adds and enables it, or applies it as the next version of the one
already there. The compiler's messages print as they are; built again unchanged, it says
the plugin is up to date. `--out <file>` only builds it, into that file, and installs
nothing. A plugin registered through `publr.plugin.define` is held to the plugin checks
first, and its doc comments are read beside it as its words. `plugin check --dir <folder>`
runs the checks alone and prints each problem with its file and line. See
[Plugins](plugins.md).

`init` and `serve` write the compiler and the SDK plugins build against out once per
machine (about 35 MB), into `$PUBLR_CACHE_DIR`, else `$XDG_CACHE_HOME/publr`, else
`~/.cache/publr`; every project on the machine shares them. When they cannot be written,
they warn and carry on: only compiling needs them. A binary built with `-Dcompiler=false`
carries neither, and `publr zig` and `plugin build` say so.

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
binary so it always matches it), then where the SDK's source is on this machine and every
permission a plugin may ask for, with its tier. `publr --help` points agents to it.

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
object a line. It sends them in calls of `record create_many`, 250 at a time (fewer when
they pass 512 KiB together), to this site or the one `--site` names, printing how many are
in. Each call is all or nothing; a refused one stops the seed and says which document. Who
runs it goes with every call.

## Publr in an agent's tool

```
publr setup cursor|claude|codex
publr mcp [--folder <path>]
```

`setup` adds Publr to that tool once, for every project, in the tool's own way: Cursor's
install link (Cursor asks the person), `claude mcp add --scope user`, `codex mcp add`. The
entry runs `publr mcp` from this binary's full path; Cursor passes each window's folder as
`--folder`. Running it again only points the entry at this binary. Not on Windows yet.

`mcp` is an MCP server over standard input and output. It passes each message, unchanged,
to the `/mcp` of the site the folder works on, and the site's answer back: the tools are the
site's, so one `publr` serves sites on any release. The folder is `--folder`, else Claude
Code's `CLAUDE_PROJECT_DIR`, else the one it starts in; it, or a folder above it, either
names a site elsewhere in `.publr/site` or is a site (`data/publr.db`), reached through the
server running it. A folder that is neither gets the tools by name and `link` (`address`),
which the agent calls once the person says which site the folder is for: it signs this
computer in and writes `.publr/site`, never in a site's own folder, the home folder or the
root. Signing in happens on the first call that needs it: the browser opens on the site's
approve page, the call waits up to 40 seconds and otherwise answers that the person still
has to approve. The token is kept with the CLI's, one per site for every tool, named after
the tool ("Cursor on <computer>"). A token the site no longer accepts is forgotten, and the
next call asks again.

## A Publr elsewhere

```
publr login <address> [--name <name>] [--scope read|write|production|publish] [--no-browser] [--claim <code>]
publr logout [<address>]
publr whoami [<address>]
publr --site <address> [--env <name>] <command ...>
```

`login` signs this machine in to the Publr at `<address>` as a device
([Authentication: Devices](auth.md#devices)): it prints a link (and opens it when there is
a browser), its person approves it in that Publr's admin and chooses what it may do
(`--scope` caps what is on offer), and the token is kept in
`~/.publr/credentials` (or `$PUBLR_CREDENTIALS`), readable by its user only, by address.
`--claim <code>` takes a sign-in the person already gave (`device offer`, the code in the
Overview's setup command) instead: nothing to approve.
It is never printed. `--name` is what the person sees; it defaults to "The publr CLI on"
this machine's name.

`--site <address>` (or `PUBLR_SITE`) sends a command to that Publr with its token: the
words go as they are and are read there, so its plugins' commands and its help are what
answer. `--as` and `--as-admin` are refused there; the device is who you are. `logout`
revokes the device there and forgets it here; `whoami` says whose it is, its scope and its
name. With one address kept, `logout` and `whoami` need none.

A folder whose `.publr/site` holds an address builds that Publr: its commands go there as
if `--site` named it, and `logout` and `whoami` mean it. The setup an Overview offers for
an agent (`curl … | sh`) writes it. `agents`, `skill`, `login`, `logout` and `whoami` always run
on this machine.

`--env <name>` sends the command to that environment or branch of the Publr, with the same
token. Without it a command goes to production. Copies are made as any are: `publr
environments create --kind branch --name <what>`. A device without **Write on production**
may make one, but every other write to production is refused with `WorksOnCopies`. A Publr
that keeps no copies has only itself.

On this computer, `--device <id>` runs a command as a device approved here, with its access
and under its name in the activity log, as `--as` does for an account.

## Clone and push

```
publr clone <address or project> [<folder>] [--media all|none] [--size] [--port <n>]
            [--no-open] [--no-serve]
publr push
```

`clone` signs in as a device if this machine is not yet, and writes the site to a folder: its
database, media, apps, plugins and `publr.zon`. Only an administrator can. It leaves behind
every other account, secrets, plugins' internal records, the logs and the site's copies; the
account cloning stays, an administrator. A bare project name means `https://<it>.publr.app`.
The Publr here must be the one there; a mismatch prints the install line for the right one.

`clone` is seen while it runs. It starts a small server at the folder's admin address
(`http://admin.localhost:<port>`, `--port` or a free one) and opens its page,
`/admin/sync`, in Publr Studio when it is installed (`publr-studio://open?url=`), else in
the browser (`--no-open` only prints it). The page shows each step as it happens: the site
packed there, the download and the unpacking on one bar divided into the site's parts
(database, media, apps, plugins, each named under its stretch), placeholders. Without
`--media`, the page first asks what comes down: everything, or the database and setup with
placeholders for media, each with what it weighs; the clone waits for the answer. When the
folder is written, a session for the account that cloned it is made there; the page takes
its cookie once, and the clone becomes the folder's `publr serve` on the same address, so
the page opens the admin signed in. `--no-serve` stops once the folder is written.

The site packs itself in a process of its own (`publr clone-pack-run`, which the server
starts without waiting), so a large database never runs the server out of SQLite memory and
the site keeps answering while it packs. The clone asks how far it is, and the page's bar
moves through packing, downloading and unpacking, a third each.

`--size` only says what a clone would bring down (`database_bytes`, `media_files`,
`media_bytes`, from the site's `GET /api/sites/size`), for the person to be asked first.
`--media none` brings no media files: every media record comes, and a plain placeholder of
the same width, height and type stands in for its file (an empty file for one that is not
a picture), listed with its size in `.publr/placeholders`.

The folder is a site of its own: `publr serve`, `--as-admin`, your own editor. `push`, run in
it, sends it up as a branch of the site for a person to review and merge. Pushing again from
the folder replaces the same branch. A placeholder still there unchanged is never sent: the
bundle names it, and the branch takes the live file. Nothing here ever writes to the live site. The Publr
there must keep copies.

## The skill

```
publr skill
publr skill install [--agent claude|codex|cursor|pi | --dir <path>]
```

`skill` prints the build-on-publr skill this binary carries: how an agent decides where a
need goes, what it never does, and when core may change. `skill install` writes it, with
its references, into the folder it runs in, where agents that load skills find it: in
`.agents/skills/build-on-publr/`, which Codex, Cursor, Pi and other agents following Agent
Skills read, and in `.claude/skills/build-on-publr/` for Claude Code. `--agent` writes
only that agent's folder (Cursor's is `.cursor/skills/`, Pi's `.pi/skills/`), `--dir` only
the folder named. The repository is
also a plugin marketplace (`.claude-plugin/`) offering the same skill.

## While a server runs

`publr serve` owns its project while it runs. It writes its port, a fresh key, a stamp
of the binary it runs (the file's modification time, which a rebuild changes), its
address (`--url`, else `http://127.0.0.1:<port>`) and its admin's origin, where `publr mcp`
reaches it, beside the database (`<db>.serve`,
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
refuse it. `publr db tables` counts every table's rows. `publr backups` lists the backups
taken before each update and `publr restore <name>` puts one back, once `serve` is stopped.
They open the database without the gate. See [Updates](updates.md) and [`update`](cli/update.md).

## A whole site in one file

`publr pack [<file>]` writes the site in this folder as one file, `<folder>.site.tar.gz`
unless named: a gzipped tar with a manifest (`publr-site.json`: format, version, the Publr
that packed it, the release that last opened the database, name, time), `data/` (a
consistent snapshot of the database, safe while `serve` runs, media, installed plugins, the
secrets' key) and `site/` (`publr.zon`, `apps/`, `plugins/`). What is only this machine's
stays behind: sessions, devices, used sign-on tokens and whom the site trusts to sign people
in, live agents, the build index, caches, backups, agents' logs, plugin builds, built pages
and the serve marker. `publr unpack <file>` writes a packed site into this folder, which must
have none; a bundle from a newer format, a name that would land outside the site, or a link
is refused.

`publr cloud login [--cloud <dashboard>]` signs this computer in to your Publr Cloud
account (`PUBLR_CLOUD`, else `https://cloud.publr.app`), as Publr Studio does: the browser
opens on Cloud's sign-in, you approve "Publr CLI", and the token is kept with the CLI's other
sign-ins. The dashboard's Account page lists it, with Sign out.

`publr cloud deploy [--space <space>] [--slug <address>] [--name <name>] [--cloud <dashboard>]`
makes this site a Publr Cloud project. It takes the token `cloud login` kept
(`PUBLR_CLOUD_TOKEN` instead, when set), your space when you have one (with several it lists
them for `--space`), and an address made from the folder's name with a random ending
(`shop-k3v9q2`) unless `--slug` names one. A site never run yet (straight from `publr new`)
gets its database made first, as `serve` would. It checks the address, packs the site, uploads it
to the dashboard, and has the project made from it, in your space only. The folder then
carries the link (`cloud.json`: the dashboard, space, project, address and admin) and is
refused next time: changes reach a live site only through Cloud.

## Global flags

| Flag | Meaning |
|---|---|
| `--db <path>` | Use this database file. Must come first. |
| `--site <address>` | Send the command to the Publr at that address, as this machine's device there (after `--db`, before the command); `PUBLR_SITE` does the same. See [A Publr elsewhere](#a-publr-elsewhere). |
| `--env <name>` | Run the command in that environment or branch. See [A Publr elsewhere](#a-publr-elsewhere). |
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
| [`project`](cli/project.md) | The installation itself: `publr init`, and what a change rebuilds |
| [`user`](cli/user.md) | Accounts, roles, passwords and signing in |
| [`role`](cli/role.md) | The roles, what each lets its accounts call, and changing them |
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
| [`snapshot`](cli/snapshot.md) | Frozen copies of records: revisions and other archives |
| [`view`](cli/view.md) | Views of the content list: saved by name, and the default each type starts at |
| [`rail`](cli/rail.md) | The pages a person pins to their rail |
| [`mod`](cli/mod.md) | Values plugins change: applied under a name, modified by whoever hooks it |
| [`ai`](cli/ai.md) | Conversations with a model: a person asks, an agent builds as their device |
| [`secret`](cli/secret.md) | Secrets plugins name but never hold: API keys, set by an administrator |
| [`removal`](cli/removal.md) | Removal lists: what an agent asked to remove for good, for its person to confirm |
| [`trash`](cli/trash.md) | The trash: what was removed, restorable until it goes for good |
| [`health`](cli/health.md) | Site Health: broken references to review case by case |
| [`design`](cli/design.md) | An app's design system and moodboard |
| [`http`](cli/http.md) | Requests a plugin sends out, its secrets filled in as they leave |
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

