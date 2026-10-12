# Plugins

Plugins and apps follow [How to build well](agents.md#how-to-build-well).
Every declaration and its shape is listed in the [Plugin API reference](plugin-api.md).

Publr has two ways to run a plugin. Both use the same SDK. The difference is
where the plugin lives and who decides that it is there: every plugin is either
**built-in** (compiled into the binary, locked: it cannot be disabled) or **installed**
(loaded at runtime into the sandbox: enabled, disabled and removed from the admin). The same
source builds either way. In the code a plugin's mode is `native` or `sandboxed`, and what
its operations and hooks take (`*PluginCtx`) is `HostApi` for a native one (direct calls,
full access) or `SandboxApi` for a sandboxed one (every call a message to the host).

```mermaid
flowchart LR
    subgraph Binary["Publr binary"]
        Core[Publr core]
        CI1[Built-in plugin]
        CI2[Built-in plugin]
    end
    subgraph Sandboxes["WebAssembly sandboxes"]
        subgraph S0["sandbox"]
            SDK[SDK proxy]
        end
        subgraph S1["sandbox"]
            RP1[Installed plugin]
        end
        subgraph S2["sandbox"]
            RP2[Installed plugin]
        end
    end
    Core --- CI1
    Core --- CI2
    Core <--> SDK
    SDK <--> RP1
    SDK <--> RP2
```

## Built-in plugins

A built-in plugin is placed into the Publr binary by a developer or a
build tool. The result is a tailored Publr: one binary with every battery
someone decided to put inside.

From the user's point of view these plugins are core features. They cannot
be disabled, removed or updated from the admin. Updating one means updating
the plugin source and building a new binary.

This is sometimes called **agency mode**: a software agency prepares the
build for a client, so what the client gets is stable, has every feature they
need, and just works. Only a competent operator decides what goes in, which
makes this setup very safe and resilient.

Two things follow from being inside the binary:

- **Full access.** A built-in plugin can reach the whole Publr API and any
  internals. Whoever builds the binary is responsible for checking it.
- **Deep integrations are possible.** Some plugins must be compiled in because
  they need things the SDK does not expose to the outside: swapping the
  database, adding database extensions, replacing the cache layer, and other
  advanced hooks.

A plugin that uses only the public SDK can be shipped both ways: compiled in,
or as an installed plugin. Whatever it does installed, it does the same compiled in, and
`zig build verify-full` proves it for every test plugin (see
[Build: Two-mode check](build.md#two-mode-check)).

## Installed plugins (DLP)

Installed plugins are the opposite. They are added from the admin, without
recompiling anything. Think of them as dynamically linked plugins, in the
spirit of DLLs, hence DLP.

```mermaid
flowchart LR
    Core["Publr core (precompiled)"]
    subgraph S0["sandbox"]
        Proxy[SDK proxy]
    end
    subgraph S1["sandbox"]
        P1[Plugin A]
    end
    subgraph S2["sandbox"]
        P2[Plugin B]
    end
    subgraph S3["sandbox"]
        P3[Plugin C]
    end
    Core <--> Proxy
    Proxy <--> P1
    Proxy <--> P2
    Proxy <--> P3
```

Each installed plugin is a precompiled WebAssembly module running in its own
sandbox. It never touches Publr directly: every call goes through the SDK
proxy, which dispatches through the same operation pipeline everything else uses. That gives:

- **An enforced boundary.** The plugin can only do what the SDK exposes and
  what an administrator granted it.
- **Isolation.** A buggy plugin cannot crash Publr or read another plugin's
  memory. A call that loops or grows past its limits stops, and only that call fails.
- **No recompilation.** Install, update or remove a plugin from the admin or
  the CLI, and it just works. Publr stays one binary.

Installed plugins are managed under Settings > Plugins in the admin, and with `publr plugin`
([CLI](cli/plugin.md)). The Built-in tab lists the built-in plugins beside them, read
only: a build puts those there, and only a new build changes them. Added, an installed plugin
is listed and runs nothing; **enabling** it shows what it asks
for and starts it; disabling stops it and keeps what it was granted. What it does, it
does as itself: every call it makes is authorized as the plugin, with the permissions it
holds now. When it acts for someone (an editor calling its operation, a hook on their
save), each call gets the narrower of its permissions and that person's roles.

A newer module for a plugin already there does not replace it: it waits as the
plugin's next version. **Updating** shows what the new version asks for beside what the
plugin holds, then runs it; the version it replaces is kept, and **rolling back** returns
to it (and keeps the other in turn). A module that does not load in the sandbox is never
added.

### Permissions

A plugin asks for permissions by key, each with its own reason. The administrator sees
the sentence, the reason, the key and a tier before enabling it:

| Tier | On enabling | Examples |
|---|---|---|
| Low | granted | `content.read`, `schema.read`, `users.names`, a hook that sees an event |
| Medium | granted, listed | `content.write`, `content.drafts`, `release.manage`, a hook that changes an input |
| High | pending until approved | `users.read`, `users.write`, `content.purge`, `settings.global`, `http.fetch`, `secret.<NAME>`, a raised limit |

Some operations no permission names, so no plugin ever reaches them: signing in and out,
passwords and set-password links, who may sign people in, setup, roles, saved views, the
project's secrets, a person's conversations with a model. A
plugin always reaches its own operations (`<name>.*`, `app.<name>.*`) and its own content
types' records without asking. Content permissions are held to its **content access**:
public types (the default), every type, or the ones the administrator ticks.

Anything granted can be revoked at any time, one at a time; the plugin's next call
answers `Denied` and it must carry on without. A key nothing installed provides is shown
as unavailable: the plugin runs without it.

### Calling out, and secrets

A plugin granted `http.fetch` sends requests with `ctx.call(publr.operations.http.Fetch,
...)`: to the domains it declares in `allowed_domains` (or a domain under one), over https,
or plain http to this machine. A key it needs is a **secret it names but never holds**: it
asks for `secret.<NAME>` and writes `{secret:NAME}` where the value goes, in the address, a
header or the body. The value is filled in as the request leaves, and put back as
`{secret:NAME}` wherever the answer echoes it. It comes from the environment variable of
the same name, else from what an administrator set under Settings › Secrets
([`secret`](cli/secret.md)). A secret not granted, or with no value, fails the call
(`SecretNotGranted`, `SecretMissing`).

### Model providers

A plugin becomes a model provider by registering two operations, built by `publr.ai`:
`publr.ai.Describe("<name>", .{...})` (its label, models, default model, and its key: the
secret it is kept under, where it is made, what to do there, how it starts) and
`publr.ai.Complete("<name>", complete)`, where `complete` turns a `publr.ai.Request` into a
`publr.ai.Response` by calling its API through `http.fetch`. Core finds every provider
installed by those names, lists them under Settings › AI, and has a conversation's agent
call the one chosen, in the agent's own process. Publr's official providers live in the
workspace's `plugins/` folder; Settings › AI sets one up in a click when the server knows
that folder (`PUBLR_PLUGIN_CATALOG`): it adds the provider's built module, as uploading it
does, and opens its review.

A message's parts are text, tool calls, tool results and images (a media type and base64
bytes: screenshots the agent takes, pictures the person attaches); in a tool message the
images follow the results. A provider sends each in its API's own shape. Pictures make a
request a few MiB, so providers ask for more memory than the default (`limits`), and
`http.fetch` sends up to 8 MiB. A provider that streams reads the reply with `http.stream`
and `http.read` and passes the words on with `publr.ai.Progress` (`ai.progress`, a
permission of its own) as they come; `publr.ai.Events` splits the stream into its
`data:` lines.

### Limits

Every call into a plugin runs within limits: 100 ms of CPU (counted in instructions),
16 MiB of memory, 1,000 calls of its own, 1 MiB of output. A plugin that needs more asks
in its manifest, with a reason; each raised limit is a high-tier request.

## Writing an installed plugin

An installed plugin is written exactly like a built-in one, against the same SDK, with
`*PluginCtx` operations and hooks. On top, it declares what it asks for:

```zig
pub const permissions = [_]publr.plugin.Permission{
    .{ .key = "users.names", .reason = "Greets the people on the site by name" },
};
pub const limits: publr.plugin.Limits = .{ .cpu_ms = 2000, .reason = "Resizes images" };
pub const content_access: publr.plugin.ContentAccess = .{
    .recommend = .all,
    .note = "Indexes every type for search",
};
pub const depends_on = [_][]const u8{"newsletter@^1"};
```

Each hook carries its reason (`pub const reason = "..."`); an event hook names the event
it sees (`pub const event = "record.published"`), an operation or a notice, and sees only
that one, compiled in or installed. A plugin never writes `export fn`.

### Panels on edit forms

A plugin can add a box to any content type's edit form, its own type, another plugin's,
or the core's, without that type's plugin knowing about it:

```zig
pub const panels = [_]publr.plugin.Panel{.{
    .type = "product",
    .label = "Stock",
    .operation = StockPanel,
}};
```

`StockPanel` is one of the plugin's reads, taking `record` (the record's id) and `base`,
answering `html`. The admin shows it in the editor's right column, titled with its label
and the plugin's name, in the plugin frame sized to its content; `call` and `query` work
in it as on the plugin's pages. It is told only which record it is on and reads the rest
itself, within what it and the viewer may. It shows to whoever may call the read, on
records of that type, and not at all when the type is not there.

### Entries in the admin's lists, and what a plugin says about itself

Any plugin, installed or built-in, can add entries to the top bar: data the admin draws
with its own components, so they look like its own and pass for nothing else. The rail is
the person's: no plugin adds to it (declaring `rail` is a compile error). A plugin's pages
are listed under Settings and its sections in Content, and each person pins the ones they
use to their own rail (`publr rail pin`, or the pin on the row).

```zig
pub const top_bar = [_]publr.plugin.Item{.{
    .label = "Notes", .icon = "file", .page = "entries", .operation = List,
    .count = Count, // a read answering `count`, shown beside the label
}};
```

A plugin that brings several content types can give them a part of the admin of their
own, listed in Content under Sections (and pinnable to the rail), instead of mixing them
into its types:

```zig
pub const sections = [_]publr.plugin.Section{.{
    .label = "Shop",
    .icon = "folder",
    .types = &.{
        .{ .handle = "product", .columns = &.{ "price", "stock" } },
        .{ .handle = "order" },
    },
}};
```

The section's sidebar lists its types; each list is the admin's content list with up to 4
of the type's fields after the title (text, numbers, yes/no, dates, money, colours), and
editing a record keeps the section lit. Its types leave the Content sidebar. A section
names only the plugin's own record types; the admin shows the ones the viewer can see.

An entry leads to one of the plugin's pages (`page`) or an address in the admin
(`href`, `/admin/...`), never elsewhere, and is shown to whoever may call `operation`.
`pub const about = "<p>...</p>"`
is what the plugin says about itself on its page under Settings › Plugins: HTML, through
the admin's sanitizer profile (no layout or colour of its own, the admin's few classes
`muted`, `success`, `warning`, `error`, images only from the site, links elsewhere opening
apart), in a box the admin draws and names after the plugin.

