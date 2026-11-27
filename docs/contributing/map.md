# The map

How Publr is put together, one idea at a time. Each idea is one small
diagram. At the end they are put together into the whole.

## Part 1: from the outside

### What Publr is

Editors write content in Publr; readers get the published part of it.
Everything is one program and one database file.

```mermaid
flowchart LR
    E[Editors] --> P[Publr] --> R[Readers]
    P --- D[(one SQLite file)]
```

### Three doors, one room

There are three ways to use it. They are fronts on the same thing: anything
one can do, the others can do too.

```mermaid
flowchart LR
    A[Admin<br/>in the browser] --> P[Publr]
    B[Command line<br/>publr ...] --> P
    C[HTTP API<br/>/api/...] --> P
```

### One action

An action is called an **operation**. It takes an input, does one thing,
gives an output. `record publish` takes a record id and answers with the new
status.

```mermaid
flowchart LR
    I["input<br/>{ id: abc }"] --> O[record publish] --> U["output<br/>{ status: published }"]
```

### The same action from each door

Each door just collects the input in its own way (a form, flags, JSON) and
runs the same operation.

```mermaid
flowchart LR
    A["Admin: the Publish button"] --> O[record publish]
    B["CLI: publr record publish --id abc"] --> O
    C["API: POST /api/record.publish"] --> O
```

### Operations come in families

About thirty operations, grouped by what they act on. `publr --help` lists
them; the API and the admin offer the same list.

```mermaid
flowchart TB
    root[operations] --> project[project<br/>init, impact]
    root --> user[user<br/>create, list, sign_in, ...]
    root --> type[content_type<br/>create, update, list, ...]
    root --> record[record<br/>create, save, publish, list, ...]
    root --> snap[snapshot<br/>list, restore, ...]
```

## Part 2: what happens when an operation runs

Every operation, from every door, goes through the same four steps.

### Step 1: who is asking

The door works this out (from the session cookie, or the `--as` flag on the
command line) before anything else happens.

```mermaid
flowchart LR
    subgraph callers [the caller is one of]
        N[nobody<br/>anonymous]
        U[a signed-in user<br/>holding roles]
        S[the system itself]
    end
```

### Step 2: may they

A few rules decide what this caller may do with this operation. A signed-in user
may call what one of its roles grants; roles are data, core's and the plugins'.
Plugins can add rules of their own.

```mermaid
flowchart LR
    N[anonymous] -->|read published,<br/>public content| Y1[allowed]
    N -->|anything else| X1[denied]
    E[editor] -->|work on content| Y2[allowed]
    E -->|manage users,<br/>change types| X2[denied]
    A[admin] -->|everything| Y3[allowed]
```

### Step 3: run it, all or nothing

The operation's code runs inside one database transaction. It either fully
happens or leaves no trace.

```mermaid
flowchart LR
    B[open transaction] --> R[run the operation] --> C{ok?}
    C -->|yes| K[commit]
    C -->|no| X[roll back]
```

### Step 4: tell whoever listens

When it is done, a named event goes out. Plugins can react (send a webhook,
rebuild a page).

```mermaid
flowchart LR
    O[record publish] -->|record.publish| L1[plugin A]
    O -->|post.transitioned| L2[plugin B]
```

### Put together: the pipeline

This pipeline is one function, `dispatch` in `src/sdk.zig`. Every call
goes through it. If you read one piece of code, read that one.

```mermaid
flowchart LR
    D1[door] --> W[1. who] --> M[2. may they] --> R[3. run in a transaction] --> T[4. tell listeners] --> D2[back to the door]
```

## Part 3: what the content is

### A content type

A content type is a schema: a name and a list of fields, each of a kind.
You make them in the admin (or the CLI); a plugin can declare its own in
code.

```mermaid
flowchart LR
    T[post] --> F1[title: string]
    T --> F2[slug: slug]
    T --> F3[body: richtext]
    T --> F4[cover: image]
```

### A record

A record is one piece of content of a type: a status plus a value for each
field.

```mermaid
flowchart LR
    E[record abc] --> TY[type: post]
    E --> ST[status: published]
    E --> DOC["document<br/>title = Hello<br/>slug = hello<br/>body = ..."]
```

### A record's life

Four statuses. Readers only ever see `published`. Every move can be undone;
`record purge` is the only thing that removes a record for good.

```mermaid
stateDiagram-v2
    [*] --> draft
    draft --> published: publish
    published --> draft: unpublish
    draft --> archived: archive
    published --> archived: archive
    archived --> draft: restore
    draft --> deleted: delete
    published --> deleted: delete
    archived --> deleted: delete
    deleted --> draft: restore
```

### Editing something that is published

Saving a published record does not change what readers see. The edit is
parked as a pending copy and the record is marked **changed**. Publish makes
the copy live; discard drops it. Unpublishing or archiving keeps the copy.

```mermaid
flowchart LR
    L["live document<br/>(what readers see)"] -.-> P["pending copy<br/>(your edits)"]
    P -->|publish| L
    P -->|discard| X[gone]
```

### History

Every time a live document is replaced, the old one is kept as a
**snapshot**. You can view them and restore one (which is itself a normal
edit).

```mermaid
flowchart LR
    S1[snapshot 1] --> S2[snapshot 2] --> S3[snapshot 3] --> L[live document]
```

### Put together: how that is stored

Three tables hold all content: the types, one row per record, and one row
per field value (under a slot: `live` or `pending`). Snapshots are beside
them. Users, sessions and settings have their own small tables. Columns are
in [Database schema](schema.md).

```mermaid
erDiagram
    content_types ||--o{ records : "shapes"
    records ||--o{ record_values : "one row per field value, per slot (live, pending)"
    records ||--o{ snapshots : "old documents"
```

## Part 4: the code

### The layers

The directories are the story in order. Each layer only calls the one below
it.

```mermaid
flowchart TB
    A["adapters/ (cli, rest, admin)<br/>the three doors"] --> B["sdk/<br/>the pipeline (dispatch)"]
    B --> C["operations/<br/>the ~30 operations"]
    C --> D["store/<br/>the tables: SQL and nothing else"]
    C --> M["model/<br/>pure rules: validation, documents, slugs, statuses"]
    D --> M
    D --> E["lib/db/<br/>SQLite"]
```

### Every file is one kind of thing

That is the rule the layout enforces, and `tidy` checks it (`scripts/tidy/kinds.zig`).
The directory tells you what a file is, what it may import, and how it is tested:

| kind | directory | is | may import | tested by |
|---|---|---|---|---|
| model | `model/` | pure rules: data in, data out. No database, no HTTP | `std`, other model files | unit tests, table-driven |
| store | `store/` | one table per file; functions are statements | `lib/db/`, `model/` | against a fixture database |
| operation | `operations/` | orchestration: grant, store, model, events; never SQL | `sdk/`, `store/`, `model/` | scenarios through `dispatch` |
| adapter | `adapters/{cli,rest,admin,apps}/` | outside format in, operation call, outside format out; never the store | `sdk/`, operations | request in, response out |
| engine | `template/` | the `.publr` template language: read into a tree, typed, rendered against a context the apps adapter supplies. No database, no HTTP | `std` | unit tests against a stand-in context |
| public SDK | `publr/` (+ `publr/plugin/`) | what plugins and app middleware build on: the definers, money and values, events, contracts; core aliases it | `sdk/`, `model/`, `lib/` | unit tests |
| pipeline | `sdk/` (+ `sdk/plugin/`) | dispatch, callers, grants, hooks, the plugin contract | `lib/`, `model/` | unit tests |
| wiring | `server/` | starting up: open the database, the registry of everything, the route table, the project handle, `serve`, `build`, wasm | everything | the http flow tests |
| library | `lib/{db,http,auth}/` | mechanisms that know nothing about content: SQLite, an HTTP server, password hashing | each other, `std` | unit tests |

Two adapters are allowed to read the store, because they are where a request
becomes a caller: `adapters/rest/identity.zig` (cookie to caller) and `adapters/cli.zig`
(`--as` to caller).

The fourth door faces the other way: `adapters/apps/` is what readers get, each app's
templates rendered through `record` operations (anonymous when shared, as the
signed-in visitor per request), built to files and rebuilt from the dependency index
(`lib/deps/`) when a `record.*` event raises a key (`operations/project/changes.zig`).
A request goes to the app mounted where it asked. See [Apps](../apps.md).

### Beside the layers

`lib/auth/` is used by the doors to work out who is asking; `lib/http/`
carries the API and admin doors; `sdk/plugin/` feeds rules, listeners and
types into the pipeline. Installed plugins reach it at run time instead:
`server/sandboxed_plugins/` runs them in the sandbox (`lib/wasm/`) behind `sdk/sandboxed_plugins.zig`, and
their calls come back through the same dispatch. Starting up lives in `main.zig`, `server/serve.zig`, `server.zig`
(`server/wasm.zig` is the same program as WebAssembly).

```mermaid
flowchart LR
    AUTH["lib/auth/<br/>passwords, CSRF,<br/>throttling"]
    HTTP["lib/http/<br/>a plain HTTP server,<br/>knows nothing of Publr"]
    PLUG["sdk/plugin/<br/>what a plugin may add,<br/>merged at compile time"]
```

### The whole thing

All of the above in one picture: the doors on top, fed by `lib/auth/` (who is
asking) and carried by `lib/http/`; the pipeline in the middle, fed by
`sdk/plugin/`;
the operations, the content rules and the database below.

```mermaid
flowchart TB
    subgraph doors [adapters/]
        CLI[cli/]
        REST[rest/]
        ADMIN[admin/]
    end
    HTTP[lib/http/] --> REST
    HTTP --> ADMIN
    AUTH[lib/auth/] -.who is asking.-> doors
    doors --> DISPATCH["sdk/ dispatch<br/>who, may they, transaction, listeners"]
    PLUG[sdk/plugin/] -.rules, listeners, types.-> DISPATCH
    DISPATCH --> OPS[operations/]
    OPS --> MODEL[model/]
    OPS --> STORE[store/]
    STORE --> MODEL
    STORE --> DB[lib/db/ + schema.sql]
```

### One button, all the way down

The "Publish changes" button in the admin, through every layer:

1. `adapters/admin/content.zig:action` reads the form and checks it came from our own
   page (same origin, CSRF token).
2. It calls `dispatch` with `record.publish` and `{ id, expected_version }`.
3. `dispatch` (`sdk.zig`) asks the rules (an editor may write records),
   opens a transaction, calls the operation.
4. `record.publish` (`operations/record/lifecycle.zig`) loads the record, checks
   the parked slug is still free, keeps the old live document as a snapshot
   (`store/snapshots.zig`), renames the `pending` slot to `live`
   (`store/values.zig`), bumps the record with `changed` off
   (`store/records.zig`).
5. Commit, `record.publish`'s own event goes to its `on` hooks, redirect back to the record.

## Part 5: reference

### Every file, one line

Grouped by kind. Lines are the whole file, tests included.

