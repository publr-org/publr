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

## Publr's marketplace first

Before you build a feature (pages, a blog, a shop, bookings), ask Publr's marketplace
whether plugins give it already. It decides on its side which of its plugins what your
person asked needs, and answers them best first, leaving out those installed:

```sh
publr plugin find --request "A shop with tea in several sizes, and orders I can manage"
publr job answer --id <asked>            # again until it is no longer `waiting`
publr plugin install --name checkout     # with what it requires: products, cart
publr job answer --id <asked>            # `done` once they run
```

Both ask another server, so both answer at once with an id (`asked`) and do the work in
the background; `job answer` reads what landed. Each answer says what the plugin gives and what it requires. Install the ones that fit;
their content types, admin sections and operations are then yours to use. Build only what
none of them gives: the pages that show them, the fields and taxonomies a site adds, a
plugin of your own for behaviour nobody offers. High permissions a plugin asks for wait for
your person under Settings › Plugins.

## Plugins

A feature is a **plugin**: a folder with a `main.zig` that registers operations (what can
be done) and records (what is stored). It runs in a sandbox and can only do what the
project's administrator allowed. Its words are its doc comments. This one is complete:

```zig
//! A guestbook visitors sign from the site.
//!
//! `guestbook sign` adds an entry, shown at once; anyone may call it from the site.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "guestbook",
    .version = "0.1.0",
};

/// Guestbook entry
///
/// What a visitor wrote.
pub const Entry = struct {
    /// Name
    name: []const u8,
    /// Message
    message: []const u8,
};

pub const Entries = publr.record.define(Entry, .{
    .name = "guestbook.entry",
    .public = true,
});

pub const SignIn = struct {
    /// Who signs, 1 to 80 characters
    name: []const u8,
    /// What they write, 1 to 500 characters
    message: []const u8,
};

pub const SignOut = struct {
    /// The new entry's id
    id: []const u8,
};

/// Signs the guestbook.
///
/// Anyone may call it, from the site's pages too.
///
/// Example:
///   in: { "name": "Ada", "message": "Lovely site!" }
///   out: { "id": "3f9c1e0a5b7d2c4e6f8a9b0c" }
pub const Sign = publr.operation.define(SignIn, SignOut, .{
    .name = "sign",
    .kind = .write,
    .untrusted_callers = true,
    .validate = check,
    .run = sign,
});

fn check(in: SignIn, problems: *publr.Problems(SignIn)) void {
    if (in.name.len == 0 or in.name.len > 80) {
        problems.add(.name, "A name is 1 to 80 characters");
    }

    if (in.message.len == 0 or in.message.len > 500) {
        problems.add(.message, "A message is 1 to 500 characters");
    }
}

fn sign(ctx: *publr.Ctx, in: SignIn) publr.Error!SignOut {
    return .{ .id = try Entries.create(ctx, .{ .name = in.name, .message = in.message }) };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Entries},
    .operations = &.{Sign},
});
```

- **One registration.** Everything the plugin brings goes in `publr.plugin.define`, last in
  `main.zig`. Options are struct fields, so a misspelt one fails the build. Write every use
  out (`.operations = &.{Sign}`); Publr never looks inside a file for a name.
- **Words are doc comments.** `main.zig`'s `//!` is the plugin's description (first line)
  and the text of its settings page (the rest); its namespace's `--help` is made from the
  same words. An operation's `///` gives its
  description, details, `Fails:` and `Example:` (an `in:` and an `out:` line of JSON);
  every field of a record, an input and an output has a `///`. A missing one fails the
  build and says where it goes. `publr <plugin> --help` shows them.
- **Names.** An operation is `<plugin>.<verb>` (`guestbook.sign`): `.name` is the verb. A
  plugin cannot be named after one of Publr's own namespaces, or `app`. Never give one
  operation two names; if the admin needs different behaviour, that is a second
  operation.
- **Who may call.** Leave `.authorize` out and administrators, and roles an administrator
  granted the operation, may call it; with `.untrusted_callers = true`, anyone may. A
  ready answer narrows it: `publr.authorize.user_is_signed_in` (needs
  `.untrusted_callers = true`), `user_has_role(&.{"editor"})`, `plugin_calls`. Or a function of yours,
  `fn (ctx: *publr.Ctx, in: In) bool`, reading `ctx.caller()`.