### Pages in the plugin frame

Any plugin, installed or built-in, can bring pages of its own, listed in the Settings
sidebar for whoever may call the read that draws them:

```zig
pub const pages = [_]publr.plugin.Page{.{
    .path = "log",
    .label = "Guestbook log",
    .icon = "stack",
    .operation = Page, // a read: In has `query` and `base`, Out has `html`, all strings
}};
```

The page is at `/admin/plugin/<plugin>/<path>`. The admin draws its chrome and puts the
plugin frame in the sheet: an `<iframe sandbox>` with an opaque origin. The frame's
document is the `html` the read answers, run as the person looking at it, with the
address's query string as `query` and the path the project is served under as `base`.

A compiled-in plugin draws the page with the admin's own layouts, so it looks like any
other Settings page: its view (an `IndexPage`, a `FormPage`) rendered whole with
`publr.admin.render.document(arena, publr.admin.chrome.in_plugin_frame(ctx, in.base),
View, props)`, which leaves out the rail, the sidebar and the crumbs the admin already
draws around the frame, and speaks the person's language: `Publr.t` in the view reads
their catalogue. An installed plugin gets the same once the design system is drawn
for it by the host; until then it answers its own markup. It gets the admin's stylesheet and a small bridge, and
nothing else: no session, no network (`connect-src 'none'`), and it can be framed only
by the admin. Its response carries the same policy, so it stays sandboxed even when
opened on its own.