#### Entry points
| File | Lines | What |
|---|---|---|
| `main.zig` | 228 | `publr [--db] <cmd>`: `serve`, `build`, `plugin prepare`/`check`/`sdk`, `site`, `agents`, `check-apps` or the CLI |
| `server/serve.zig` | 510 | `publr serve`: open the database and the apps, run the HTTP server loop with the rebuild queue between ticks; refuse to run beside another server, leave the session the CLI finds |
| `server/build.zig` | 221 | `publr build`: every app as files |
| `server/plugin_sdk.zig` | 60 | `publr plugin sdk`: the SDK plugins of this release build against, carried for a compiler outside the binary |
| `server/agents.zig` | 37 | `publr agents`: the guide for agents (`docs/agents.md`), where the SDK comes from, the permission catalog |
| `server/apps_host.zig` | 135 | The apps `serve` holds: read from the folder (or the build's own), opened, loaded again when its files change or on `apps load` |
| `server/apps_watch.zig` | 110 | The apps folder watched while `serve` runs: a change loads the apps again once it holds still |
| `server/apps_load.zig` | 126 | `publr apps load` and `/_publr/apps/load`: the apps swapped into the running server, or checked here |
| `server/operator.zig` | 304 | While `serve` runs: its session beside the database, the CLI sending it commands (`/_publr/cli`), and running a command there or here (`Commands`) |
| `server/plugin_build.zig` | 365 | `publr plugin prepare` and `plugin check --file`: a plugin's build around a compiler outside the binary, its source checked, its manifest read from the module in the sandbox and written in |
| `server/plugin_routes.zig` | 191 | Compiled-in plugins' routes, registered before the core's and refused when a prefix covers a core route; the sender's context, a plugin's own sign-in |
| `server/plugin_states.zig` | 90 | Every compiled-in plugin's `State`, made when the server opens the project, freed when it closes |
| `server/plugin_hooks.zig` | 99 | Compiled-in plugins around the process: `before_command`, `serving`, operator commands behind the operator key |
| `server.zig` | 111 | `Server`: open the database, apply schema and plugin bootstrap, open the dependency index, hold auth state |
| `server/wasm.zig` | 325 | The same program as a wasm reactor: init, import a db, answer one request |
| `p.zig` | 61 | The library root, private: every module, what Publr's own binaries, generated roots and the installed plugins' guest root import as `p` |
| `sdk/public_root.zig` | 263 | The root check: every name of `publr/root.zig`, and every type its fields, decls and signatures reach, is defined under `publr/` (or in `std`, `publr_api`, `publr_text`, `publr_ai`); `publr` forwards exactly those names, `db` the one exception |
| `operations/plugin/sdk_offered.zig` | 94 | The SDK's names as `sdk:` items of `plugin surface` (root names and their members), and their deprecations |
| `publr.zig` | 95 | What plugins and app middleware import as `publr`: forwards `publr/root.zig`'s names from `p`, reaching nothing else |
| `publr/root.zig` | 459 | The public names, each defined in a file under `publr/`, documented where they are named |
| `publr/version.zig` | 17 | The release this is (a release writes it) |
| `server/registry.zig` | 74 | Core + plugin operations/namespaces/policies/hooks/types/roles, the `SDK`, the status and role registries, bootstrap |
| `server/routes.zig` | 288 | The route table (`/api/auth/*`, `/api/health`, admin, rest, the apps as the fallback) and a `testing.Flow` that drives the full router |
| `server/project.zig` | 130 | `Project`: the per-process handle handlers get (`connection`, `auth`, static dir, the loaded apps, the domain), which app a request is for, the session cookie's domain |
| `server/sandboxed_plugins.zig` | 248 | The installed plugins the server holds: the sandbox's runtime, every plugin loaded from its row and file, the hook and operation index, the roles plugins declare |
| `server/sandboxed_plugins/interface.zig` | 760 | The `sdk.plugins.Plugins` every context carries: find and run a plugin's operation, run its hooks, read a module to install, reload after a change, open and end a request on the plugins |
| `server/sandboxed_plugins/invoke.zig` | 873 | One call into a plugin, as itself and within its limits, its input as it comes (`Passed`: JSON text, or as another plugin handed it over), or one hook over many items (`invoke_many`); the host functions it may call (`publr_emit`, `publr_log`, `publr_enqueue`) |
| `server/sandboxed_plugins/said_memory.zig` | 178 | A plugin's memory said in the log: an entry that ran out of it, a request that left it more than half full, each with the largest collection it made |
| `server/sandboxed_plugins/described.zig` | 207 | A plugin's description of a type's layout: its parts (numbers, texts, enums, lists, pointers, optionals, structs, unions, free-form values) and how many bytes each takes |
| `server/sandboxed_plugins/given.zig` | 386 | A value a plugin hands over, copied out of its memory with every address and length checked, the bytes read bounded and its addresses followed 64 deep at most |
| `server/sandboxed_plugins/given_typed.zig` | 370 | That value read straight into one of core's own types (an operation's `In`): `null` as `null`, numbers and texts by their kind |
| `server/sandboxed_plugins/laid.zig` | 280 | A value built for a plugin in the layout it described, in zeroed memory, addressed from 0 until the plugin makes room |
| `server/sandboxed_plugins/laid_typed.zig` | 283 | One of core's own values (an operation's `Out`) laid out straight from the struct |
| `server/sandboxed_plugins/transfer.zig` | 379 | A value moved from one plugin's layout to another's with nothing in between, fields, enum tags and a union's alternatives by name |
| `server/sandboxed_plugins/held.zig` | 299 | A value core keeps between two plugins: copied whole out of the sender, one piece of bytes |
| `server/sandboxed_plugins/shaped_call.zig` | 308 | `publr_call_shaped`: a plugin's call read into a compiled-in operation's `In` and its `Out` laid out, or handed on whole to another plugin's operation |
| `server/sandboxed_plugins/shaped_entry.zig` | 291 | One entry of a plugin (operation, hook, modifier, job, rule, field kind) run with its envelope built in the plugin's layout |
| `server/sandboxed_plugins/described_parser.zig` | 397 | That description read into its parts: every size, count and name bounded, a part naming one it is inside of only where it lies at an address of its own |
| `server/sandboxed_plugins/described_reader.zig` | 58 | The description's bytes taken in order, never past their end |
| `server/sandboxed_plugins/described_checks.zig` | 305 | What a description's parts must be to one another, checked once all are read; which parts hold a union |
| `server/sandboxed_plugins/given_json.zig` | 374 | That value written as JSON, for what core keeps as JSON and the outer edge: a keyed list as an object, a union by its alternative's name, a decimal as its text |
| `server/sandboxed_plugins/given_object.zig` | 189 | A struct of core's read from an object a plugin handed over: fields by name, defaults, a key per dimension gathered |
| `server/sandboxed_plugins/laid_json.zig` | 383 | That value built from JSON: what core keeps as JSON, the outer edge, a field's default |
| `server/sandboxed_plugins/transfer_scalars.zig` | 105 | A number, a decimal or a text read out of one layout for another |
| `server/sandboxed_plugins/transfer_shapeless.zig` | 89 | A free-form value and a union moved between two layouts |
| `server/sandboxed_plugins/shaped_read.zig` | 126 | What a call says about itself, copied out of the plugin and checked: its description, its unions, an event's payload and a job's input written as JSON once |
| `server/sandboxed_plugins/shaped_answer.zig` | 199 | `publr_shaped_take`, `publr_answer`: an answer waiting for the room the plugin makes, and an entry's answer copied out while it is still there |
| `server/sandboxed_plugins/drawing.zig` | 225 | `publr_frame`: the frame a plugin's page is for and who is looking, laid out for its view; `publr_translate`: one message of a view in the person's language |
| `server/sandboxed_plugins/drawing_page.zig` | 270 | `publr_draw`: a whole page a plugin's view described, drawn in one call: each component's props read where they lie into the design system's own `Props`, every address, name, prop and size checked |
| `ui/drawn.zig` | 135 | One component an installed plugin may draw, by name, its props from whoever reads them |
| `ui/drawn_placed.zig` | 440 | A described page put together: each placeholder replaced by what was drawn for it, at any depth, attributes moved onto the root drawn; bounded in size, depth and replacements |
| `sdk/plugin/view_wire.zig` | 175 | What a view hands over to be drawn: the page and component structs, a component's props described by the plugin's build, the placeholder |
| `server/sandboxed_plugins/loaded.zig` | 267 | One installed plugin: its module, manifest, grants with their flags, own types, limits, each entry's layout read once, and its instance: kept while a request is open on the host, dropped with the request, or at once when a call spoils it |
| `server/sandboxed_plugins/batched.zig` | 233 | `publr_invoke_batch`, `publr_item`: one hook run for many items in one call into the module, each item's end and answer kept apart; a module built before batches is run item by item |
| `server/sandboxed_plugins/hooks_many.zig` | 118 | Installed `before` and `after` hooks over the inputs of a bulk write: each plugin's hook entered once for all still going, and only for the inputs it is about (`interface.zig`, `hears`) |
| `server/sandboxed_plugins/projected.zig` | 150 | What an `on` hook waits in the queue with: of an event, the fields the hook's own type names, read by its layout where the value lies and written as JSON once |
| `server/sandboxed_plugins/modifying.zig` | 257 | Installed modifiers over the values of one apply, held laid out, in turn, in working memory given back after each: the answer laid over the values where they lie, a value of another type handed over alone; a modifier that fails refuses the apply |
| `server/sandboxed_plugins/applied.zig` | 319 | The values of one apply as core holds them between two modifiers: one piece, each value in its owner's layout; made from an installed plugin's memory or from core's own structs, read back the same way |
| `server/sandboxed_plugins/applied_over.zig` | 326 | A modifier's answers laid over the held values: one piece in the values' layout with the modifier's own fields added; an answer that cannot lie over its value leaves it |
| `server/sandboxed_plugins/applied_typed.zig` | 216 | The held values as a compiled-in modifier takes them: read into its structs, its answer laid over them like any other |
| `server/sandboxed_plugins/applied_trees.zig` | 158 | Held values whose shape comes with the data: what the outer edge sent as JSON, what core read from storage |
| `server/sandboxed_plugins/merged.zig` | 254 | What a modifier wrote laid over the value it was given, where both lie: fields by name, anything else replaced, shape-with-data parts as trees |
| `server/sandboxed_plugins/merged_lists.zig` | 259 | The lists of a merge: item by item, by each item's `id`, a keyed list by its keys |
| `server/sandboxed_plugins/merged_tree.zig` | 213 | Two trees merged by the same rules, for parts whose shape comes with the data and for hooks' changes |
| `server/sandboxed_plugins/merged_shape.zig` | 425 | The layout the values take once a modifier's answer lies over them: their own, with the fields only the modifier has |
| `server/sandboxed_plugins/merged_added.zig` | 119 | A field only a modifier has, copied into that layout as one that may hold nothing |
| `server/sandboxed_plugins/merged_rooms.zig` | 141 | Every size, offset and alignment of a layout core puts together itself |
| `server/sandboxed_plugins/described_text.zig` | 264 | A description written again from its parts: one part on its own, or a layout core put together |
| `server/sandboxed_plugins/given_tree.zig` | 298 | A value a plugin handed over as the tree it stands for, read where it lies |
| `server/sandboxed_plugins/shaped_apply.zig` | 147 | A plugin's `ctx.mod`: its values copied out once, held laid out through `mod.apply`, laid back in its layout |
| `server/sandboxed_plugins/scenarios_instances.zig` | 250 | A plugin's instance on the fixture `keeper`: one for a request, none left for the next, dropped on a trap, nested work counted against the call's budget, a bulk write's hook entered once, a modifier out of its budget refusing the apply |
| `server/sandboxed_plugins/files.zig` | 224 | Modules on the data drive by their hash, uploads arriving in pieces, the sweep of files no row names |
| `server/sandboxed_plugins/scenarios.zig` | 518 | The sandbox end to end on the fixture plugins: install, call, revoke, update, remove, the admin's pages |