- **What a site calls.** `.untrusted_callers = true` lets anyone call it without
  credentials: an app's pages at `<mount>/_actions/app.<plugin>.<verb>` (an island posts
  JSON with `Publr-Request: 1`, a form posts its fields), and any script anywhere. Its
  input is untrusted: key data to the caller, answer with nothing of other people's.
  Through that address an administrator is a signed-in person like any other. An
  operation without it is reachable there too, by someone signed in its `.authorize` lets
  in.
  `ctx.caller().visitor` is the visitor's stable id, signed in or not: key carts and the
  like on it. Never set cookies of your own.
- **Check in `.validate`.** `problems.add(.field, "reason")` for each problem; every one is
  told at once and the call is refused before `run`, answered 422 as
  `{ "error": "Invalid", "message", "problems": [ { "field", "message" } ] }`: every
  refusal takes that shape. A record checks its own
  data; check only what belongs to the call.
- **Rules live on the record.** A field's limits go in its `.validation` in
  `record.define`'s `.fields` (`.note = .{ .validation = .{ .max_len = 280 } }`), never in
  an operation and never only in words: every write checks them, the admin's editor
  included, and the admin shows them beside the field's help, so the help never repeats
  them. `.validation.hint` replaces that line (`"Up to {max_len} characters"`).
- **Modify, do not copy.** How the admin names a record of yours (a variant as `Earl Grey,
  50 g`) is a modifier, `publr.modify("variant.title", title)` in `.hooks`, never a title
  copied into another field. Its function takes one value (`*publr.Title(Variant)`:
  `.record` typed, `.title` to change); its reads are batched for the whole list by Publr. A
  value of yours others may change goes through `ctx.mod("yourplugin.name", value)`. A
  modifier cannot write or call out.
- **Refuse in your own words.** List the failure in `Fails:`
  (`- NotEnoughStock (409): fewer left than asked`) and
  `return ctx.fail(.NotEnoughStock, "Only {left} left", .{ .left = left })`: the name is
  what a form's redirect carries (`?error=NotEnoughStock`) and a page checks for, the
  message what an island or the CLI shows, in the caller's language. The write rolls
  back.
- **Shared or per app.** An internal record is kept per project; a visitor's cart that
  belongs to one app says `.scope = .app`.
- **Declare secrets.** `.secret = &.{.password}` lists the input fields that hold one (a
  name that is no field fails the build). Core logs every call's input
  (`publr activity list`, `publr errors list`) with them replaced by `•`; a field named
  like a secret (`password`, `token`, `secret`, `*_key`) is masked even undeclared.
- **State lives in records.** The plugin's instance may be dropped and made again at any
  time; keep nothing in globals.
- **Records are typed values.** `publr.record.define(Entry, .{ .name = "guestbook.entry"
  })` makes the type from the struct (named under the plugin: apps, GROQ and `--type` use
  `guestbook.entry`; a `.validate` on it checks rules across fields on every write) and gives `get` (by id), `find_one` (by a field),
  `create` and `save` (only the fields you give), and `transition` (a named transition of
  its flow). Never build JSON text by hand. Anything more is a GROQ query:
  `publr.query.prepare(text, .{})`, then `execute(ctx, Result, .{ .name = value })`, its
  `$names` checked against the struct when it compiles.
- **Reach the rest of Publr through `ctx.call`,** with an operation's type: every one
  `publr --help` lists is there, under `publr.operations`, and the plugin's own operations
  by their definitions (`ctx.call(Sign, in)`). The plugin's own records and operations
  need no permission.
- **Check before you finish.** `publr plugin check --dir plugins/<name>` names money,
  times and references kept as plain numbers or text, JSON in text, and an untrusted
  write taking facts the server owns. A `Why:` line in the field's `///` passes one when
  the rule does not fit.
- **Queued work.** What may wait, or reaches another server, is a job:
  `publr.job.define(In, .{ .name, .run })` in `.jobs`, queued with `ctx.enqueue(Job, in)` and
  run after the call by the worker, tried again when it fails. A schedule is
  `publr.job.define_recurring(.{ .name, .run, .every = .day, .at = .{ .hour = 3 } })`. What
  another server sends comes in through `publr.webhook.define` in `.webhooks`.