Inside, anything goes: any markup, any script, any library. The admin's design system
is the easy default. The frame reaches the admin only through the bridge:

- `publr.call("guestbook.sign", input)` runs one of the plugin's own operations as the
  viewer, through the usual checks, and resolves with its output. Anything else is
  refused.
- `publr.navigate("log?week=2")`, and every link clicked, goes to another of the
  plugin's pages (`?week=2` alone stays on this one). A link to another site opens in a
  new tab.
- The frame grows with what it shows.

What the frame draws never reaches the admin, so it needs no sanitizing and no
permission.

A page can also be a declaration, with no views of the plugin's: `.form = .{ .read =
Read, .save = Save, .multiline = &.{"description"} }` instead of `.operation`. The admin
draws it as one of its own pages (no frame: nothing of the plugin's is drawn), a field for
each field of `Save`'s input (strings, numbers, switches; `multiline` ones as several
lines; each `field_docs` line as its help), filled from what `Read` answers; Save calls
`Save` as the person looking. It works the same for an installed plugin, which draws
nothing else in the admin yet.

In a page's PTSX, `publr/operations` does the talking, the same in the frame and on an
admin page: `call("guestbook.sign")` is a write through one of the plugin's operations
(called with its input; `isPending`, `error`, `value`), after which every read on the page
reads again; `query("guestbook.entries")` is a reactive read (`value`, `isPending`,
`refresh()`), and ``query(groq`*[_type == "entry"]`, () => params)`` a GROQ read through
`record.query`, run as the plugin for the viewer, so it reads no more than both may. The
admin's composites (`FieldRow`, `ItemList`, `StatusStrip`) and `OperationForm` (a form
from a list of fields and the operation that saves them) make the page look like the
admin's own without styling it. `publr plugin build` writes `ui/operations.d.ts`, each
operation's input and output as TypeScript, and `plugin scaffold` gives a working plugin
to start from.

## One folder, and which are compiled in

Every plugin of a project is a folder under `plugins/`, `plugins/<name>/main.zig`, the
same source whichever way it runs. Which are compiled in is the project's decision, in
`publr.zon` beside that folder, and nothing else's:

```zig
.{
    .plugins = .{
        .native = .{ "blog", "hello" },   // compiled into publr: Built-in in the admin
    },
}
```

or every plugin under `plugins/`:

```zig
.{
    .plugins = .{
        .native = .all,
    },
}
```

With no `publr.zon`, or no `.plugins.native`, none is: every plugin is built for the sandbox and
installed at runtime. A plugin never says which it is: trusting code with everything is
its owner's choice, never its author's. `zig build` compiles in the ones listed (a name
`plugins/` lacks fails the build).

`publr plugin build --name <name>` builds `plugins/<name>/main.zig` for the sandbox with the
compiler Publr carries, so no Zig is needed: its manifest is read from the module itself and written into it, then it is added
and enabled (a new plugin) or applied as its next version (one already there, the previous
kept to roll back to). What it asks for is granted by tier; high requests wait for an
administrator. Built again unchanged, it is up to date. `zig build sandboxed-plugins` builds
every plugin under `plugins/` that is not compiled in with the same command into
`zig-out/sandboxed-plugins/<name>.wasm`, as the tests build theirs; see
[Build](build.md#the-plugins).

**Every plugin builds for the sandbox.** What cannot run there is left out of that build,
never a reason to refuse it: `schema_sql`, `bootstrap` and a sign-in provider (they need
the host), an operation or hook that takes the host's context (`*sdk.Ctx`) rather than
`*PluginCtx`, and, until the sandbox runs them, policies, pre hooks, field kinds,
statuses, transitions, filters and delivery gates. The build names each (`publr plugin
build` prints them; the manifest's `left_out` keeps them, and `plugin get` shows them;
the admin's plugin page does not yet).
Calling an operation left out answers `unavailable`; a hook left out never runs.

What a plugin calls is checked as it compiles: a `ctx.call` of an operation that none of
its declared permissions opens fails the build, naming the permission to add ("plugin
peek calls `user.list`, which needs `users.read`"). Its own namespace, the harmless
operations and record operations pass: a record operation may reach its own types, which
need nothing, and one that names another type without a permission is refused when it
runs, as `Denied`.

In the sandbox, operations, before, after, event and display hooks, content types, custom
fields and roles run; a role from a plugin grants only its own operations.

## Which one to pick

| | Built-in | Installed (DLP) |
|---|---|---|
| Added by | developer or build tool | admin, marketplace, repository |
| Needs a rebuild | yes | no |
| Access | full, trusted | SDK only, within its permissions |
| Isolation | none, it is part of the binary | sandboxed |
| Can be disabled or removed by the user | no | yes |
| Deep integrations (database, cache, ...) | yes | no |
| HTTP routes of its own | yes | not yet |
| Admin pages and a top bar item | yes | not yet |
| State, process hooks, operator commands | yes | not yet |
| Uses only the public SDK | works | works |

## Writing a built-in plugin

A plugin is one directory under `plugins/` with a `main.zig`, listed in `publr.zon`'s
`.plugins.native` to be compiled in. It imports one
thing, `publr`, and declares what it brings: a manifest (name, version,
summary), documented namespaces, operations exactly like the core's, each named
`<plugin>.<verb>` or `app.<plugin>.<verb>` (anything else fails the build; a plugin
cannot take a core namespace's name, or `app`), policies,
hooks, statuses, field kinds, content types, roles (see below), delivery gates (who
sees the apps, see [Apps](apps.md#delivery-gates)), filters (a `filters` array of
`model.filter.Definition`: a key, a label, operators, and how a clause constrains the
list; the admin's content list grows a pill for each) and a sign-in provider (see below). `zig build` finds it, compiles it in and
wires it up; nothing is registered anywhere else. Its operations appear in the
CLI and every other adapter, documented like the core's.

Storage is content types and snapshots. A plugin that needs to keep things
declares a type (`pub const content_types = [_]publr.plugin.ContentTypeDef{...}`,
usually private) and works with it through the record operations. The type is
created, or brought up to date, when the database opens, owned by the plugin:
it shows in the types manager as a system type, its declared fields are
locked, and editors can add fields of their own that survive the next
redeclaration. Its records get validation, permissions, listing, filtering
and the admin for free. History goes into
snapshots (`snapshot take/list/prune`, kinds of the plugin's own); parked
copies of a document go into slots (`record get --slot`), like the core's
`pending`. A plugin that truly needs its own table ships `schema_sql`; it runs only when
the plugin is compiled in. Once a release of the plugin has shipped, a change to those
tables is a migration of its own, `pub const migrations = [_]publr.db.migration.Migration{...}`,
named by the release that ships it and run by the gate like core's ([Updates](updates.md)).

A plugin that keeps files declares a **media type**: a type of `.kind = .media` with a
`title` field and, optionally, the file families it takes (`.families = &.{"image"}`).
Its files are uploaded with `media upload --type <handle>` (`/media/upload?type=`),
listed with `media list --type`, read with `media read`, and kept apart from the media
library and every other type: they show nowhere until the plugin draws them on a page of
its own. A Private media type's files are private. Sandboxed plugins declare one the same
way.

A page shows its type's files with the admin's own library: `<MediaLibrary type="invoice_file" />`
(`@publr/admin/MediaLibrary.ptsx`) is the whole of Media's screen for that type, the bar,
the explorer, the tiles and a file opened in place, reading the files of the address it
is on. Its parts lay it out differently or beside a page's own:
`MediaLibraryFilterBar` (with `MediaLibraryUpload`, or other actions, as children),
`MediaLibrarySidebar`, `MediaLibraryGrid`, `MediaLibrarySelection`, `MediaLibraryPager` and
`MediaLibraryFile`, inside `<MediaLibrary type="…">`. A part of the page's own imports
`state` and the actions (`follow`, `load`, `toggled`…) from `MediaLibrary.ptsx`, so its
table filters, pages and selects as the grid does. On a Settings page, `<ListDetailPage sidebar>` keeps the
Settings sidebar beside it. On a compiled-in plugin's own route it
works today; in the plugin frame it waits on the frame reaching `media` operations.

A plugin can declare roles (`pub const roles = [_]publr.plugin.Role{...}`): a name, a
label and grants, each an operation or a namespace ending in `.*`. A name of its own is
a new role, such as the visitors of an app, granted `app.<feature>.*`; the name of one
there already adds grants to it, so a plugin whose operations editors should call
declares `editor` with `<feature>.*`. Only an admin gives an account a role; a plugin's
open sign-up creates accounts with its own. See [Auth](auth.md#roles).

A plugin can declare one **sign-in provider** (`pub const sign_in_provider:
publr.plugin.SignInProvider`): a name (`github`, in URLs and identity rows), a label
("Continue with GitHub"), its mark as one SVG path on a 24 by 24 canvas (brand marks are
the plugin's, never the icon set's), and three functions: `available`, whether its
credentials are in the environment (an unavailable provider is compiled in but not
offered); `authorize_url`, where to send the browser given the callback URL, the `state`
and the PKCE challenge the core made; and `identity`, which exchanges the callback's
code for who the person is (their stable id at the provider, their email and whether the
provider vouches for it, a name, an avatar). The core does the rest: the routes, the
cookie, the buttons, and whose account it is ([Auth](auth.md#signing-in-with-a-provider)).

A plugin can answer **HTTP routes** (`pub const routes = [_]publr.plugin.Route{...}`): a
method (`get` or `post`), a path and a handler, `fn (request, response, ctx)` like the
core's. Every path lives under a prefix the plugin owns, `/admin/<own>`, `/api/<own>` or
`/auth/<own>`, where `<own>` is its name or one of its namespaces; after the prefix a
segment may be a parameter (`/api/shop/orders/:id`). A plugin has at most 16. Its routes
come before the core's, and the server refuses to start when a prefix covers a core route
(a plugin named `content` would take `/admin/content`). A handler that calls operations
does it as whoever sent the request: `publr.plugin_routes.caller_context` gives the SDK
context, refusing a write that does not come from this site with the session's CSRF
token, as the REST API does. A route that signs someone in its own way (a token another
server made, say) gets a session from an operation and hands it to
`publr.plugin_routes.set_session`, which sets this site's session cookie as the core's
sign-in does. Routes run only compiled in; an installed build leaves them
out and says so.

A plugin can show in the **admin**. Its views are PTSX files in `ui/` beside its
`main.zig`, lowered with the admin's own when it is compiled in: they import the design
system as `@publr/ui/<Name>.ptsx` and the admin's views as `@publr/admin/<Name>.ptsx`, and
are rendered as `publr.admin.views.<Name>`. A view's name may not be one the admin or the
design system has, so name it after the plugin. An icon it names only at runtime goes in
its `ui/icons.txt`, one per line, as the admin's do.

A plugin's page is drawn like the core's: its view returns one of the admin's layouts,
`IndexPage` (a list), `FormPage` (one thing), `HubPage`, `CardPage` or `ListDetailPage`
(working through a set of things one at a time, as a merge does), and fills its slots
(title, parents for the crumbs, description, actions, meta, tabs, notice, filters, the
list, empty, footer; for a form the column, the aside and the danger zone, where
`ConfirmAction` asks before anything is undone). Two versions of something compare on
`CompareSides` and `CompareField`, their values shaped by `publr.admin.compare` (see
`admin.md`). The layout draws the chrome, the
sidebar, the crumbs and every gutter; the view sets no spacing of its own, and the build
refuses a page drawn otherwise. Who is signed in and the CSRF token are read where they
are needed as `Publr.request.session` (`name`, `email`, `csrf`); no view forwards them.

```tsx
import { IndexPage } from "@publr/admin/IndexPage.ptsx";