#### template/ (the template engine)
| File | Lines | What |
|---|---|---|
| `template.zig` | 1897 | `Program`: every template read, the route and island tables, the classes; `load` with its limits and diagnostics; the engine's tests against a stand-in context |
| `template/ast.zig` | 338 | What a template is once read: typed expressions, nodes, the template's facts |
| `template/routes.zig` | 198 | `content/` paths to route patterns, matching, substitution |
| `template/compile.zig` | 623 | The compiler's context and driver: names, paths, island keys, node lists |
| `template/frontmatter.zig` | 1094 | Imports and the Publr API reads, with the static/dynamic inference |
| `template/markup.zig` | 615 | Tags, attributes, children, `/_app/` URLs, minifying |
| `template/blocks.zig` | 165 | `{...}` in child position: loops, conditionals, values |
| `template/components.zig` | 745 | Component call sites: embed, island, PJSX |
| `template/expression.zig` | 946 | The typed expression parser and the text helpers |
| `template/render.zig` | 779 | `Renderer(Ctx)`: the tree evaluated against a context |
| `template/impact.zig` | 484 | Which pages and fragments of a program read a type |
| `template/imports.zig` | 234 | A template's `.publr` imports, and where one leads: inside the app, or out to the apps folder |

#### adapters/apps/ (the fourth door: readers)
| File | Lines | What |
|---|---|---|
| `adapters/apps.zig` | 1049 | The dispatcher (the app mounted where a request asked, then its assets, islands or pages), the caching policy, `ETag`/304; the apps' integration tests |
| `adapters/apps/spec.zig` | 361 | Every compiled-in app as data, read off the generated `apps` module at compile time: name, mount, roles, templates, assets, tokens, interactive components, middleware |
| `adapters/apps/state.zig` | 439 | `App`: one app loaded, its stylesheet from the JIT, its fingerprint and assets, its address and output folder; `check_apps` |
| `adapters/apps/folder.zig` | 318 | Apps read from a project's folder at runtime: `app.zon`, templates, the build's checks; compiled parts from the build's app of the same name |
| `adapters/apps/imported.zig` | 116 | The templates an app imports from outside its folder, joined to its own |
| `adapters/apps/load.zig` | 47 | Every app loaded into the project, and released |
| `adapters/apps/fingerprint.zig` | 263 | The generated assets' fingerprint and the build stamp |
| `adapters/apps/context.zig` | 1027 | The Publr API a template reads, over `record.list|get` (anonymous when shared, the visitor per request, nobody to an app whose roles it lacks); `Deps` recording |
| `adapters/apps/pages.zig` | 266 | A page served from the build or rendered now; the app's 404 |
| `adapters/apps/islands.zig` | 268 | One fragment, or a batch of dynamic ones |
| `adapters/apps/assets.zig` | 55 | `<mount>/_app/<path>`: generated code and the stylesheet, from memory |
| `adapters/apps/public.zig` | 302 | `public/` at the mount: copied to the build's root, served from disk, the sitemap |
| `adapters/apps/build.zig` | 444 | The static build of one app or all, the sitemap |
| `adapters/apps/artifacts.zig` | 127 | Built files: their names in the index (`<app>:<url>`), their paths, reading and writing them |
| `adapters/apps/rebuild.zig` | 314 | The project's rebuild: `refresh` at startup, `flush` between ticks, each batch's artifacts sent to their app |
| `adapters/apps/rerender.zig` | 233 | One artifact rendered again, removed or forgotten; a changed record's own pages |
| `adapters/apps/middleware.zig` | 160 | An app's `middleware.zig` asked before core answers, its answer written as given |
| `publr/app_middleware.zig` | 240 | What an app's `middleware.zig` sees (the path inside the app) and the answer it gives: `publr.Request`, `publr.Response` |
| `adapters/apps/islands.js` | | The island loader: `<publr-island>` fetches its fragment and replaces itself |
| `operations/project/changes.zig` | 91 | The `on` middleware: every `record.*` event raises the record's keys in the index |
| `lib/deps.zig` | 16 | The face on `publr_deps` |
| `lib/time.zig` | 32 | Dates as text |

