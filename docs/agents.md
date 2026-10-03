# Building on Publr: a guide for agents

You are working in a Publr project for someone. This guide is built into the `publr`
binary they run (`publr agents` prints it), so it describes exactly the Publr in front of
you. Read it whole before changing anything.

## The project

A project is the folder `publr` runs in:

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

- **Build with Publr only.** Pages are `.publr` templates, styled with classes. No
  JavaScript app, no React or other framework, no npm, no bundler, no scripts of your own
  in `public/`. The one script a page may carry is `Publr.islands.condition`.
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

## Pages: apps

The site people visit is made of apps: folders of templates, never compiled. An app
answers at a mount and works with what its plugins store and do.

```
apps/courses/app.zon                      .{ .mount = .{ .path = "/learn" } }
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

- **What a page can read.** Built pages see live records of **public** types only: give
  the plugin's content type `.public = true`, and for pages per record a slug field,
  `.{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{ .source = "title" } }`.
  An entry is `id`, `type`, `slug`, `title`, `created_at`, `updated_at` and `data`, its
  fields (`lesson.data.body`).
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
  of Publr: an app of yours has neither. Put code in a plugin.

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

## Where to read more

- `publr --help`, and `--help` on any namespace or command.
- The SDK's source, as this binary builds plugins against it: `publr agents` ends with
  where it is on this machine. Start at `publr.zig` and `sdk/plugin/`.
