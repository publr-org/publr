# Building on Publr: a guide for agents

You are working in a Publr project for someone. This guide is built into the `publr`
binary they run (`publr agents` prints it), so it describes exactly the Publr in front of
you. Read it whole before changing anything.

## The project

Every `publr` in this guide means this site's own binary, run from the site's folder:
the one its `publr.zon` names in `.binary`, else the first of `./publr`, `../publr`,
`./zig-out/bin/publr`, `../zig-out/bin/publr` that exists (sites beside a shared binary,
or a Publr checkout with its own build). Never a `publr` from the PATH. A project (a
site) is the folder `publr` runs in:

```
data/publr.db                       the database: content, users, installed plugins
plugins/<name>/main.zig             the source of each plugin you write
apps/<name>/                        each app: what people use at an address (see Pages); the
                                    project's own `apps/` is read when it has one
```

A **plugin** is what is stored and done: content types and operations. An **app** is what
people use at an address: a website, a shop, or a whole product with its own sign-in,
dashboards and forms for its users, separate from Publr's admin. An app that needs logic
of its own brings a plugin for it.

`publr serve` runs the site and the admin (`http://127.0.0.1:8080/admin`). While it runs,
every other `publr` command is sent to it and takes effect at once: you never restart it.
`publr --help` lists Publr's own commands; installed plugins bring namespaces of their own
(`publr --as-admin plugin list` names the plugins). `publr <namespace> --help` lists a
namespace's commands, either kind, and `publr <namespace> <verb> --help` explains one.

## Plugins

A feature is a **plugin**: a Zig file that declares operations (what can be done) and
content types (what is stored). It runs in a sandbox and can only do what the project's
administrator allowed. This one is complete:

```zig
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

const Entry = struct { name: []const u8, message: []const u8 };
const entries = publr.records.of(Entry, "guestbook_entry");

pub const manifest: publr.plugin.Manifest = .{
    .name = "guestbook",
    .version = "0.1.0",
    .summary = "A guestbook visitors sign from the site",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "app.guestbook",
    .summary = "What the site's visitors do with the guestbook",
    .details = "`app.guestbook sign` adds an entry, published at once; anyone may call it.",
}};

pub const content_types = [_]publr.plugin.ContentTypeDef{.{
    .handle = "guestbook_entry",
    .name = "Guestbook entry",
    .public = true,
    .title_field = "name",
    .fields = &.{
        .{ .name = "name", .label = "Name", .kind = "string", .required = true },
        .{ .name = "message", .label = "Message", .kind = "string", .required = true },
    },
}};

pub const operations = [_]type{Sign};

pub const Sign = struct {
    pub const name = "app.guestbook.sign";
    pub const description = "Sign the guestbook";
    pub const details = "Anyone may call it. A name is 1 to 80 characters, a message 1 to 500.";
    pub const open = true;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { name: []const u8, message: []const u8 };
    pub const Out = struct { id: []const u8 };
    pub const example: In = .{ .name = "Ada", .message = "Lovely site!" };
    pub const example_out: Out = .{ .id = "3f9c1e0a5b7d2c4e6f8a9b0c" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "Who signs",
        .message = "What they write",
    };
    pub const rules: sdk.operation.Rules(In) = .{
        .name = .{ .min_len = 1, .max_len = 80 },
        .message = .{ .min_len = 1, .max_len = 500 },
    };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        const entry: Entry = .{ .name = in.name, .message = in.message };
        const id = try entries.create(ctx, entry, .{ .status = "published" });

        return .{ .id = id };
    }
};
```

- **Names.** Every operation is `<plugin>.<verb>` (`notes.add`), for the people running
  the site from the admin or the command line, or `app.<plugin>.<verb>`
  (`app.guestbook.sign`), for an app's users. Anything else fails the build. A plugin
  cannot be named after one of Publr's own namespaces, or `app`. `app.` says an
  operation is safe to give an app's users, not who may call it: administrators call
  `app.*` operations too. Never give one operation two names; if the admin needs
  different behaviour, that is a second operation.
- **Declare bounds, don't write them.** `pub const rules: sdk.operation.Rules(In)` holds
  each input field's bounds (`min`/`max`, `min_len`/`max_len`, `items_min`/`items_max`,
  `preset`, `pattern`); core refuses a call that breaks them before your code runs, saying
  which field, and `--help` shows them.
- **What a site calls is `app.`.** An app's pages reach `app.<plugin>.<verb>` at
  `<mount>/_api/<plugin>/<verb>` (an island posts JSON with `Publr-Request: 1`, a form
  posts its fields), as the visitor, only when the app lists the plugin in `.plugins`.
  `ctx.visitor()` is the visitor's stable id, signed in or not: key carts and the like on
  it. Never set cookies of your own.