export function GuestbookEntries({ entries }: GuestbookEntriesProps) {
  return (
    <IndexPage
      title="Guestbook"
      description="What visitors wrote, newest first."
      empty={entries.length === 0 && <Empty>…</Empty>}
    >
      <Table>…</Table>
    </IndexPage>
  );
}
```

The route's handler renders it with `publr.admin.screen(&session, .ok, View, props)`,
the view's own data only, after `publr.admin.require` for the signed-in session.

- A settings page (`pub const settings_pages = [_]publr.plugin.SettingsPage{...}`): a
  label, an icon and the path of one of its own `get` routes, listed in the Settings
  sidebar for whoever may call the operation it names, and lit on that path and every
  path under it. A page that belongs under another's entry says so with
  `publr.admin.screen_with(&session, .{ .settings_path = "/admin/<other>" }, ...)`.
- A segment joined to the app picker (`pub fn app_picker_segment(session: *const
  publr.admin.Session, attached: bool) publr.admin.Error!?publr.admin.render.Node`): drawn
  after the picker as one control where the project has apps (`attached` true: draw it as
  the control's end, `StatusButton attach="end"`), on its own in the top bar where it has
  none. Null shows nothing.
- Where someone who must sign in goes (`pub fn sign_in_at(session: *const
  publr.admin.Session) anyerror!?[]const u8`): asked on the login page before the form and
  before a trusted issuer; the first plugin that names an address sends the browser there.
  Null leaves the login as it is. The page they asked for is the login's `return`
  (`publr.admin.query_param(session, "return")`), a path on the site; carry it on with
  `publr.admin.query_value` so they land there once signed in.
- Actions on the rows of another plugin's page (`pub const row_actions =
  [_]publr.plugin.RowAction{...}`): the page's slot as its owner names it, a label, a path
  where `{name}` stands for the row's name, a row kind (every row when empty) and the
  operation whoever sees it may call. The page's owner reads them for each row with
  `publr.admin.row_actions(session, slot, kind, name)`; neither plugin knows the other's
  code. An installed plugin's actions count too, when they lead into the admin
  (`/admin/...`) through an operation of its own.

A plugin can **keep state** for as long as the process runs: one `pub const State =
struct {...}`, made when the server opens the project (with `pub fn init(state: *State,
process: publr.plugin.Process) !void` when its fields need more than defaults; `deinit`
if it holds something to free) and never in a top-level `var`. An operation, a route or a
hook reaches it with `publr.plugin_states.of(ctx, @This())` from a context, or
`publr.plugin_states.from(project.plugin_states.?, @This())` from the project.

A plugin can also act on the process around the operations:

- `pub fn before_command(command: *publr.plugin_hooks.Command) !void` runs before any
  command, in name order: it may move the process into another folder
  (`std.process.setCurrentDir`) and take its own arguments off `command.args`, or change
  `command.db_path`. What is left runs as the command.
- `pub fn serving(serve: publr.plugin_hooks.Serving) !void` runs once `serve` listens, with
  the project and the port it got, before the first request. It may name the session
  cookie (`serve.project.session_cookie`), so two servers on one host keep their sign-ins
  apart. One that fails stops `serve`.
- `pub const operator_commands = [_]publr.plugin.OperatorCommand{...}`: a name and a
  handler, answered at `POST /_publr/<plugin>/<name>` only with the running server's
  operator key, which only processes of the same user on the machine can read
  (`<db>.serve`). `publr.operator.find` and `publr.operator.post` send one.

A plugin can **build on another**. It names what it depends on, each another plugin and,
after `@`, the versions it works with (exact, `1.2.3`, or caret, `^0.2`: the same leftmost
non-zero part, no older): `pub const depends_on = [_][]const u8{"newsletter@^1.2"}`.
A compiled-in plugin's requirements are checked when the binary is built (present, in
range, never round a loop); an installed one's when it is enabled. A plugin it only works
with when present goes in `compatible_with`, with the same ranges.

A plugin never imports another. It declares, in its own words, each operation of another
plugin it uses: the name, what it sends and the part of the answer it reads, listed in
`remotes`:

```zig
pub const remotes = [_]type{Subscribe};
pub const Subscribe = publr.plugin.Remote(
    "newsletter.subscribe",
    struct { email: []const u8 },
    struct { subscribed: bool },
);
// ctx.call(Subscribe, .{ .email = email }), or a hook on `Subscribe.name`
```

Every plugin's manifest carries the shapes of its own operations and the remote ones it
uses. When both plugins are compiled in, a remote shape that does not fit the real one is
a compile error naming the field. A plugin's own `interface.zig`, beside its `main.zig`,
is for its own files: `@import("newsletter")` inside newsletter.

A write may also say what it does outside the database once it is kept:
`pub fn committed(ctx: *sdk.Ctx, in: In, out: Out) sdk.Error!void` runs after its
transaction commits, only when no other write encloses it (core's `design.save_system`
loads the apps this way). Its failure is the call's answer; the write stays.

A plugin can run once the database opens (`pub fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void`),
as the system, after every declared type and field is in place: a setting the product
needs, a record that must exist. It runs at every start, so it checks before it writes.

What a plugin keeps for itself and nobody edits (carts, reservations, stock movements,
logs) is not content: it declares each kind as an internal record collection,
`pub const internal_records = [_]publr.plugin.InternalCollection{ .{ .kind = "movement",
.indexed = &.{"stock"}, .append_only = true } }`, and reaches them through the `internal`
operations (see [the CLI page](cli/internal.md)): its own records only, in the request's
app, with no permission to ask for. They never appear in the admin's content list.

A plugin can also keep values on the accounts themselves: `custom_fields` declares
custom field groups the way `content_types` declares types, each with its location
(`destination` user or media). They are created or brought up to date when the database
opens, their fields locked; a template reads the signed-in user's with
`Publr.request.userField('<group>.<field>')`.

The contract is checked when the binary compiles: a missing manifest, a bad
name, an undocumented operation, a hook on an operation that does not exist,
two plugins with the same name, all stop the build with a message naming the
plugin. Plugins are applied in name order, always. Tests live next to the code
and run with `zig build test`. The `plugins/` directory and `publr.zon` are yours:
Publr's own repository does not track them, so a fork can commit its plugins alongside
the core. `-Dplugins=<dir>` builds from another folder instead, with the `publr.zon`
beside it; a link in it counts, so one folder can gather plugins kept elsewhere.

### Translations

A plugin brings the admin's words in other languages as gettext PO files: `pub const
translations = [_]publr.plugin.Translation{ .{ .locale = "pl", .label = "Polski", .po =
@embedFile("i18n/publr/pl.po") } }`. `.domain` names whose words a file holds (`publr`,
or a plugin's name; the plugin's own when left out), so one plugin can translate the core
and others, and fill in what their authors left out. A plugin translating its own words is
first-party and wins; a `publr` file wins only when marked `.official`. A language pack is
a plugin of these alone, named `language_<code>` (`language_pl`). Site Health shows where
translations disagree and what each language still misses. See
[Admin](admin.md#the-admins-language).

### The Overview's "Your agent" tab

The Overview offers two ways to build: the person's own keys, and their own agent, whose tab
shows the commands that set an agent to work on this site. A plugin may show its own words
there instead (`pub const agents_tab = "<p>...</p>"`): HTML through the admin's sanitizer
profile, in a box named after the plugin, as `about` is. One plugin at a time; compiled in
only, for now. A demo running in a browser tab, which no agent can sign in to, says how to
build with an agent on the visitor's own machine.

### Variants and System settings tabs

A plugin may declare the one **variant dimension** (`pub const variants:
publr.plugin.Variants`): the words of the setting every field then has (`label`, `help`),
the words of the type setting for records not written in a variant (`untranslated`), and a
read of its own answering `variants`, each `{ code, label, address, main }` in order, the
main one first. The core draws the setting, stores and reads the values (see
[Content](content.md#languages-and-other-variants)), offers the switch in its editors and
serves each variant's pages under its address. The languages plugin is one: a language is
a variant.

A plugin may add a section to a tab of System settings (`pub const settings_tabs =
[_]publr.plugin.SettingsTab{...}`): the tab's name (`localization`) and label, a view whose
`draw(session)` returns the section drawn with the admin's components, and the operation
that decides who sees it. Plugins naming the same tab share it, their sections in plugin
order; the tab shows while any plugin adds to it. A refused save draws the tab again with
`publr.admin.settings_tabs.show_refused`. Compiled in only, for now.

### Its data, when it is removed

Removing a plugin moves it to the trash; its data stays, unless an administrator chose
otherwise on its page (Settings › Plugins › the plugin › Its data, or
`plugin choose_removal`). The page lists what the database holds for it: the content
types it owns with their records, its internal record collections, its custom field
groups. Ticked pieces go into the plugin's own trash entry and come back with it; nothing
is ticked until someone ticks it, so disabling, removing and adding a plugin back never
lose data by themselves.

A plugin that keeps more than core knows can clear it on the way out:

```zig
pub const uninstall = Forget; // one of its own writes, taking `remove`
```

`Forget` runs, while the plugin still runs, when it is removed with some of its data,
told which pieces go (`remove`: `type:<handle>`, `internal:<collection>`,
`fields:<group>`). If it fails, nothing is removed.