#### model/ (pure)
| File | Lines | What |
|---|---|---|
| `model/field.zig` | 299 | Field kinds, options, `Def`, validation of field definitions |
| `model/field/given.zig` | 146 | A field's overrides as a plugin gives them (`publr/field_options.zig`) made into core's `Def` parts |
| `publr/field_options.zig` | 256 | `publr.field.Overrides`: what one field of `record.define`'s `.fields` takes |
| `model/content_type.zig` | 153 | A content type `Def`, its validation, JSON encode/decode, id from handle |
| `model/validate.zig` | 416 | A JSON document against a type's fields: problems |
| `model/key_page.zig` | 90 | A page of a list held in memory, in the order of its keys: the window after `after` and the next page's key |
| `model/document.zig` | 487 | A document as rows and back: `flatten` (object to rows, dotted paths, ordinals), `assemble` (rows to object), title and slug rules, path lookup |
| `model/json_fields.zig` | 180 | A JSON object cut to some of its fields, and one text field read from it, where the text lies: nothing is built in between |
| `model/status.zig` | 189 | The status registry (`draft/published/archived/trashed`, transitions), extensible by plugins |
| `model/convert.zig` | 159 | Value conversion when a field changes kind |
| `model/evolution.zig` | 200 | Diff two type definitions into a plan (removed, converted, needs rewrite) |
| `model/account.zig` | 65 | Email normalisation, display-name rule |
| `model/role.zig` | 373 | A role (name, label, grants), grant matching (`record.*`, `!record.purge`), the core roles, merging the plugins' |
| `model/permission.zig` | 310 | The permission catalog: keys, sentences, tiers and the operations each stands for; what every plugin gets and what none ever does |
| `model/sandboxed_plugin.zig` | 376 | A plugin's manifest as data; what it asks for and at which tier, what installing grants, when an update waits, its limits |
| `model/app.zig` | 312 | An app's `app.zon`: its name and label, its plugins, mounts, their validation, which app a host and path go to, an app's address |
| `model/view.zig` | 204 | A saved view's filters: the JSON shape, its bounds, `me` and relative days |
| `model/filter.zig` | 473 | The filter registry: keys, labels, operators, what each takes, how a clause constrains the list |

#### store/ (SQL only)
| File | Lines | What |
|---|---|---|
| `store/tables.zig` | 40 | The two document domains and the tables each owns (`records`, `terms`) |
| `store/definitions.zig` | 280 | A definitions table (`content_types`, `taxonomies`), generic over the domain: insert/update/get/list/delete |
| `store/documents.zig` + `documents/list.zig` | 260 + 330 | A documents table (`records`, `terms`): the `Record` row, insert/get/save/set_status/delete/rename, and the composed list query |
| `store/document_values.zig` | 400 | A values table + its search index: write flattened rows per slot, read, promote, lookups, delete by field |
| `store/content_types.zig`, `store/records.zig`, `store/values.zig` | 60, 230, 350 | The record domain's instantiations, with their tests; `values.zig` also writes the assignments of `terms` fields |
| `store/taxonomies.zig`, `store/terms.zig`, `store/term_values.zig` | 50, 250, 60 | The term domain's instantiations; `terms.zig` adds the parent: `parent_of`, `set_parent`, `ancestors`, `nodes` |
| `store/record_terms.zig` | 380 | `record_terms`: a record's membership per slot and field, ancestors included; promote, rebuild after a move |
| `store/snapshots.zig` | 182 | `snapshots` table: take/get/list/prune |
| `store/views.zig` | 226 | `views` table: a user's saved views, insert/get/list/update/delete |
| `store/next_id.zig` | 49 | A table's next time-ordered id, after the greatest one it holds for the same millisecond |
| `store/sandboxed_plugins.zig` | 161 | `sandboxed_plugins` table: one row per installed plugin, get/list/count/put/delete |
| `store/users.zig` | 414 | `users` table: insert/find/list/tokens/password, the account's roles read with it |
| `store/user_roles.zig` | 106 | `user_roles` table: the roles an account holds, set whole; how many hold one |
| `store/sessions.zig` | 324 | `sessions` table: create/validate/slide/destroy, per-user cap |
| `store/identities.zig` | 220 | `identities` table: a provider's user linked to an account; find/insert/touch/of_user/delete |
| `store/settings.zig` | 54 | `settings` key/value get/set |

#### operations/ (the features)
| File | Lines | What |
|---|---|---|
| `operations/heartbeat.zig` | 63 | `heartbeat check` |
| `operations/project.zig` | 159 | `project init` (first admin), `project status` |
| `operations/project/impact.zig` | 213 | `project impact`: what the index holds for a record or its type |
| `operations/project/move_app.zig` | 201 | `project move_app`: a renamed app's types (where they live, who they are shared with) and design records handed to its new name, or made Global |
| `operations/role.zig` | 48 | `role list` |
| `operations/user.zig` | 540 | `user create/list/password_link/set_password` |
| `operations/sign_in.zig` | 188 | `user sign_in/sign_out`: throttle, session |
| `operations/status.zig` | 51 | `status list` |
| `operations/document.zig` + `document/*.zig` | 60 + 1600 | One implementation of document CRUD for both domains: `access` (grant-checked load, statuses), `document` (parse, assemble, unique slug, revisions), `crud` (create/get/save/list/referrers/validate), `lifecycle` (transition/publish/discard/delete/purge), `definition` (find, create/update/get/list/delete/validate with evolution) |
| `operations/content_type.zig` | 250 | `content_type create/update/get/list/delete/validate`, declared over the record domain |
| `operations/record.zig` | 900 | The record domain (`document.Domain`), `record create/get/save/list/referrers/validate` declared over it, the record rules (kinds, `terms` fields name a taxonomy, assigned terms exist) + the tests |
| `operations/record/lifecycle.zig` | 227 | `record transition/publish/discard_changes/delete/purge`, declared |
| `operations/record/reach.zig` | 366 | `record reach`: why a record is out of the caller's reach (`access`, `not_shared`, `deleted`) and the payload that stands in its place; tests of what an app reaches |
| `operations/health.zig` + `health/cases.zig` | 350 + 270 | `health list/count/keep/unlink`: Site Health's broken references, worked out from the references (`store.values.suspect_links`), kept ones in `health_kept` |
| `operations/health/translations.zig` | 380 | `health translations/choose_translation/missing_translations`: disagreements a page at a time read through `Ctx.translations`, picks under the `translation_choices` setting |
| `operations/health/coverage.zig` | 80 | `health coverage`: how much of each domain's messages each language translates, a page at a time |
| `operations/taxonomy.zig` | 330 | `taxonomy create/update/get/list/delete/validate`, declared over the term domain |
| `operations/term.zig` + `term/lifecycle.zig` | 560 + 230 | The term domain, `term create/get/save/list/tree/validate` with the parent rules, and the lifecycle with purge refusing children and members |
| `operations/internal/computed.zig` + `computed_reads.zig` | 450 + 180 | Computed fields of internal records kept fresh: checked on every read, worked out by the owner's function and the field's mod with no reader, stored, and noted in `lib/deps` with what they read |; `computed_reads` gathers what the work read, until when it holds, and the stamp of the code and modifiers that made it
| `operations/internal/computed_operations.zig` | 235 | `internal sum` (a whole number added up by the database, values freshened a page at a time) and `internal holds_until` |
| `operations/record/fixture.zig` | 18 | The `post` type the record tests write against |
| `operations/snapshot.zig` | 211 | `snapshot list/get/take/restore/prune` |
| `operations/view.zig` | 339 | `view list/get/create/update/delete`: private, owner-bound |
| `operations/plugin.zig` | 402 | `plugin list/get/upload/add/enable/disable/update/rollback/cancel_update/grant/revoke/deny/set_grant/remove`: administrators only |
| `operations/plugin/lifecycle.zig` | 303 | The checks before a module is taken; add, enable, disable, remove, grant and revoke |
| `operations/plugin/versions.zig` | 132 | The next version applied, the previous one kept and rolled back to, the grants a version carries over |
| `operations/plugin/state.zig` | 216 | A plugin's row read and written as data; its requests with where each stands |
| `operations/plugin/detail.zig` | 243 | What the plugin operations answer, and their documented examples |