- **Taxonomies.** `publr.taxonomy.define(Term, .{ .name, .public, .hierarchical, .single,
  .internal, .fields })` in `.taxonomies`, stored as `<plugin>.<name>`. A type lists its
  taxonomies (`.taxonomies = &.{ "blog.topic", "tags" }` on the record); another plugin's
  types get one by `.register_taxonomies = .{ .{ .taxonomy, .to = &.{"products.*"} } }`. A
  taxonomy never names types. Terms come back under the name with the dot an underscore
  (`blog_topic`).
- **Not built yet.** `define` has no `register_components` option and fails the build on
  one. There is no outside search engine for plugins yet. When a feature needs one, tell the
  person what is missing.

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
  or hook is a `publr.remote.operation("inventory.reserve", Sends, Reads)` in your
  `.remotes`, in your own words, with only the fields you use;
  `publr.remote.record("products.variant", Fields)` reads their records and
  `publr.remote.event("inventory.out_of_stock", Payload)` hears their events the same way,
  listed in `.remotes` too. A remote that stops fitting is off (`error.Unavailable`), so
  handle that answer. Never import another
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
  IDs. Take a record as its handle's `Ref` (`Variants.Ref`): the caller sends its id,
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
  declare each kind as a record with `.internal = true` and `.indexed` for the fields it is
  found by (`publr.record.define(Movement, .{ .name = "stock.movement", .internal = true,
  .indexed = &.{.stock} })`), and use its handle. They never show in the admin's Content, reach only your plugin's records in
  the request's app, and need no permission.
- **Use the field kinds.** A record pointing at another holds its `Ref` (a `reference`
  field), a time is `publr.Time` (a `datetime` field), a choice is an enum (a `select`
  field), a price is `money` (`.fields = .{ .price = .{ .kind = "money" } }`) (`{ "GBP": 850 }`, minor units, in the site's currencies; a template
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
  show a notice; islands, `_actions` calls and forms work there. Guard storage with `try`.
- **Static first.** A page is built once unless it must know the visitor; a part that does
  (a cart, stock left) is a dynamic island. Forms post to the plugin's operations at
  `/_actions/app.<plugin>.<verb>`.
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
"without" something (an `extend`, an operation that takes the host's context), that part
does not run in the sandbox; calls to it answer unavailable.

Check it:

```sh
publr --as-admin plugin get --name guestbook     # version, what it asked for, what waits
publr guestbook --help                           # the plugin's own commands
curl -X POST http://127.0.0.1:8080/api/guestbook.sign \
  -H 'content-type: application/json' -H 'origin: http://127.0.0.1:8080' \
  -d '{"name":"Ada","message":"hi"}'             # one for untrusted callers, as a visitor
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
  `.form = .{ .read = Read, .save = Save }` needs no
  views at all: the admin draws the form from `Save`'s input (each field's `///` is its
  help), filled from what `Read` answers, compiled in or installed alike. In
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
- **Entries, not chrome.** To put a page in the top bar, the page says `.top_bar = .{
  .count = Count }` (a read answering `count`, for a number beside it). The admin draws it.
  The rail is the person's: nothing adds to it, and people pin your pages there themselves
  (`publr rail pin`). Your content types sit under menu items: declare `.menu = &.{.{ .name
  = "shop", .label = publr.t("Shop"), .icon = "bag" }}` and give each record `.menu = .{
  .parent = &.{"<plugin>.shop"} }`; an item with no parent is a part of the admin of its
  own, its children headings in its sidebar. A record's `.data_view = .{ .columns = &.{
  .price }, .order = .{ .field = .price, .direction = .asc } }` is where its list starts;
  whether a field filters or sorts is the field's (`.fields.price = .{ .sortable = true }`). Icons of your own go in `.icons` (SVG,
  sanitized). Removing a plugin keeps its data unless an administrator ticks pieces on its
  page; core knows all of it. The text on your plugin's page under Settings › Plugins is
  `main.zig`'s `//!` past its first line.

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
apps/courses/content/faq.md               /learn/faq, written in Markdown
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