- **Show, do not store.** How the admin names a record of yours (a variant as `Earl Grey,
  50 g`) is a display hook (`stage = .display`, `point = "record.title"`,
  `content_type`), never a title copied into another field. It gets the batch's titles
  and fields, reads the rest as granted (`publr.records.of(...).many(ctx, ids)`, one
  call), cannot write, and answers text only.
- **Refuse in your own words.** `return ctx.fail("NotEnoughStock", "Only 2 left.")`: the
  name is what a form's redirect carries (`?error=NotEnoughStock`) and a page checks for,
  the message what an island or the CLI shows. The write rolls back.
- **Shared or per app.** An internal collection is kept per app unless it says
  `.shared = true` (stock every shop sells from); a visitor's cart stays per app.
- **Declare secrets.** `pub const secret = .{"password"}` lists the input fields that
  hold one. Core logs every call's input (`publr activity list`, `publr errors list`)
  with them replaced by `•`; a field named like a secret (`password`, `token`, `secret`,
  `*_key`) is masked even undeclared, but declare it anyway.
- **Document everything.** Every namespace, operation and field gets its text: an
  operation its `description`, `details` (who may call it, what it changes, how it fails),
  `example`, `example_out` and `field_docs`. `publr <namespace> --help` shows them to the
  people who use the plugin, and to the next agent.
- **State lives in records.** The plugin's instance may be dropped and made again at any
  time; keep nothing in globals.
- **Records are typed values.** `publr.records.of(Entry, "guestbook_entry")` gives
  `get` (by id), `find_one` (by a unique field), `find` (many, filtered on at most one
  field), `create` and `save` (only the fields you give; with `.status = "published"`
  straight into the live record, publishing nothing else). Never build JSON text by hand.
  There is no query language: anything a read by identity or one field cannot say is an
  operation of your plugin.
- **Reach the rest of Publr through `ctx.call`,** with an operation's type: every one
  `publr --help` lists is there, under `publr.operations`. The plugin's own content types
  and operations need no permission.

## How to build well

Follow these. A plugin or app that breaks one is not done.

**Plan first.** Before writing code, say what the people running the site will see in the
admin (which content types, which fields, what they edit) and what visitors will see
(which pages, what is static, what changes per visitor). Agree it with the person you
work for.

**Plugins**

- **One capability per plugin, generic.** Inventory counts stock of any record it is
  pointed at; it knows nothing about products. A plugin may have no pages or admin
  screens at all.
- **Name what you build on.** A plugin that needs another names it in `depends_on`; one
  it only uses when present goes in `compatible_with`. Each operation of theirs you call
  or hook is a `publr.plugin.Remote("inventory.reserve", Sends, Reads)` in your
  `remotes`, in your own words, with only the fields you use. Never import another
  plugin. Do not make a plugin whose only job is to connect two others; one of them owns
  the connection.
- **Parents never know their children.** A plugin others extend exposes documented
  operations and accepts hooks on them; it never names, imports or checks for the plugins
  that extend it.
- **A plugin is its own folder.** Import `publr`, your own files and other plugins'
  `interface.zig` by name. Never import or copy another plugin's code, never share a
  folder of helpers between plugins.
- **When Publr cannot do something, say so.** Tell the person what is missing. Do not
  build a workaround that hides it.

**Authority**

- **The server owns the facts and the rules.** An operation reads what it decides on from
  storage. Its input is the request: a query, answers, a selection, quantities, record
  IDs. Take a record as `publr.records.Ref(Variant, "variant")`: the caller sends its id,
  core reads the stored record with the caller's access before your operation runs
  (`in.variant.value.?`), and refuses one that is unknown or not theirs to see. Never records' contents, prices, rules or policies sent by the caller: a visitor can
  send anything.
- **Pages show and collect.** A page never gathers data to send to an operation for it to
  trust, and never calls an operation only so a check appears to happen.
- **One transaction.** A write, the hooks it runs and the calls it makes commit or roll
  back together. A call you catch an error from undoes only its own changes. Do not call outside services from a write: nothing undoes them if it
  rolls back.

**Data**

- **Content is what people manage.** Model it as content types they edit: products,
  variants, orders, methods.