#### Adapters
| File | Lines | What |
|---|---|---|
| `adapters/cli.zig` | 1091 | Args to `In`, dispatch, print `Out`, `--help` from the op docs, `--as` to caller |
| `adapters/cli/sandboxed_plugins.zig` | 223 | An installed plugin's commands: flags to JSON by its manifest's field shapes, `--help` from its manifest |
| `adapters/rest.zig` | 256 | `GET/POST /api/:name` to the op; query/body to `In`; its http test |
| `adapters/rest/identity.zig` | 173 | Who is making an HTTP request: cookie to caller, CSRF guard for writes, the `Ctx` a handler dispatches with |
| `adapters/rest/auth.zig` | 247 | `/api/auth/*` handlers (sign-in, sign-out, set-password, session) and their http test |
| `adapters/admin.zig` | 356 | Admin routes, `Session`, `require`/`accept`/`param`, `fail`, the admin http test |
| `adapters/admin/page.zig` | 113 | Plain HTML page writer with escaping |
| `adapters/admin/fields.zig` | 190 | Field defs to form inputs to JSON document |
| `adapters/admin/auth.zig` | 212 | Setup, login, logout pages |
| `adapters/admin/definitions.zig` | 430 | A definitions list and head, generic over the domain: create, settings, delete |
| `adapters/admin/types.zig`, `adapters/admin/taxonomies.zig` | 70, 30 | The content type and taxonomy instantiations |
| `adapters/admin/editor.zig` | 700 | The document editor, generic over the domain: pages, fragments, autosave verdicts, reshapes, status actions |
| `adapters/admin/terms.zig` | 220 | A taxonomy's terms page (the tree) and the term editor with its Parent aside |
| `adapters/admin/type_fields.zig` | 400 | A type's fields page, the kind picker, the field form |
| `adapters/admin/type_fields/write.zig` | 350 | A field added, changed, removed or moved: the definition posted back through `content_type update` |
| `adapters/admin/content.zig` | 25 | Records: the entry |
| `adapters/admin/content/form.zig` | 280 | The record editor instantiation: the terms aside (RecordTerms), the dependency dialog, the drawer's picker |
| `adapters/admin/content/list.zig` | 475 | The content list: the view shown, its filters, the rows |
| `adapters/admin/content/pills.zig` | 502 | The filter bar: the type pill, one pill per filter, the Filter menu |
| `adapters/admin/content/filters.zig` | 453 | Filters between the address, the saved view's JSON and the list input |
| `adapters/admin/content/views.zig` | 108 | Saving the filters as a view: create, save, rename, delete |
| `adapters/admin/app_scope.zig` | 310 | Which app the admin shows: the viewer's choice in a cookie and the switcher; narrowed, the admin reaches what the app does |
| `adapters/admin/type_placement.zig` | 140 | A type's settings: where it lives, who it is shared with, Public or Private, drawn and read back |
| `adapters/admin/health.zig` | 315 | Settings › Site Health: the cases and their actions, one row or the ticked ones |
| `adapters/admin/health/translations.zig` | 160 | Site Health › Translations: disagreements with a pick each, coverage, the missing `.pot` |
| `adapters/admin/top_bar.zig` | 44 | The top bar's items: each compiled-in plugin's, then the app switcher |
| `adapters/admin/nav.zig` | 158 | The Content sidebar: recent, private and saved views, by status, by type |
| `adapters/admin/revisions.zig` | 214 | Versions explorer + restore |
| `adapters/admin/plugins.zig` | 378 | Settings > Plugins: one list with enable, disable, update and remove; the enabling and update reviews; a plugin's page with grant, revoke and roll back |
| `adapters/admin/plugins/rows.zig` | 146 | Plugin requests as rows low to high, with a switch for each key and flag; what a posted form switched |