- **Panels on other types' forms.** `.panels = &.{.{ .type = "product", .label =
  "Stock", .operation = StockPanel }}` in `define` adds a box to every product's
  edit form, whoever's type it is. `StockPanel` is one of your reads taking `record` (the
  record's id, all it is told) and `base`, answering `publr.views.render(ctx, in.base,
  publr.views.all.StockPanel, props)` as `html`: a view in your `ui/` on the `PanelPage`
  layout, drawn in the plugin frame like your pages, with `call` and `query` working the
  same. It reads what else it needs itself. Nothing on the type's side knows about it; without the type, there is no panel.
- **What a page can read.** Built pages see live records of **public** types only: give
  the plugin's record `.public = true`, and for pages per record a slug field,
  `slug: ?[]const u8 = null` with `.fields = .{ .slug = .{ .kind = "slug", .options =
  .{ .source = "title" } } }`.
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
  sanitized: no scripts, styles, frames or `on…` attributes survive), `set:markdown={value}`
  (a Markdown text field, converted to HTML and sanitized the same way), `{items.map((item) =>
  (...))}`, `{test ? (...) : null}`, and `<Component prop="..." />` with `<slot />`. A
  layout or component reads `props.name`. Keep island directives and PJSX component
  calls in the outer markup; computed JSX can embed static `.publr` components.
- **Markdown pages.** `content/faq.md` is a page: `key: value` frontmatter, `layout:
  ../layouts/base.publr` with the other keys as the layout's props, the Markdown as its
  slot. It suits writing kept with the code (docs, a changelog); words the owner edits stay
  in records.
- **Computed markup.** JavaScript expressions can generate arrays of JSX elements,
  including SVG patterns. Relative `.js` and `.ts` helpers use ES module imports.
  Static pages save the HTML; no browser JavaScript or Node installation is needed.
  Use seeded randomness. There is no filesystem, network or asynchronous rendering.
- **Per request.** A page named `<name>.dynamic.publr` renders for each visitor and may
  read `Publr.request` (`session`, `getCollection`, `call('app.<plugin>.<verb>')` for a
  read that allows it). A form posts to the plugin's operations through
  `<mount>/_actions/app.<plugin>.<verb>`.
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

Anything beyond its own records and operations, a plugin asks for in `define`, a key with
yes/no flags and a reason:

```zig
.permissions = &.{
    .{ .key = "records.read", .reason = "Lists the posts on the notes page" },
    .{ .key = "records.write", .publish = true, .reason = "Puts new prices live" },
    .{ .key = "http.fetch", .domains = &.{"api.supplier.com"}, .reason = "Fetches prices" },
},
```

The keys: `records.read` (`.records`; `.drafts`, `.private`, `.internal`), `records.write`
(`.records`; `.publish`), `records.destroy` (`.records`), `project.put` (`project.put`:
anything the project stores exactly as another copy of it keeps it, ids kept), `terms.read` (`.taxonomies`; the
read flags), `terms.write` (`.taxonomies`; `.publish`), `schema.read`, `schema.write`,
`users.names`, `users.read`, `users.write`, `site.read`, `settings.write`, `http.fetch`
(`.domains`), `media.read` (`.private`), `media.write`, `messaging.send`, and
`call:<plugin>.<verb>` for another plugin's operation. Reading starts at what a visitor
sees; name the types you need in `.records` rather than asking for every one. Without
`.publish` a write makes drafts and asks for transitions to live (`.pending`). A domain is
exact (`api.supplier.com`, no subdomains implied), `*.supplier.com`, or `"*"` for any public
address; production refuses local and private addresses whatever is listed, and redirects
stay within the domains. Any other key or option fails the build. They are requests: the
administrator may refuse any of them, and `ctx.grant(key)` says what the plugin got
(`.domains` for `http.fetch`).

A secret is not a permission: it is a field of a `.secrets` struct, its `///` the label
and where to find it, written into a request as `{secret:NAME}`; the plugin never holds
its value. Declare every one you write (an undeclared one fails the build) and ask for
`http.fetch`. The administrator fills it in at install or later on the plugin's page;
until then a request naming it is refused: "Supplier API key isn't set".

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

On Publr Cloud your changes go to a branch of the site, a copy with its content, never to
the live site. Start one for each task; every later command from this folder goes there,
reads included, so you see what you made:

```sh
publr --site https://example.com work start --name "Recipes section"   # prints Preview and Merge
publr work                                # the branch this folder works in
publr work done                           # stop sending this folder's commands there
publr --site https://example.com --production record publish ...   # this one call, live
```

Forget to start one and your first write starts one for you, named after the time. In a
branch you may do anything, publishing included: visitors see none of it until the person
merges it. When you are done, give them its Preview and Merge links. Use `--production`
only when they ask you to change the live site. A self-hosted Publr has no branches: your
changes go to the site itself, and `work start` says so.

The person chooses what you may do: `write` (the default), `drafts` (you write, they
publish) or `read`. Never ask them for a password or a token, and never paste a token anywhere: the
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