- **What only your plugin keeps is internal records.** Carts, holds, ledgers, logs:
  declare each kind (`pub const internal_records = [_]publr.plugin.InternalCollection{
  .{ .kind = "movement", .indexed = &.{"stock"}, .append_only = true } }`) and use
  `publr.internal.of(Movement, "movement")`: `get`, `find_one`, `find`, `create`, `save`,
  `delete`. They never show in the admin's Content, reach only your plugin's records in
  the request's app, and need no permission.
- **Use the field kinds.** A record pointing at another is a `reference` field
  (`.options = .{ .to = &.{"product"} }`), a time is `datetime`, a choice is `select`,
  a price is `money` (`{ "GBP": 850 }`, minor units, in the site's currencies; a template
  writes it with `Publr.build.money(product.data.price)`). Never a
  record ID in a `string`, never JSON in a `text`, never a time or a price as a number.
- **What is pointed at is a record.** If anything refers to a part of a record (a
  product's variants), make the part its own content type with a reference to the whole.
- **History keeps a copy.** An order copies what was bought (name, variant, price,
  options) when it is placed, and keeps a reference to the variant that may stop
  resolving (`.reference = .{ .on_delete = .keep }` in its `.options`).

**Pages**

- **Scripts are yours to add.** Pages are `.publr` templates; their behaviour (a slider,
  a menu, a whole framework) can be any JavaScript in the app's `public/`, linked from a
  layout (`<script src="/learn/slider.js" defer></script>` for an app at `/learn`). Markup
  printed with `set:html` is sanitized, so a script goes in a template or `public/`, never
  in a record. The admin is on an origin of its own, so a page's scripts never act as
  someone signed in to it: they see the real page. The admin's previews show pages in a
  sandboxed frame, where `localStorage` and `document.cookie` throw and other sites' embeds
  show a notice; islands, `_api` calls and forms work there. Guard storage with `try`.
- **Static first.** A page is built once unless it must know the visitor; a part that does
  (a cart, stock left) is a dynamic island. Forms post to the plugin's `app.*` operations.
- **Use the patterns people expect.** For a shop: product pages, a cart, a separate
  checkout, a confirmation. Internal documents (packing slips) belong in the admin.

**Before calling it done,** check: the plugin works with nothing but what it requires; a
call without permission is denied and changes nothing; a failing hook rolls back the whole
write; and the admin and the pages match what you agreed.

## Build, install, change

```sh
publr plugin build --name guestbook
```

This compiles `plugins/guestbook/main.zig` with the compiler inside `publr` (no
Zig needed), then installs it: a new plugin is added and enabled, one already there gets
this as its next version, the previous kept to roll back to. When the compiler reports an
error, fix the source and run it again. To change a plugin, edit it, raise `.version`, and
build again. Built again unchanged, it says it is up to date. When it says it builds
"without" something (a `schema_sql`, an operation that takes the host's context), that part
does not run in the sandbox; calls to it answer unavailable.

Check it:

```sh
publr --as-admin plugin get --name guestbook     # version, what it asked for, what waits
publr guestbook --help                           # a plugin's own commands, when its
                                                 # namespace is not `app.*`
curl -X POST http://127.0.0.1:8080/api/app.guestbook/sign \
  -H 'content-type: application/json' -H 'origin: http://127.0.0.1:8080' \
  -d '{"name":"Ada","message":"hi"}'             # an `app.*` operation, as a visitor
```

## Admin pages for a plugin

A plugin's settings are best a `.kind = .settings` content type: the admin draws its page
for you. A page of its own is for what that cannot do. Start from a working one:

```sh
publr --as-admin plugin scaffold --name notes --page list   # or --page form
```

It answers every file of a plugin with a page (`{ path, content }`); hand them to
`plugin build --name notes --files <files>`, or write them into `plugins/notes/` and run
`publr plugin build --name notes`. The page is listed in Settings and shown in the plugin
frame, looking like the admin's own. Keep it that way:

- **Compose, never style.** The page returns an admin layout (`IndexPage`, `FormPage`)
  and fills it with the design system's composites: `FieldRow` for each field (label,
  required mark, help), `ItemList` for an ordered list of linked items (move, remove, a
  place to add), `StatusStrip` for the status line. Set no spacing or colours of your own;
  a status tone is one of neutral, success, warning, error, accent, review, info (the
  build refuses others).
- **A form by declaration.** A page declared as
  `.form = .{ .read = Read, .save = Save, .multiline = &.{"description"} }` needs no
  views at all: the admin draws the form from `Save`'s input (each field's `field_docs`
  line is its help), filled from what `Read` answers, compiled in or installed alike. In
  a page of your own, `@publr/admin/OperationForm.ptsx` does the same from a list of
  fields.