#### Infrastructure
| File | Lines | What |
|---|---|---|
| `sdk.zig` | 700 | `Registry`, `SDK(registry)`: `dispatch`, `admit`, `run` in a tx, one error boundary (`as_outcome`), hooks, events; `may` (whether a caller may call an operation) and `reaches_admin` (whether it may use the admin) |
| `sdk/operation.zig` | 330 | What an operation type must declare; `resource_of(in)`; `Docs(In)`; name helpers (`namespace.verb`, `app.<feature>.verb`) |
| `sdk/operation/values.zig` | 290 | The rule that `In` and `Out` hold values: a text field whose example is a JSON object or array, or whose doc line says JSON, is a compile error naming the operation and the field; `verbatim` names another system's text passed through (an HTTP body) |
| `sdk/context.zig` | 104 | `Ctx`: caller, db, io, arena, auth, clock, events |
| `sdk/caller.zig` | 174 | `Caller` union (anonymous, user with its roles, system, token, machine, plugin) |
| `sdk/grant.zig` | 267 | `Grant`: allow/deny, type and status filters, transitions, row filter |
| `sdk/authorize.zig` | 318 | The core policy (anonymous reads live+public, a user what its roles grant); runs plugin policies |
| `sdk/hooks.zig` | 89 | Hook stages (`pre`, `before`, `after`, `on`) and event shapes |
| `sdk/plugin.zig` | 647 | What a plugin module may export; `Merged(plugins)`; compile-time validation |
| `sdk/plugin/sandboxed.zig` | 320 | What a plugin declares to run in the sandbox (permissions, limits), its entries, what may not be sandboxed |
| `sdk/plugin/manifest.zig` | 190 | The manifest written into a plugin's module, built from its declarations |
| `sdk/plugin/field_kinds.zig` | 327 | A plugin's `publr.field.kind` as core keeps it: the descriptor, its checks, text and editor, compiled in or installed |
| `sdk/plugin/bound.zig` | 238 | A plugin as core reads it: `Bind` pairs its `define` with its words, `has`/`get` read its options |
| `sdk/plugin/bound/declared.zig` | 393 | The options `get` answers in core's shapes: content types, collections, hooks, pages, kinds, namespaces |
| `sdk/plugin/flows.zig` | 262 | A record's flow as core keeps it, and the statuses a plugin adds to other plugins' flows |
| `sdk/plugin/records.zig` + `records/fields.zig`, `records/listed.zig` | 350 + 343, 148 | A plugin's records as core stores them: each content type's declaration, each internal record's collection, the `.register_fields` groups; each field's definition from its Zig type and overrides; the field a record is listed by, its statuses and its flow |
| `sdk/plugin/menus.zig` | 240 | A plugin's menu items and icons as the admin reads them, checked |
| `sdk/plugin/location_rules.zig` | 135 | A plugin's location rules as core runs them, compiled in or installed |
| `sdk/plugin/taxonomies.zig` | 193 | Core's reading of taxonomies: each a plugin declares as the type core stores (`def_of`), its registrations checked, and those registrations as the site keeps them: whose each is, which types its patterns pick |
| `sdk/plugin/dimensions.zig` | 226 | Core's reading of a plugin's dimensions: each list resolved to its own operation, each dimension as data (`declared`, `declared_of`, `Native`) |
| `sdk/plugin/guest.zig` | 363 | The SDK inside the sandbox: `SandboxApi`, the installed call behind `publr.Ctx`, proxied to the host in the plugin's own structs, the exports generated for a plugin, its manifest among them |
| `sdk/plugin/shape_wire.zig` | 260 | A struct's layout described at build time, so the host reads values where they lie and writes answers in the plugin's own memory; how a struct with its own JSON says how it lies (`publr_form`) |
| `sdk/plugin/shape_said.zig` | 233 | How each kind of type is said in a description |
| `sdk/plugin/shape_default.zig` | 212 | A field's default as JSON, said in the description at build time |
| `sdk/plugin/shape_parts.zig` | 205 | A value's unions beside its block: listed by the guest for what it hands over, built from what the host laid out |
| `publr/free_value.zig` | 396 | A value whose shape comes with the data, in bytes read where they lie: its getters, and the check that it is well made |
| `publr/free_builder.zig` | 252 | Writes such a value part by part |
| `sdk/free_json.zig` | 233 | Such a value to and from JSON, where Publr keeps or sends JSON |
| `publr/free_typed.zig` | 254 | A struct written as such a value, with no text in between |
| `publr/free_read.zig` | 225 | Such a value read as a struct |
| `sdk/free_comptime.zig` | 244 | An example's JSON read into such a value at build time |
| `sdk/operation/json.zig` | 301 | `operation.Json`: JSON text in Publr, bytes read where they lie in an installed plugin's module, one way to work with it in both |
| `sdk/operation/lists.zig` | 330 | The rule that every list of an operation's input or answer holds a page (200) unless its struct's `limits` says fewer, checked as the operation runs; what answering a page at a time (`after` in, `next` out) is |
| `publr/money.zig` | 201 | `publr.Money`: a list of amounts by currency, handed over as it lies, `{ "PLN": 12300 }` in JSON |
| `sdk/extended_laid.zig` | 179 | The fields plugins add to a list read's rows, as an installed plugin's module holds them |
| `sdk/plugin/wire_json.zig` | 1479 | JSON at a cost close to its bytes, for what still crosses as JSON (`publr.json`) |
| `sdk/plugin/read_memo.zig` | 177 | Reads one call made already, answered again until the plugin writes; a scope drops the ones it made |
| `publr/plugin/collections.zig` | 277 | `publr.List(T)`, `publr.IdMap(V)`, `publr.IdList(V)`: a plugin's own collections, made with `init(ctx)`, growing in the memory they were made in and telling what they hold |
| `publr/plugin/pages.zig` | 130 | `publr.pages`: every page of an operation that answers a page at a time, walked with one page held at once |
| `sdk/plugin/held_note.zig` | 49 | Where a collection tells what it holds: the plugins' memory compiled in, the host (`publr_held`) installed |
| `sdk/plugin/rows.zig` | 328 | `Records.where`, `Records.all`: walks over internal records, a page held at a time, each row's memory given back at the next |
| `publr/plugin/record_computed.zig` | 196 | A record's computed fields: which fields, the batch modifier each brings under `computed.<record>.<field>`, `publr.Computed` |
| `sdk/plugin/walks.zig` | 95 | The walks a plugin has open, given back with the work or scope they were opened in; `walks/native.zig` (145) and `walks/guest.zig` (180) for each mode |
| `publr/plugin/id_map.zig` | 141 | Maps keyed by text that is mostly ids, hashed in 64-bit steps (an installed plugin does 128-bit ones in software) |
| `sdk/plugin/mod_reads.zig` | 478 | What a modifier reads while it runs over a batch: a `get` noted per record type and read once for the batch, laid out as the record's struct (`Typed`); any other read noted and asked once per distinct input |
| `sdk/plugin/mod_reads_laid.zig` | 147 | How an installed plugin keeps those reads: asked and answered as its own structs, told apart by the input's bytes |
| `sdk/plugin/laid_key.zig` | 127 | A value's bytes as what a read is remembered by: read where it lies, nothing built |
| `sdk/plugin/guest_memory.zig` | 46 | An installed plugin's memory: its `heap` and each call's `Arena`, over the module's linear memory |
| `sdk/plugin/guest_memory/runs.zig` | 400 | Free pages kept as runs: taken, given back, joined and split; a memory for tests |
| `sdk/plugin/guest_memory/arena.zig` | 381 | One call's or one scope's memory: small requests fill blocks of pages, all given back at its end |
| `sdk/plugin/guest_memory/large.zig` | 166 | An arena's requests of a page or more: pages of their own, grown, shrunk and freed by pages |
| `sdk/plugin/guest_memory/heap.zig` | 207 | The plugin's general allocator: whole pages from 16 KiB, the small allocator below |
| `sdk/plugin/route.zig` | 211 | What a compiled-in plugin's routes and operator commands may be: under prefixes it owns, at most 16 and 8 |
| `sdk/plugin/admin_slots.zig` | 66 | A plugin in the admin: its pages, panels, a top bar item, row actions |
| `sdk/plugin/state.zig` | 71 | A compiled-in plugin's `State` and the process it is made from |
| `sdk/structure.zig` | 34 | Which events change a project's structure |
| `sdk/scratch.zig` | 109 | A request's scratch: working memory for a loop's items, given back after each |
| `sdk/plugin_memory.zig` | 152 | Compiled-in plugins' working memory: one piece set aside per process, in pages, on the installed plugins' allocator (`plugin/guest_memory`) |
| `sdk/plugin_memory/work.zig` | 356 | One piece of a compiled-in plugin's work in an arena of its own: `begin`, `leave`, `end`; a refusal's words carried out |
| `sdk/hook_memory.zig` | 141 | A compiled-in hook run in memory of its own: what it changed copied to its caller's, what it left alone not |
| `sdk/help.zig` | 311 | An operation's `--help`: its fields, output, failures and example, for core and installed plugins alike |
| `sdk/plugin/wire.zig` | 107 | What crosses the sandbox's boundary: error codes, the result cell, the envelopes |
| `sdk/sandboxed_plugins.zig` | 195 | The `Plugins` interface through which dispatch reaches installed plugins' operations and hooks |
| `sdk/plugin_access.zig` | 188 | A plugin's granted permissions turned into the grant for one request |
| `sdk/call_json.zig` | 600 | Calling an operation by name through the same steps: a built-in one with JSON in and out, an installed plugin's with its input and answer as they come (`sandboxed_plugins.Passed`), JSON written only for the log and a removal list. `Working`: the request's working memory taken for one piece of a plugin's work (an installed operation, a queued job or `on` run, core's apply of modifiers), each call into core given back as it answers; a call out of it fails, never runs twice |
| `sdk/plugin/context.zig` | 978 | `HostApi`: the compiled-in call behind a plugin's `publr.Ctx`, and `host_of`/`behind_of`, the SDK's own way behind it |
| `publr/ctx.zig` | 383 | `publr.Ctx`, declared once: an opaque type whose methods go to the call behind it, compiled in or installed; `Ctx.Scope`, `Ctx.Locale` |
| `publr/caller.zig` | 130 | `ctx.caller()`: where a call came from, the account and roles, whether it was granted |
| `publr/queue_ctx.zig` | 199 | `publr.QueueCtx`: queued work's `Ctx`, with `fetch` |
| `publr/exchange_ctx.zig` | 59 | `publr.ExchangeCtx`: a sign-in provider's exchange step, `fetch` and `log` |
| `publr/extend/host.zig` | 350 | `publr.Host`: what a built-in plugin's `.extend` registers, and every type its seams take |
| `publr/extend/route.zig` | 217 | A built-in plugin's routes and operator commands: `Route`, `Request`, `Response`, `Context` over the server's own |
| `publr/extend/database.zig` | 167 | `publr.Database` and `Statement`: SQL on a built-in plugin's own tables |
| `publr/extend/policy.zig` | 46 | `host.policy`: the caller's view and the call in, a narrowing grant out |
| `publr/extend/delivery.zig` | 40 | `host.delivery_gate`: what a gate is asked about and what it says |
| `publr/extend/sign_in.zig` | 93 | `host.sign_in_provider`: the sign-in provider contract |
| `publr/extend/process.zig` | 106 | `Process`, `Command`, `Serving`, `Server`: what a plugin's state and process hooks are given |
| `publr/extend/admin.zig` | 21 | `host.admin_brand` and `host.sign_in_at` |
| `publr/extend/admin_page.zig` | 222 | `publr.Host.admin_pages`: a built-in plugin's own admin screens over the admin's session |
| `publr/extend/timed.zig` | 51 | `publr.Host.timed`: a built-in plugin's own request out with a time limit |
| `sdk/plugin/types.zig` | 139 | Content types declared by plugins: create/update on bootstrap, lock declared fields, keep hand-added ones |
| `lib/auth/password.zig` | 110 | Argon2id hashing and checking |
| `lib/auth/csrf.zig` | 97 | CSRF token derive/verify, origin check |
| `lib/auth/throttle.zig` | 165 | Sign-in throttling by subject |
| `lib/auth/state.zig` | 99 | Process auth state: secret, throttle, hashing params |
| `lib/db.zig` | 394 | `Runtime` (SQLite global init), `Db` (one connection), errors, test fixture |
| `lib/db/statement.zig` | 239 | Prepared statement: bind/step/column |
| `lib/db/transaction.zig` | 154 | `BEGIN IMMEDIATE` / savepoints / commit / rollback |
| `lib/db/schema.zig` | 72 | Apply `schema.sql`; table list |
| `lib/http/server.zig` | 602 | Single-threaded poll loop: accept, read, dispatch, write, keep-alive |
| `lib/http/socket.zig` | 191 | POSIX sockets + poll |
| `lib/http/request.zig` | 425 | HTTP/1.1 request parser |
| `lib/http/response.zig` | 173 | Response builder (headers, text/html/json/redirect) |
| `lib/http/router.zig` | 241 | Pattern routes with `:params`, middleware chain |
| `lib/http/static.zig` | 106 | Serve files from a directory |
| `lib/http/status.zig` | 75 | Status codes |
| `lib/http/form.zig` | 135 | urlencoded bodies and query strings as name/value pairs, percent-decoded |
| `lib/id.zig` | 112 | Ids: 24 hex, time-ordered (records, users), random (tokens) or derived from a name (content types) |
| `lib/text.zig` | 57 | Slugs: slugify and numeric suffixes |
| `lib/html.zig` | 32 | HTML escaping |
| `lib/report.zig` | 46 | Print an error box to stderr |