- **Data through `publr/operations`.** `call("notes.add")` writes through one of the
  plugin's operations (call it with the input; it has `isPending` and `error`);
  `query("notes.list")` reads reactively and reads again after every write (with
  `{ seeded: true }` when the page's server render already drew it, so it reads only
  once a write makes it stale);
  ``query(groq`*[_type == "notes_entry"]`)`` reads GROQ as the plugin may. No `fetch`, no
  tokens: in the frame both go through the admin, which runs only what the plugin may.
- **Typed.** `publr plugin build` writes `ui/operations.d.ts`: every operation's input and
  output, so a misspelt name or field is an error in your editor.
- **Entries, not chrome.** To put the page in the top bar, declare
  `pub const top_bar = [_]publr.plugin.Item{.{ .label = "Notes", .icon = "file",
  .page = "entries", .operation = List, .count = Count }}` (`count`, a read answering
  `count`, for a number beside it). The admin draws it; it leads only to your pages or
  `/admin/...`. The rail is the person's: nothing adds to it, and people pin your pages
  there themselves (`publr rail pin`). Several content types of your own get a section of
  their own in Content with `pub const sections = [_]publr.plugin.Section{.{ .label = "Shop",
  .icon = "folder", .types = &.{.{ .handle = "product", .columns = &.{"price"} }} }}`:
  listed under Sections in Content, with a sidebar of their own. Removing a plugin keeps
  its data unless an administrator ticks pieces on its page; `pub const uninstall = Forget`
  (one of your writes, taking `remove`) clears what core does not know is yours when they
  do. `pub const about` is HTML for the plugin's page under
  Settings › Plugins: plain text markup, classes only `muted`, `success`, `warning`,
  `error`; anything else is dropped.

## Pages: apps

The site people visit is made of apps: folders of templates, never compiled. An app
answers at a mount and works with what its plugins store and do.

**Words in records, layout in templates.** Everything a person would change on the site
lives in content types and records the templates read: each page's title and body (a
`page` type with title, slug and body, one `[slug].publr` drawing them all), the menu
(records, or a list on a settings type), the site's name, phone, address and opening
hours (a `kind = settings` type, one record). Templates hold the layout and the look,
never the words. A site built this way is edited in the admin by its owner, and a small
change is one `record update`: live at once, no file written, nothing loaded. Hard-coded
text in a template is a site its owner cannot edit.

```
apps/courses/app.zon                      .{ .name = "courses", .label = "Courses", .mount = .{ .path = "/learn" } }
apps/courses/layouts/base.publr           the page around every page
apps/courses/content/index.publr          /learn
apps/courses/content/lessons/[slug].publr /learn/lessons/<slug>, one per lesson
apps/courses/components/*.publr           parts pages import
apps/courses/public/                      files served as they are, at /learn/<file>
```

A template is synchronous JavaScript frontmatter over HTML. Imports, Publr reads,
functions, arrays and seeded computations share scope with the body:

```astro
---
import Base from '../../layouts/base.publr';
const lesson = Publr.build.getEntry({ type: 'lesson' });
const lessons = Publr.build.getCollection({ type: 'lesson', limit: 100 });
---
<Base title={lesson.title}>
  <h1>{lesson.title}</h1>
  <div>{lesson.data.body ?? ""}</div>
  <ul>
    {lessons.map((item) => (
      <li><a href={`/learn/lessons/${item.slug ?? ""}`}>{item.title}</a></li>
    ))}
  </ul>
</Base>
```

- **Panels on other types' forms.** `pub const panels = [_]publr.plugin.Panel{.{ .type =
  "product", .label = "Stock", .operation = StockPanel }}` adds a box to every product's
  edit form, whoever's type it is. `StockPanel` is one of your reads taking `record` (the
  record's id, all it is told) and answering `html`; it is drawn in the plugin frame like
  your pages, with `call` and `query` working the same, and reads what else it needs
  itself. Nothing on the type's side knows about it; without the type, there is no panel.
- **What a page can read.** Built pages see live records of **public** types only: give
  the plugin's content type `.public = true`, and for pages per record a slug field,
  `.{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{ .source = "title" } }`.
  An entry is `id`, `type`, `slug`, `title`, `created_at`, `updated_at` and `data`, its
  fields (`lesson.data.body`).
- **Images.** A media field holds the file's id, not its address:
  `Publr.build.media(lesson.data.photo)` is the file (`url`, `alt`, `title`, `width`,
  `height`), or null when there is none a visitor may see, and
  `Publr.build.mediaUrl(lesson.data.photo, { w: 800, h: 600, fit: 'cover' })` its address,
  resized. Never query the `media` type: it is the admin's library, closed to visitors.
  Bring images in with `media import_many --urls <a>,<b>,…` (up to 20 a call; one with
  `media import --url`).
- **Ask with a query when the reads do not fit.** `Publr.build.query(groq, params)` (or
  `Publr.request.query`) reads with GROQ: several types joined, nested lists, any filter,
  counts, order by anything, in one call. `*[_type == "variant" && product == $id] |
  order(price.GBP) { _id, title, price }`. Its answer is plain JSON shaped by the query, not
  entries; references are record ids (`product == ^._id`, `author->name`). The URL's query
  string is `Publr.request.param('error')`.
- **The body** takes `{value}` (escaped), `set:html={value}` (markup,
  sanitized: no scripts, styles, frames or `on…` attributes survive), `{items.map((item) =>
  (...))}`, `{test ? (...) : null}`, and `<Component prop="..." />` with `<slot />`. A
  layout or component reads `props.name`. Keep island directives and PJSX component
  calls in the outer markup; computed JSX can embed static `.publr` components.
- **Computed markup.** JavaScript expressions can generate arrays of JSX elements,
  including SVG patterns. Relative `.js` and `.ts` helpers use ES module imports.
  Static pages save the HTML; no browser JavaScript or Node installation is needed.
  Use seeded randomness. There is no filesystem, network or asynchronous rendering.
- **Per request.** A page named `<name>.dynamic.publr` renders for each visitor and may
  read `Publr.request` (`session`, `getCollection`, `call('app.<plugin>.<verb>')` for an
  operation that allows it). A form posts to the plugin's `app.*` operations through
  `/api/<namespace>/<verb>`.
- **Links** are the app's own: an app at `/learn` writes `/learn/...`.
- **Interactive components** (`interactive/*.ptsx`) and `middleware.zig` still need a build
  of Publr: an app loaded from a folder has neither. For behaviour in the browser, use
  scripts in `public/`; for code on the server, a plugin.

After changing an app:

```sh
publr apps load
```

The running server reads the apps again and serves the change at once; a template it
refuses is named with the reason, and the apps answer 503 until a load succeeds.

## Permissions: declare, never grant

Anything beyond its own types and operations, a plugin asks for, with a reason:

```zig
pub const permissions = [_]publr.plugin.Permission{
    .{ .key = "content.read", .reason = "Lists the posts on the notes page" },
};
```

The build tells you when one is missing: calling an operation none of the plugin's
permissions opens fails to compile, naming the key to add. `publr agents` ends with every
key there is, its tier, and the operations it opens. Low
and medium ones are granted when the plugin is installed; high ones wait for a person.
**Never grant anything yourself** (`plugin grant`): that decision is the administrator's.
When something waits, finish by telling them what it is, why the plugin needs it, and that
they approve it in the admin under Settings > Plugins. A call the plugin was not granted
answers `Denied`; handle it, so the plugin still works without it.

## Working on a Publr elsewhere

When the project runs on another machine (a server, Publr Cloud), sign in to it as a
device, then send it commands:

```sh
publr login https://example.com          # prints a link; your person approves you there
publr --site https://example.com record list --type post
publr --site https://example.com --help  # its own commands, plugins included
publr whoami                             # whose device this is, and what it may do
```

The person chooses what you may do: `read`, `drafts` (you write, they publish) or
`write`. Never ask them for a password or a token, and never paste a token anywhere: the
link is the only way in. Removing is safe: what you delete (a record, a content type, a
plugin, a file, a user) goes to the trash whole, and the person can restore it (`trash
list`, `trash restore`). Only what is final waits for them: purging a record or a term, or
removing something from the trash, is not run but put on their removal list
(`ListedForRemoval`); they remove it themselves. Under `drafts`, a write that would publish
is refused with `DraftsOnly`: save drafts and tell them what waits to be published.

With no files of your own to edit, the project's apps and plugins are reached through
operations: `apps files`, `apps read`, `apps write --path <app>/<path> --content <text>`,
`apps remove`, then `apps load`, which answers why the apps do not load when they do not;
and `plugin build --name <name> --files '[{"path":"main.zig","content":"..."}]'`, which
builds and installs on the server, with `plugin build_log --name <name>` to follow it.

## Where to read more

- `publr skill`: the short version of how to decide where each need goes, and when Publr
  itself may change (only as a generic pull request).
- `publr --help`, and `--help` on any namespace or command.
- The SDK's source, as this binary builds plugins against it: `publr agents` ends with
  where it is on this machine. Start at `publr.zig` and `sdk/plugin/`.