### What is wrong with it today

1. ~~Three shapes for one record~~ done: `store/records.zig:Record` is the one row shape (type handle, title and slug joined in by SQL), operations return it as is; `record get` answers `{ record, slot, document }`.
2. ~~Error mapping everywhere~~ done: operations `try` straight through (`sdk.Error` already contains the storage errors); the one translation left, a broken database constraint becoming `Conflict`, happens in `sdk.zig:as_outcome` when an operation returns. `model/content_type.zig` got a declared error set instead of an inferred one.
3. ~~Operation ceremony~~ done: an operation is `name`, `description` (+ `details`, `field_docs`, `output_docs`), `kind`, `In`, `Out`, `example`, `example_out`, `run`. `resource` is read from `In` by field name (`sdk/operation.zig:resource_of`); `seed` became one example world, which then left `src/` entirely (`scripts/parity.zig`); `volatile_fields` went because parity compares the shape of outputs, not values; `example_caller` is derived from what the policy lets an anonymous caller do.
4. ~~Asserts that restate the compiler~~ done: `tidy` now rejects tautologies, `or true`, type and size restatements (28 removed), fails a non-trivial function only when it asserts nothing, and reports how many functions have a single assertion (two stays the aim: 22 today). Asserts that restate a non-empty argument stay where they say something.
5. ~~Dead weight~~ done: `sdk/queue.zig` and `enqueue`/`drain` are gone (there is no deferred form of an operation; a plugin that wants "later" keeps the intent as a record).
6. ~~Mixed files~~ done: `server/routes.zig` is the table (tests moved next to what they test: `lib/auth/http.zig`, `adapters/rest.zig`); `lib/auth/identity.zig` split out of `lib/auth/http.zig`; `record/common.zig` dissolved into `record/access.zig` (who may touch what), `record/document.zig` (the document), the events into `record/lifecycle.zig`, the test fixture into `record/fixture.zig`.
7. ~~Admin handler skeleton~~ done: `admin.accept(exchange, back)` is the one place a POST is admitted (signed in, parseable form, same origin + CSRF) and `admin.param` the one place a missing route parameter answers not found; handlers start with one line each.

Each item is one reviewable diff. The map is updated with each.
