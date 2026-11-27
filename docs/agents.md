# Building on Publr: a guide for agents

You are working in a Publr project for someone. This guide is built into the Publr release
the site runs (`publr agents` prints it), so it describes exactly the Publr in front of
you. Read it whole before changing anything.

## The project

Every `publr` in this guide is the `publr` command (`brew install publr-org/tap/publr` or
`curl -fsSL https://publr.dev/install.sh | sh`), run in the site's folder. There it hands
every command of Publr's own to the release the site pins in its `publr.zon`, so what this
guide says is what answers. A project (a site) is the folder Publr runs in:

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

`publr start` runs the site and the admin in the background (`publr open` opens the admin,
signed in; `publr ls` says where each site answers). While it runs, every other `publr`
command is sent to it and takes effect at once: you never restart it.
`publr --help` lists Publr's own commands; installed plugins bring namespaces of their own
(`publr --as-admin plugin list` names the plugins). `publr <namespace> --help` lists a
namespace's commands, either kind, and `publr <namespace> <verb> --help` explains one.
`--as-admin` runs a command as an administrator, `--as <email>` as that account.

## Publr's marketplace first

Before you build a feature (pages, a blog, a shop, bookings), ask Publr's marketplace
whether plugins give it already. It decides on its side which of its plugins what your
person asked needs, and answers them best first, leaving out those installed:

```sh
publr plugin find --request "A shop with tea in several sizes, and orders I can manage"
publr job answer --id <asked>            # again until it is no longer `waiting`
publr plugin install --name checkout     # with what it requires: orders
publr job answer --id <asked>            # `done` once they run
```

Both ask another server, so both answer at once with an id (`asked`) and do the work in
the background; `job answer` reads what landed. Each answer says what the plugin gives and
what it requires. When the marketplace cannot decide, the answer lists every plugin it
offers; pick from them by their summaries. Install the ones that fit; their content types, admin sections and
operations are then yours to use. Build only what none of them gives: the pages that show
them, the fields and taxonomies a site adds, a plugin of your own for behaviour nobody
offers. High permissions a plugin asks for wait for your person under Settings › Plugins.

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
    const id = try Entries.create(ctx, .{
        .name = in.name,
        .message = in.message,
    });

    return .{
        .id = id,
    };
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
  and the text of its page under Settings › Plugins (the rest); its namespace's `--help` is
  made from the same words. An operation's `///` gives its description, details, `Fails:`
  and `Example:` (an `in:` and an `out:` line of JSON); every field of a record, an input
  and an output has a `///`. A missing one fails the build and says where it goes.
- **Names.** An operation is `<plugin>.<verb>` (`guestbook.sign`): `.name` is the verb. A
  plugin cannot be named after one of Publr's own namespaces, or `app`. Never give one
  operation two names; if the admin needs different behaviour, that is a second
  operation.
- **Who may call.** Leave `.authorize` out and administrators, and roles an administrator
  granted the operation, may call it; with `.untrusted_callers = true`, anyone may. A
  ready answer narrows it: `publr.authorize.user_is_signed_in` (needs
  `.untrusted_callers = true`), `user_has_role(&.{"editor"})`, `plugin_calls` (only
  plugins' code). Or a function of yours, `fn (ctx: *publr.Ctx, in: In) bool`, reading
  `ctx.caller()`. `ctx.caller().from` says where a call came from: `.plugin` with the
  calling plugin's name for another plugin's code (`orders`), so a part only `orders` may
  ask checks that name.
- **A visitor's call narrows yours.** What your operation calls while it runs for someone
  (a visitor's `_actions` call, a hook on their write) gets the narrower of your plugin's
  permissions and that person's roles; your own records stay yours. So giving an account a
  type, which a visitor may not do, is `Denied` there: do it from queued work (a job, a
  `publr.on` hook), which runs as your plugin alone.
- **What a site calls.** `.untrusted_callers = true` lets anyone call it without
  credentials: an app's pages at `<mount>/_actions/app.<plugin>.<verb>` (an island posts
  JSON with `Publr-Request: 1`, a form posts its fields), and any script anywhere. Its
  input is untrusted: key data to the caller, answer with nothing of other people's.
  Through that address an administrator is a signed-in person like any other. An
  operation without it is reachable there too, by someone signed in its `.authorize` lets
  in. `ctx.caller().visitor` is the visitor's stable id, signed in or not: key carts and
  the like on it. `ctx.caller().account()` is the signed-in person's account (null for
  nobody): keep it in a `publr.Account` field. Never set cookies of your own.
- **Check in `.validate`.** `problems.add(.field, "reason")` for each problem; every one is
  told at once and the call is refused before `run`, answered 422 as
  `{ "error": "Invalid", "message", "problems": [ { "field", "message" } ] }`: every
  refusal takes that shape. A record checks its own data; check only what belongs to the
  call.
- **Rules live on the record.** A field's limits go in its `.validation` in
  `record.define`'s `.fields` (`.note = .{ .validation = .{ .max_len = 280 } }`, `.min`,
  `.max`), never in an operation and never only in words: every write checks them, the
  admin's editor included, and the admin shows them beside the field's help, so the help
  never repeats them. `.validation.hint` replaces that line (`"Up to {max_len} characters"`).
- **Refuse in your own words.** List the failure in `Fails:`
  (`- NotEnoughStock (409): fewer left than asked`) and
  `return ctx.fail(.NotEnoughStock, "Only {left} left", .{ .left = left })`: the name is
  what a form's redirect carries (`?error=NotEnoughStock`) and a page checks for, the
  message what an island or the CLI shows, in the caller's language. The write rolls
  back. Every name a `ctx.fail` uses is listed in its operation's `Fails:`, and every
  `Fails:` line is used: the build reports either.
- **Hooks.** `.hooks = &.{ ... }` lists them: `publr.before(Operation, run)` changes or
  refuses an operation's input inside its write; `publr.after(Target, run)` runs inside the
  write after an operation or an event, and may refuse, rolling it all back;
  `publr.on(Target, run)` runs from the queue once the write committed, may call out, and
  runs again when it fails; `publr.modify("name", run)` changes a mod's value. `after` on
  an operation takes `fn (ctx: *publr.Ctx, in: *In, out: *const Out) publr.Error!void`,
  `on` takes `fn (ctx: *publr.QueueCtx, payload: Payload) publr.Error!void` (an operation's
  payload is its answer). Each hook is asked for like a permission: the `///` above its
  function is required, and its first line is the reason the administrator reads. A hook
  without it fails the build.
- **Modify, do not copy.** How the admin names a record of yours (a variant as `Earl Grey,
  50 g`) is a modifier, `publr.modify("variant.title", title)` in `.hooks`, never a title
  copied into another field. Its function takes one value (`*publr.Title(Variant)`:
  `.record` typed, `.title` to change); its reads are batched for the whole list by Publr. A
  value of yours others may change goes through `ctx.mod("yourplugin.name", value)`. A
  modifier cannot write or call out. `publr --as-admin mod list` lists every modifier.
  Core's own: `money.currencies` (`{ currencies }`) and `media.base` (`{ base }`, empty for
  the site's own address): a modifier that sets `base` to an origin serves every media
  address from there (a CDN), and nothing else.
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
  `guestbook.entry`; a `.validate` on it checks rules across fields on every write) and
  gives `get(ctx, id, .{})`, `find_one(ctx, .field, value)` (null when none), `many`,
  `create(ctx, value)` (answers the id), `save(ctx, held, .{ .field = value })` (only the
  fields you give), `delete`, and `transition` (a named transition of its flow). Never
  build JSON text by hand. Anything more is a GROQ query: `publr.query.prepare(text, .{})`,
  then `execute(ctx, Result, .{ .name = value })`, its `$names` checked against the struct
  when it compiles.
- **Reach the rest of Publr through `ctx.call`,** with an operation's type: every one
  `publr --help` lists is there, under `publr.operations` (`publr.operations.user.AddType`),
  and the plugin's own operations by their definitions (`ctx.call(Sign, in)`). The plugin's
  own records and operations need no permission.
- **Check before you finish.** `publr plugin check --dir plugins/<name>` (`plugin build`
  runs it too) names money, times and references kept as plain numbers or text, JSON in
  text, an untrusted write taking facts the server owns, and `Fails:` names out of step
  with `ctx.fail`. A `Why:` line in the field's `///` passes one when the rule does not fit.
- **Queued work.** What may wait, or reaches another server, is a job:
  `publr.job.define(In, .{ .name, .run })` in `.jobs`, queued with `ctx.enqueue(Job, in)`,
  or for a moment with `ctx.enqueue_at(Job, in, time)`, and run after the call by the
  worker, tried again when it fails. A schedule is
  `publr.job.define_recurring(.{ .name, .run, .every = .day, .at = .{ .hour = 3 } })`. What
  another server sends comes in through `publr.webhook.define` in `.webhooks`; to test one
  on your machine, expose the site with a tunnel (ngrok) and give the sender that address.
- **Time.** `ctx.now()` is a `publr.Time`; `try ctx.time_zone()` the site's zone, for
  `time.add_months(zone, 1)`, `start_of_day`, `local_date`, `days_until`.
- **What visitors bring.** `.request = .{ .query = .{"ref"}, .cookies = .{"consent"},
  .redirects = .{.{ .prefix = "/ref/", .operation = "follow" }} }` in `define`, with the
  permissions `request.read` and `request.redirect`. Core keeps the named query parameters
  of each visitor's landings, and answers every address under a prefix by calling your
  operation (`follow`, `.authorize = publr.authorize.plugin_calls`, taking `path` and
  `rest`, the part after the prefix, and answering `to` and `status`). Any call the
  visitor's request makes, a hook on their write included, reads what they brought with
  `ctx.call(publr.operations.request.Read, .{})`: the `first` and `last` landing that
  brought a parameter of yours (`landing`, `referrer`, `at_ms`, `values`), their `address`
  and your `cookies`.
- **People of your own.** A plugin whose people sign in to an app (customers, affiliates)
  declares a user type and the roles it gives:
  `.user_types = &[_]publr.plugin.UserType{.{ .name = "affiliate", .label = "Affiliate",
  .apps = &.{"shop"}, .sign_up = true, .roles = &.{"affiliate"} }}` and
  `.roles = &[_]publr.plugin.Role{.{ .name = "affiliate", .label = "Affiliate",
  .description = "..." }}`. Accounts are on two ladders, staff and members, and a type gives
  member roles only: never `admin`, `editor` or `contributor`, nor a role whose grants reach
  past what members call. With `users.own` the plugin makes accounts of its own types and
  gives or takes them (`publr.operations.user.AddType`, `.user`, `.user_type`).
- **Taxonomies.** `publr.taxonomy.define(Term, .{ .name, .public, .hierarchical, .single,
  .internal, .fields })` in `.taxonomies`, stored as `<plugin>.<name>`. A type lists its
  taxonomies (`.taxonomies = &.{ "blog.topic", "tags" }` on the record); another plugin's
  types get one by `.register_taxonomies = .{ .{ .taxonomy, .to = &.{"products.*"} } }`. A
  taxonomy never names types. Terms come back under the name with the dot an underscore
  (`blog_topic`).
- **Its words in other languages.** Every word a person reads goes through `publr.t("...")`
  (declarations), `ctx.t("...", values)` (code) or `Publr.t('...')` (views and templates).
  The plugin's translations travel with it:
  `.translations = &.{.{ .locale = "pl", .label = "Polski", .po = @embedFile("i18n/pl.po") }}`,
  a gettext file whose `msgid`s are those English words.
- **Not built yet.** There is no `register_components` option and no outside search engine
  for plugins. When a feature needs one, tell the person what is missing.

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
- **Name what you build on.** A plugin that needs another names it in `depends_on`
  (`.depends_on = .{"orders@^0.3"}`: exact `1.2.3` or caret `^0.3`); one it only uses when
  present goes in `compatible_with`. Each operation of theirs you call or hook is a
  `publr.remote.operation("inventory.reserve", Sends, Reads)` in your `.remotes`, in your
  own words, with only the fields you use; `publr.remote.record("products.variant",
  Fields)` reads their records and `publr.remote.event("inventory.out_of_stock", Payload)`
  hears their events the same way, listed in `.remotes` too. `publr event list` (`--plugin
  inventory`) shows every event plugins declare with its payload's fields and kinds,
  `publr event get --name <event>` one with the hooks on it; an operation's own event
  carries its answer (`publr <namespace> <verb> --help`). A remote that stops fitting is
  off (`error.Unavailable`), so handle that answer. Do not make a plugin whose only job is
  to connect two others; one of them owns the connection.
- **Another plugin's contracts.** `@import("orders")` works in a plugin naming `orders` in
  `depends_on` or `compatible_with`, and gives its published interface: its contracts
  (`orders.contracts.item`), never its code or types. `plugin build` makes it from the site's
  installed `orders`; to build without it, name its module: `publr plugin build --name
  booking --with orders.wasm`. `publr --as-admin plugin interfaces` shows every contract's
  parts with their input and output.
- **Parents never know their children.** A plugin others extend exposes documented
  operations and accepts hooks on them; it never names, imports or checks for the plugins
  that extend it.
- **Every plugin is as extendable as Publr.** Sites differ, so another plugin must be able
  to change anything yours decides without editing it. Operations are hookable as they
  are. A value you decide (a price, the list on offer, a total, what is left) goes
  through `ctx.mod("yourplugin.name", value)` before you use it, carrying the facts you
  decided it from, and your doc comment names the mod. Behaviour that needs settings of
  its own or calls out (live carrier rates, a payment gateway) is a contract whose
  providers are plugins, with yours as one way among them. Before calling a plugin done,
  list each decision it makes and the mod or contract that changes it.
- **A record holds only what every use of it needs.** An optional facet (a product's
  measures, its digital delivery) is a plugin of its own that adds fields to the record
  and hooks into the plugins that use them. A field some real use does without leaves the
  base; facets some use wants apart are separate plugins; fields that only mean something
  together (weight and size) stay together.
- **A plugin is its own folder.** Import `publr`, your own files and the plugins you name
  by name. Never import or copy another plugin's code, never share a folder of helpers
  between plugins.
- **When Publr cannot do something, say so.** Tell the person what is missing. Do not
  build a workaround that hides it.

**Authority**

- **The server owns the facts and the rules.** An operation reads what it decides on from
  storage. Its input is the request: a query, answers, a selection, quantities, record
  IDs. Take a record as its handle's `Ref` (`Variants.Ref`): the caller sends its id,
  core reads the stored record with the caller's access before your operation runs
  (`in.variant.value.?`), and refuses one that is unknown or not theirs to see. Never
  records' contents, prices, rules or policies sent by the caller: a visitor can send
  anything.
- **Pages show and collect.** A page never gathers data to send to an operation for it to
  trust, and never calls an operation only so a check appears to happen.
- **One transaction.** A write, the hooks it runs and the calls it makes commit or roll
  back together. A call you catch an error from undoes only its own changes. Do not call
  outside services from a write: nothing undoes them if it rolls back.

**Data**

- **Content is what goes live in versions.** Model it as content types when it is
  published, keeps versions, or is read by visitors as public or private records:
  products, variants, orders, pages.
- **Everything else is internal records.** Carts, holds, ledgers, logs, a plugin's
  settings, and what people manage that never goes live in versions (an A/B test, a tax
  class), through admin pages of your plugin over its own operations: declare each kind as
  a record with `.internal = true` and `.indexed` for the fields it is found by
  (`publr.record.define(Movement, .{ .name = "stock.movement", .internal = true, .indexed =
  &.{.stock} })`), and use its handle. They never show in the admin's Content, reach only
  your plugin's records in the request's app, and need no permission.
- **Use the field kinds.** The Zig type decides the kind: `[]const u8` is `string`, an
  integer `integer`, a float `number`, `bool` `boolean`, an enum `select`, `publr.Time`
  `datetime`, `publr.Decimal(n)` `decimal`, `publr.Money` `money` (`{ "GBP": 850 }`, minor
  units, in the site's currencies; a template writes it with
  `Publr.build.money(product.data.price)`), a handle's `Ref` `reference`, `publr.Account`
  `user` (found with `find_one(ctx, .owner, account)`), a struct `group`, a list of structs
  `repeater`. Other kinds are named in `.fields` (`.body = .{ .kind = "text" }`): `text`,
  `richtext`, `slug`, `email`, `url`, `media`, `terms`, `embed`, `color`, `time`,
  `password`, `link`, `location`. Never a record ID in a `string`, never JSON in a `text`,
  never a time or a price as a number. A code a person must not guess (a pickup code, a
  voucher) comes from `try ctx.random(&buffer)`, never from hashing an id.
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

This compiles `plugins/guestbook/main.zig` against the site's release with the compiler
the `publr` command carries (no Zig needed), then installs it: a new plugin is added and
enabled, one already there gets this as its next version, the previous kept to roll back
to. When the compiler reports an error, fix the source and run it again. To change a
plugin, edit it, raise `.version`, and build again. Built again unchanged, it says it is up
to date. When it says it builds "without" something (an `extend`, an operation that takes
the host's context), that part does not run in the sandbox; calls to it answer unavailable.

**Examples are its tests.** Each `Example:` is compiled against the shapes (its `in:` and
`out:` must fit them) and run when the plugin builds: against an empty site with only the
plugin and those it names in `depends_on` and `compatible_with`, called by an
administrator. It passes when the answer has the `out:` shape, or when the call is refused
for what an empty site lacks (nothing found, the plugin's own failure); a refusal of the
example's own input fails the build. So write examples an empty site answers
(`{ "currency": "PLN", "lines": [] }`, not an id that must exist). The `publr` command
builds only the module: it runs no Zig `test` blocks. Check the rest on the running site:
call each operation as the people who will (`publr --as <email> booking cancel --booking
<id>`, a visitor's call with `curl` as below), read what it kept (`publr --as-admin internal
find --plugin booking --kind booking`), and read `publr --as-admin plugin log --name booking` and
`publr errors list`.

```sh
publr --as-admin plugin get --name guestbook     # version, what it asked for, what waits
publr guestbook --help                           # the plugin's own commands
curl -X POST http://127.0.0.1:8080/api/guestbook.sign \
  -H 'content-type: application/json' -H 'origin: http://127.0.0.1:8080' \
  -d '{"name":"Ada","message":"hi"}'             # one for untrusted callers, as a visitor
```

**A test clock.** Work that waits for a date (a month's billing, an overdue request, a lapsed
cart) is tried by moving the site's clock:
`publr --as-admin project set_clock --ahead_ms 2678400000` (31 days on), `--at_ms <ms>` (a
moment), `--reset` (back to the wall clock). `ctx.now()`, queued work's moments and the
queue worker read it, so what falls due runs. Only on a test site: one on this computer,
served over plain http; sign-ins keep the wall clock.

## Admin pages for a plugin

A plugin's own settings are an internal record of its own, one record, and a page the
admin draws from its read and save operations: never a content type, since nothing in them
goes live in versions.

```zig
/// Settings
///
/// How workshops are sold.
pub const Setting = struct {
    /// Seats one buyer may book at once
    seats_max: i64 = 10,
};

pub const Settings = publr.record.define(Setting, .{
    .name = "workshops.settings",
    .internal = true,
    .fields = .{
        .seats_max = .{
            .validation = .{
                .min = 1,
                .max = 100,
            },
        },
    },
});

const kept_settings = publr.query.prepare(
    \\*[_type == "workshops.settings"][0...1]{ "id": _id, seats_max }
, .{});

pub const Kept = struct {
    id: []const u8,
    seats_max: i64 = 10,
};

pub const Nothing = struct {};

pub const SettingsOut = struct {
    /// Seats one buyer may book at once
    seats_max: i64,
};

/// Reads the settings
///
/// Administrators, and roles granted it. Changes nothing.
///
/// Example:
///   in: {}
///   out: { "seats_max": 10 }
pub const ReadSettings = publr.operation.define(Nothing, SettingsOut, .{
    .name = "settings",
    .kind = .read,
    .run = read_settings,
});

fn read_settings(ctx: *publr.Ctx, _: Nothing) publr.Error!SettingsOut {
    const found = try kept_settings.execute(ctx, []const Kept, .{});

    return .{
        .seats_max = if (found.len == 0) 10 else found[0].seats_max,
    };
}

/// Keeps the settings
///
/// Administrators, and roles granted it.
///
/// Example:
///   in: { "seats_max": 4 }
///   out: { "seats_max": 4 }
pub const SaveSettings = publr.operation.define(SettingsOut, SettingsOut, .{
    .name = "save_settings",
    .kind = .write,
    .run = save_settings,
});

fn save_settings(ctx: *publr.Ctx, in: SettingsOut) publr.Error!SettingsOut {
    const found = try kept_settings.execute(ctx, []const Kept, .{});

    if (found.len == 0) {
        _ = try Settings.create(ctx, .{
            .seats_max = in.seats_max,
        });
    } else {
        const held = try Settings.get(ctx, found[0].id, .{});

        try Settings.save(ctx, held, .{
            .seats_max = in.seats_max,
        });
    }

    return in;
}

/// Shop › Settings › Workshops, or a tab of System settings without the shop.
const settings_page: publr.plugin.Page = .{
    .path = "settings",
    .label = publr.t("Workshops"),
    .icon = "settings",
    .form = .{
        .read = ReadSettings,
        .save = SaveSettings,
    },
    .parent = &.{ "products.settings", "core.system" },
};

// in define: .records = &.{Settings}, .operations = &.{ ReadSettings, SaveSettings },
// .pages = &.{settings_page},
```

A page declared with `.form` needs no views: the admin draws the form from `save`'s input
(each field's `///` is its help), filled from what `read` answers. A page of your own
starts from a working one:

```sh
publr --as-admin plugin scaffold --name notes --page list   # or --page form
```

It answers every file of a plugin with a page (`{ path, content }`); write them into
`plugins/notes/` and run `publr plugin build --name notes`. The page is shown in the plugin
frame, looking like the admin's own. Keep it that way:

- **A page is a read.** `.pages = &.{.{ .path = "bookings", .label = publr.t("Bookings"),
  .icon = "calendar-check", .operation = Page }}`: `Page` takes `base` and `query` (the
  page's query string, `booking=<id>`) and answers `html` from
  `publr.views.render(ctx, in.base, publr.views.all.BookingsPage, props)`, a view in
  `ui/BookingsPage.ptsx`. Integers in props arrive as numbers at any depth. `.menu = .none`
  keeps a page out of the menu (one opened from a list); `.parent` makes it a tab of a
  tabbed page.
- **Compose, never style.** The view returns one admin layout (`IndexPage`, `FormPage`,
  `PanelPage`), its only root, and fills it with the design system's composites:
  `IndexSection`, `FieldRow` for each field (label, required mark, help), `ItemList` for a
  list of linked items (move, remove, a place to add), `StatusStrip` for the status line,
  `Button`, `Input`. Set no spacing or colours of your own; a status tone is one of neutral,
  success, warning, error, accent, review, info (the build refuses others).
- **Data through `publr/operations`.** `call("notes.add")` writes through one of the
  plugin's operations (call it with the input; it has `isPending` and `error`);
  `query("notes.list")` reads reactively and reads again after every write (with
  `{ seeded: true }` when the page's server render already drew it, so it reads only
  once a write makes it stale); ``query(groq`*[_type == "notes_entry"]`)`` reads GROQ as
  the plugin may. No `fetch`, no tokens: in the frame both go through the admin, which runs
  only what the plugin may. State that changes is `Publr.reactive({ ... })`, updated in
  `Publr.effect`. Table rows with buttons in them, `onClick={() => cancel(item.id)}`,
  `.map`, `.filter`, `.some`, `.every`, `.find` and `.join` work in a view.
- **Typed.** `publr plugin build` writes `ui/operations.d.ts`: every operation's input and
  output, so a misspelt name or field is an error in your editor.
- **Menus.** A page or a content type sits under a menu item. Declare yours,
  `.menu = &.{.{ .name = "bookings", .label = publr.t("Bookings"), .icon = "calendar-check"
  }}`; an item with `.page` opens that page, one with `.record` a type's list, one with
  neither is a heading. Others name it `<plugin>.<name>` in `.parent` (a record's
  `.menu = .{ .parent = &.{"booking.bookings"} }`, an item's `.parent`), the first that
  exists: `.parent = &.{"products.shop"}` sits under the shop's Shop and is a part of the
  admin of its own without it. The names other plugins' items carry are in their
  `main.zig`; the shop's are `products.shop` (Shop) and the tabbed page `products.settings`
  (Shop › Settings); core's tabbed pages are `core.system` (System settings), `core.users`
  and `core.ai`. An item with no parent is a part of the admin of its own, its children
  headings in its sidebar.
- **Entries, not chrome.** To put a page in the top bar, the page says `.top_bar = .{
  .count = Count }` (a read answering `count`, for a number beside it). The rail is the
  person's: nothing adds to it, and people pin your pages there themselves (`publr rail
  pin`). A record's `.data_view = .{ .columns = &.{.price}, .order = .{ .field = .price,
  .direction = .asc } }` is where its list starts; whether a field filters or sorts is the
  field's (`.fields.price = .{ .sortable = true }`). Icons of your own go in `.icons` (SVG,
  sanitized), named `<plugin>.<name>`. Removing a plugin keeps its data unless an
  administrator ticks pieces on its page; core knows all of it.
- **Panels on other types' forms.** `.panels = &.{.{ .type = "product", .label = "Stock",
  .operation = StockPanel }}` in `define` adds a box to every product's edit form, whoever's
  type it is. `StockPanel` is one of your reads taking `record` (the record's id, all it is
  told) and `base`, answering `html` from a view on the `PanelPage` layout, with `call` and
  `query` working the same. It reads what else it needs itself. Nothing on the type's side
  knows about it; without the type, there is no panel.

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
apps/courses/interactive/*.ptsx           parts that keep state in the browser
apps/courses/public/                      files served as they are, at /learn/<file>
```

`app.zon`'s `.plugins = .{ "orders", "booking" }` names the plugins an app reaches: their
operations at its `_actions` address and their components. A plugin it does not list is
denied there.

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

- **Reads go in the frontmatter.** `Publr.build.*` and `Publr.request.*` are called in the
  frontmatter, named, and the body uses the names; only `Publr.t('...')` works in the body
  too. `??` is for a value that may be missing and takes a text fallback (`?? ""`); compare
  a value that may be missing with `null`, any other with a value of its kind.
- **What a page can read.** Built pages see live records of **public** types only: give
  the plugin's record `.public = true`, and for pages per record a slug field,
  `slug: ?[]const u8 = null` with `.fields = .{ .slug = .{ .kind = "slug", .options =
  .{ .source = "title" } } }`. An entry is `id`, `type`, `slug`, `title`, `created_at`,
  `updated_at` and `data`, its fields (`lesson.data.body`).
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
- **The body** takes `{value}` (escaped), `set:html={value}` (markup, sanitized: no
  scripts, styles, frames or `on…` attributes survive), `set:markdown={value}` (a Markdown
  text field, converted to HTML and sanitized the same way), `{items.map((item) =>
  (...))}`, `{test ? (...) : null}`, and `<Component prop="..." />` with `<slot />`. A
  layout or component reads `props.name`. Keep island directives and PJSX component calls
  in the outer markup; computed JSX can embed static `.publr` components.
- **Markdown pages.** `content/faq.md` is a page: `key: value` frontmatter, `layout:
  ../layouts/base.publr` with the other keys as the layout's props, the Markdown as its
  slot. It suits writing kept with the code (docs, a changelog); words the owner edits stay
  in records.
- **Computed markup.** JavaScript expressions can generate arrays of JSX elements,
  including SVG patterns. Relative `.js` and `.ts` helpers use ES module imports.
  Static pages save the HTML; no browser JavaScript or Node installation is needed.
  Use seeded randomness. There is no filesystem, network or asynchronous rendering.
- **Per request.** A page named `<name>.dynamic.publr` renders for each visitor and may
  read `Publr.request` (`session`, `getCollection`, `call('app.<plugin>.<verb>', input)`
  for a read that allows it, answered as `.data`). A call that is refused or fails
  answers an empty `data` (`{}`) and the page still renders, so draw from
  `read.data.name ?? ""`.
- **Forms.** A form posts its fields, named as the operation's input, to
  `<mount>/_actions/app.<plugin>.<verb>`; a hidden `redirect` field (a path on this site)
  is where it goes after, else back to the page, with `?error=<Name>` added when refused.
- **A plugin's components.** A plugin brings parts pages place: `components/<Name>.publr`,
  imported as `import DatePicker from 'plugin:booking/DatePicker'`, and
  `components/<Name>.dynamic.publr`, drawn for each visitor, imported as
  `'plugin:affiliates/AffiliateAccount.dynamic'` and placed with `dynamic`
  (`<AffiliateAccount dynamic here="/account/affiliate" />`): the page that places it need
  not be `.dynamic`. `interactive/<Name>.ptsx` in a plugin is imported as
  `'plugin:<plugin>/<Name>.ptsx'`. The app must list the plugin in `.plugins`.
- **Interactive components** (`interactive/*.ptsx`, PJSX that keeps state in the browser)
  are built when the app loads. `middleware.zig` still needs a build of Publr: an app
  loaded from a folder has none. For code on the server, a plugin.
- **Links** never write the app's mount: start them with `Publr.build.base()` (`/learn`,
  empty at the root or on its own host), so `${base}/lessons` follows the app wherever it
  moves. `Publr.build.baseUrl()` is the app's full address, for canonical links, sharing
  and emails. Whoever runs the site can give an app a host of its own in
  `apps/addresses.zon`; never edit that file by hand on a hosted site.

A running `publr serve` watches the apps folder: save a file and the change is live within
half a second, a stylesheet included. A change that does not compile is refused, the
version before it keeps serving, and the server prints why. To see that reason yourself,
or to wait for the change before you check a page, run:

```sh
publr apps load
```

A `<script>` in a template is written out exactly as it is, with no `{expressions}` filled
in. Structured data takes `set:json`, which writes a value as JSON a script holds safely:
`<script type="application/ld+json" set:json={{ "@type": "Product", name: product.title }} />`.
HTML from a field (`set:html`) is sanitized and never carries a script.

## A second language

Content languages come from the `languages` plugin. When `publr languages --help` does not
answer, install it from Publr's marketplace (`publr plugin install --name languages`, then
`publr job answer --id <asked>` until it is `done`). The admin's own language is separate: a
language pack such as `language_pl` makes the admin speak Polish. Never stand in for a
language with separate fields or pages per language.

```sh
publr languages save --languages '[{"code":"pl","name":"Polski","main":true},
  {"code":"en","name":"English","address":"/en"}]'
```

The main language is at `/`, every other at its address. A content type's field holds a
value per language when it lists `"dimensions": ["language"]` (`content_type create` or
`update`); a value in a language is the field's name with the language,
`"title@language=en"`, written beside `title` in the same record. One template serves every
language: `/en/about` is the `/about` page read in English, its links keep `/en`. A
plugin's own records cannot be translated yet. Taking `language` off a field drops its
translations, so `content_type update` asks for `--drop_content`. `--language` on an
account is the admin's language, not the site's.

## Permissions: declare, never grant

Anything beyond its own records and operations, a plugin asks for in `define`, a key with
yes/no flags and a reason:

```zig
.permissions = &.{
    .{
        .key = "records.read",
        .reason = "Lists the posts on the notes page",
    },
    .{
        .key = "records.write",
        .publish = true,
        .reason = "Puts new prices live",
    },
    .{
        .key = "http.fetch",
        .domains = &.{"api.supplier.com"},
        .reason = "Fetches prices",
    },
    .{
        .key = "call:orders.charge_more",
        .reason = "Charges each month of a contract on its own line",
    },
},
```

The keys: `records.read` (`.records`; `.drafts`, `.private`, `.internal`), `records.write`
(`.records`; `.publish`), `records.destroy` (`.records`), `project.put` (anything the
project stores exactly as another copy of it keeps it, ids kept), `terms.read`
(`.taxonomies`; the read flags), `terms.write` (`.taxonomies`; `.publish`), `schema.read`,
`schema.write`, `users.names`, `users.read`, `users.write`, `users.own` (accounts of the
plugin's own user types), `site.read`, `settings.write`, `http.fetch` (`.domains`),
`mail.send`, `media.read` (`.private`), `media.write`, `request.read`, `request.redirect`,
`messaging.send`, and `call:<plugin>.<verb>` for another plugin's operation. Reading starts
at what a visitor sees; name the types you need in `.records` rather than asking for every
one. Without `.publish` a write makes drafts and asks for transitions to live (`.pending`).
A domain is exact (`api.supplier.com`, no subdomains implied), `*.supplier.com`, or `"*"`
for any public address; production refuses local and private addresses whatever is listed,
and redirects stay within the domains. Any other key or option fails the build. They are
requests: the administrator may refuse any of them, and `ctx.grant(key)` says what the
plugin got (`.domains` for `http.fetch`). Hooks and modifiers are requests too, each with
its `///` as the reason.

A secret is not a permission: it is a field of a `.secrets` struct, its `///` the label
and where to find it, written into a request as `{secret:NAME}`; the plugin never holds
its value. Declare every one you write (an undeclared one fails the build) and ask for
`http.fetch`. The administrator fills it in at install or later on the plugin's page;
until then a request naming it is refused: "Supplier API key isn't set".

The build tells you when one is missing: calling an operation none of the plugin's
permissions opens fails to compile, naming the key to add. `publr agents` ends with every
key there is, its tier, and the operations it opens. Low and medium ones are granted when
the plugin is installed; high ones wait for a person. **Never grant anything yourself**
(`plugin grant`): that decision is the administrator's. When something waits, finish by
telling them what it is, why the plugin needs it, and that they approve it in the admin
under Settings > Plugins. A call the plugin was not granted answers `Denied`; handle it, so
the plugin still works without it.

## Emails and text messages

Publr sends nothing on its own: a plugin emits a message, and a messaging provider plugin
(`smtp`, `email_ses`, `email_cloudflare`) sends it from the queue after the write commits.
With none installed nothing is sent and nothing fails. Ask for `messaging.send`:

```zig
ctx.emit(publr.messaging.Email, .{
    .to = "ada@example.com",
    .subject = ctx.t("Your booking", .{}),
    .text = ctx.t("See you on {day}.", .{ .day = day }),
});
ctx.emit(publr.messaging.Sms, .{
    .to = "+48600100200",
    .text = ctx.t("Pickup code {code}", .{ .code = code }),
});
```

`Email` also takes `html`, `preheader`, `from`, `reply_to`, `attachments` (the site's
media by id) and `stream` (`marketing` needs `unsubscribe`); `publr.messaging.Push` takes
`to`, `title`, `text`, `url`. A shop's emails about an order are the shop's: see Selling.

**Testing emails.** On a site on this computer, install the `email_inbox` plugin (Local
inbox): it sends nothing and keeps every email, text message and notification on the site.
Read them in the admin under Local inbox, or check what an address got:
`publr email_inbox messages --to ada@example.com --subject "order"` answers each message
with its HTML, text and details. It keeps messages only on a development site (this
computer, plain http, not hosted, not a copy); elsewhere mail goes to the next provider. To
try the real `smtp` plugin, run Mailpit or MailHog and set it up under Settings › System ›
Email: server `127.0.0.1`, port `1025`, security none, no user name; read what arrived at
`http://127.0.0.1:8025`.

## Counted balances: the ledger

When something is a count per holder that changes only by recorded moves (store credit, gift
cards, points, credits, what someone owes or is owed), keep it on Publr's ledger, never in a
record's number field.

- Declare it once: `pub const Ledger = publr.ledger.define(struct { ... }, .{ .reasons =
  Reason, .units = Units })`, each account name a field (`held:
  publr.ledger.Liability(.{ .never_below_zero = true })`), each with a `///` line; list it in
  `define` as `.ledger = Ledger`.
- Open accounts on first use: `Ledger.open(ctx, .held, .{ .holder = .{ .person = account },
  .unit = publr.ledger.unit("loyalty.points") })`. Keep one in a record as a
  `publr.ledger.Account` field.
- Move with `Ledger.transfer(ctx, .{ .id, .debit, .credit, .amount, .reason })`, give every
  move an id of your own made from what it is for (`"earned-{order}"`): a retry then does
  nothing. Use `hold` then `post_hold` or `void_hold` for money set aside, `chain` for steps
  that stand or fall together, `reverse` to take back.
- Catch refusals by name after `error.Failed`: `ctx.failure()` is `Overdrawn`, `NotYours`,
  `Taken`, `UnitMismatch`, and so on.
- Read with `publr.ledger.balance`, `history`, `find` (everything about a record) and
  `totals`. Another plugin's accounts need `.{ .key = "ledger.read", .plugins = &.{"orders"},
  .reason = "..." }`; you move another plugin's account only inside its call to you, when it
  hands it over.
- Nobody types a transfer in the admin. Each plugin's accounts are on its Ledger tab under
  Plugins, all of them in Settings › Ledger with a Check of the books; `publr ledger accounts`,
  `history`, `totals` and `check` read the same.

## Selling: orders and money

A shop is Publr's commerce plugins from the marketplace: `orders` (carts, orders, their
lines and charges, its books on Publr's ledger), `payments`, `tax` with a
country's law (`tax_pl`), and on top of them `products`, `inventory`, `shipping`,
`discounts`, `customers`, `checkout`, `bank_transfer`, `cash_on_delivery`. Anything can be
sold: each way of selling is a plugin providing `orders`' contracts. `publr orders --help`
lists every operation with its input, output and failures; `publr --as-admin plugin
interfaces` every contract part's shapes.

**Rules.** Each one is also what the base holds you to.

- Amounts come from the server: an item type's `price`, a rule, a gateway's word, a sale
  imported as it happened, or staff with a reason. A page sends references and quantities,
  never a price or a total, and never adds money up.
- A plugin changes money only on its own lines and its own ledger accounts. Anyone else
  asks the line's plugin. To book money with the shop, hand `orders` your own account by
  calling it (`orders.pay`, `orders.cost`, `orders.settle`): it moves that account for that
  call only.
- Nothing that holds money is edited or deleted: it is adjusted, reversed or corrected,
  and paid or fulfilled orders are archived, never deleted.
- Every write that moves money takes an `id`, the caller's idempotency key: sent again it
  changes nothing.
- Nothing outside Publr is called while a cart is calculated: `price`, options, fees,
  codes and rules only read and answer. Outside calls go in jobs and event hooks.
- Money is whole minor units of one currency. In operations, yours and other plugins',
  it is `publr.Money`: `try publr.Money.of(ctx.arena(), "PLN", 12300)`, `price.get("PLN")`;
  JSON writes it `{ "PLN": 12300 }`. In a contract's parts it is an `i64` of the `currency`
  beside it, its `///` saying `Why:`. A quantity is `publr.Decimal(6)` in the item's unit,
  written `"2"` or `"0.350000"`.
- Money counts as received only from a payment method's signed confirmation, a manual
  record by staff for a method that allows one, or a set-off (store credit).
- Refunds go back along the payments that paid what is refunded, never more than was
  paid for it, and count only once the method says the money left.
- An amount is claimed by at most one document of a kind.

**Words.** Shopify's where they exist.

| Word | Meaning |
|---|---|
| Item type | A provider of `orders.item`: what one plugin sells (`products`, `workshop`) |
| Line | An item in a cart or order: its item type, the item by id, a quantity, the type's data. Lines nest (a meal, the burger in it) |
| Cart | An order not placed yet, calculated again on every change. Staff build **draft orders** |
| Order | Placed lines, charges, payments, refunds and documents. Status: open, complete (paid and no plugin reports work left), archived. Money status: unpaid, partly paid, paid, partly refunded, refunded, overpaid |
| Charge | What the buyer owes for a line or the order, with its **facts**: nature, kind of supply, seller, tax class, places, buyer. Facts left out come from the item type's declaration |
| Nature | What an amount is: `price` (almost always), `free_supply`, `collected` (for someone else), `deposit`, `compensation`, `penalty`, `interest`, `forfeited_deposit`, `tip`, `donation`, `voucher`. It decides whether VAT applies and whose money it is |
| Payment request | A payer asked for an amount of an order, per charge, by a due date, valid until a time; ends paid, cancelled or lapsed. Past its due date it is overdue |
| Allocation | Which charges a payment paid. Money no charge takes is unallocated: owed to the payer |
| Adjustment | A change after the sale, either way, with a kind and a reason code |
| Work left | What a plugin still does for a line (send it, cook it); it keeps the order from completing |

### Sell something: an item type

Provide `orders.item`. Each part is one of your operations, in your own words: its input
names only the fields of the part's you use (the rest are left out of what it reads), and
its output gives every field the part reads that has no default. `@import("orders")` gives
the contract, not its types. A part is called by `orders` alone: give it
`.authorize = publr.authorize.plugin_calls` and check the caller is `orders`, as `price`
does below.

| Part | Needed | Asked | Answers |
|---|---|---|---|
| `declare` | yes | once, at install, kept | kind of supply, tax class, nature, unit, seller and capacity, gross or net pricing, special-category lines, its line data (`DataField`s) |
| `price` | yes | on every calculation; read only | per line: `title`, `option`, `sku`, `unit`, `available` and `problem` ("Sold out"), `charges` (amount, and only the facts that differ: nature, tax class, kind of supply, `supply_at`), `requests` it wants for the line when placed (a deposit now, the rest later) |
| `on_add` / `on_remove` | no | a line added to or taken from a cart | take or give back what you hold (stock, a seat); a `problem` refuses; `parts` puts other types' lines under yours |
| `on_changed` | no | a line's quantity or data changed in the cart (`orders.change`), with what it was before; without it you hear `on_add` again | move what you hold to the new quantity or dates, or refuse with a `problem` |
| `on_placed` | no | your lines went into an order (`orders.place`, a draft placed by staff), inside the placing write, with the order, its currency and your lines | what you held for the cart becomes the order's (confirm the dates, give a charge its period, queue the next month) |
| `on_part` | no | a caller puts a line under one of yours | refuse it, or say you price it (`priced`) |
| `on_paid` | no | the order became paid in full | hand over, open the door, send to the kitchen |
| `decide_adjust` | no | someone else asks to reduce or cancel your line (with the `amount` asked and what is `left` of it) | refuse, or grant an `amount` and a `fee` |
| `on_adjusted` | no | your line was adjusted | free what it held |
| `on_lapsed` | no | a cart lapsed, or a payment request on your lines lapsed | release, remind, cancel |
| `on_refund` | no | a refund of your lines was asked | restock, revoke |
| `search` | no | staff look for items (Create order) | items matching the words, with their price now |

```zig
//! Workshops: seats at the shop's workshops, sold through orders.
//!
//! Sells the item type `workshop` (`orders.item`): admission to an event, each seat priced
//! from the workshop's price in the cart's currency.
const std = @import("std");
const publr = @import("publr");
const orders = @import("orders");

const manifest: publr.Manifest = .{
    .name = "workshops",
    .version = "0.1.0",
};

pub const Quantity = publr.Decimal(6);

/// Workshop
///
/// A workshop people book seats at.
pub const Workshop = struct {
    /// Title
    title: []const u8,
    /// Price of a seat
    ///
    /// With VAT.
    price: publr.Money,
};

pub const Workshops = publr.record.define(Workshop, .{
    .name = "workshops.workshop",
    .public = true,
});

pub const Supply = enum {
    goods_shipped,
    goods_installed,
    goods_handed_over,
    rental,
    accommodation,
    passenger_transport,
    goods_transport,
    admission,
    restaurant,
    short_hire,
    long_hire,
    electronic,
    energy,
    intermediary,
    services,
};

pub const Nothing = struct {};

pub const DeclareOut = struct {
    /// Kind of supply
    supply: Supply = .services,
};

/// Declares a seat: admission to an event, at the standard rate
///
/// Example:
///   in: {}
///   out: { "supply": "admission" }
pub const Declare = publr.operation.define(Nothing, DeclareOut, .{
    .name = "declare",
    .kind = .read,
    // Why: core asks it as whoever calls orders while the answer is not kept yet.
    .untrusted_callers = true,
    .run = declare,
});

fn declare(_: *publr.Ctx, _: Nothing) publr.Error!DeclareOut {
    return .{
        .supply = .admission,
    };
}

pub const PriceLine = struct {
    /// The line, by id; empty in a preview
    line: []const u8 = "",
    /// The workshop, by id
    item: []const u8,
    /// How many seats
    quantity: Quantity,
};

pub const PriceIn = struct {
    /// The cart's currency
    currency: []const u8,
    /// The lines to price
    lines: []const PriceLine,
};

pub const Proposed = struct {
    /// Why: whole minor units of the cart's currency, as orders reads them.
    amount: i64,
};

pub const Priced = struct {
    /// The line, by id
    line: []const u8 = "",
    /// The workshop, by id
    item: []const u8,
    /// What it is
    title: []const u8,
    /// False when it cannot be bought now
    available: bool = true,
    /// Why not
    problem: []const u8 = "",
    /// Its charges
    charges: []const Proposed = &.{},
};

pub const PriceOut = struct {
    /// Each line, as asked
    lines: []const Priced,
};

/// Prices seats from each workshop's price in the cart's currency
///
/// Example:
///   in: { "currency": "PLN", "lines": [] }
///   out: { "lines": [] }
pub const Price = publr.operation.define(PriceIn, PriceOut, .{
    .name = "price",
    .kind = .read,
    .authorize = publr.authorize.plugin_calls,
    .run = price,
});

/// Only orders asks for prices.
fn from_orders(ctx: *publr.Ctx) publr.Error!void {
    switch (ctx.caller().from) {
        .plugin => |name| if (std.mem.eql(u8, name, "orders")) return,
        else => {},
    }

    return error.Denied;
}

fn price(ctx: *publr.Ctx, in: PriceIn) publr.Error!PriceOut {
    try from_orders(ctx);

    const out = try ctx.alloc(Priced, @intCast(in.lines.len));

    for (in.lines, out) |line, *one| {
        const held = Workshops.get(ctx, line.item, .{}) catch |err| switch (err) {
            error.NotFound, error.Invalid => null,
            else => return err,
        };
        const seat = if (held) |workshop| workshop.value.price.get(in.currency) else null;

        if (held == null or seat == null) {
            one.* = .{
                .line = line.line,
                .item = line.item,
                .title = "Workshop",
                .available = false,
                .problem = "This workshop is not sold in this currency.",
            };
            continue;
        }

        const charges = try ctx.alloc(Proposed, 1);

        charges[0] = .{
            .amount = seat.? * @divTrunc(line.quantity.units, Quantity.scale),
        };
        one.* = .{
            .line = line.line,
            .item = line.item,
            .title = held.?.value.title,
            .charges = charges,
        };
    }

    return .{
        .lines = out,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .depends_on = .{"orders@^0.3"},
    .records = &.{Workshops},
    .operations = &.{ Declare, Price },
    .register_providers = .{.{
        .contract = orders.contracts.item,
        .name = "workshop",
        .label = "Workshops",
        .operations = .{
            .declare = Declare,
            .price = Price,
        },
    }},
});
```

A page adds a seat with `app.orders.add` (`{ "item_type": "workshop", "item": "<id>",
"quantity": "2" }`), and prices items without a cart with `app.orders.preview`.

- **Line data.** Declare it in `declare` (`data`: name, label, kind, options, who may read
  it, `special` for health data, `sits_on = .line`, where it is printed); orders checks
  every value before keeping it, and `price` reads it. A price the buyer names (pay what
  you want) is line data `price` checks against its minimum. An extra with a price of its
  own (bacon, engraving) is a second charge on the same line.
- **Cart data.** What decides your price for the whole cart (eaten in, a branch) is your
  plugin's data on the cart (`orders.data`, below); `price` receives it as `data`.
- **Parts.** `on_add` may answer `parts`: lines of other item types put under yours (a
  bundle's mug and book). Each part's own type still prices it (its title, whether it can
  be bought, the charge it would take) and holds its stock, but that charge is not
  posted: your `price` is asked after it, gets the part beside your lines with its
  `item_type`, `priced_by_parent` and `amount` (what its own type priced it at), and
  answers the part's charges itself, spreading your one price by those amounts. Each part
  keeps its own type's facts, so a mug stays at 23 % and a book at 5 %. Those charges are
  yours: you adjust and refund them.

### After the order

`price` runs until the order is placed. After that, on your own lines:

| You want to | Call |
|---|---|
| Charge more for a line (an overstay, kWh, a weighed price, a month's rent) | `orders.charge_more` (`id`, `line`, `amount`, `nature`, `description`, `reason`, `tax_class`, `supply`, `supply_at`); a cart step's plugin charges on the order itself with `order` and no `line` |
| Charge the buyer a carrier's fee after the sale (a parcel taken back), as a shipment's carrier | `shipping.charge_buyer` (below) |
| Add your items to a placed order (a round of drinks) | `orders.add_to_placed` (`id`, `order`, `item_type`, `lines`) |
| Record a fact learned later (when it was supplied, a period, a lapsed right, the buyer named later) | `orders.facts` (`charge` or `line`; `supply_at`, `period_from`, `period_to`, `lapsed`, `buyer`, `buyer_status`, `buyer_vat`, `buyer_country`, `recipient`) |
| Reduce or cancel a line, or raise it | `orders.adjust` (`id`, `order`, `lines` by amount or quantity, `kind`, `reason`, `direction`) |
| Ask for money (a deposit, the rest, someone else pays) | `orders.request_payment` (`id`, `order`, `payer`, `charges` or an `amount`, `how`, `due_at`, `valid_until`) |
| Return money | `orders.refund` (`id`, `order`, `lines`); it adjusts first when nothing freed covers it |
| Give money your adjustment freed to your own charges (a weighed price's difference to a fee), or move money paid towards your own request (a deposit) | `orders.allocate`, `orders.release` |
| Report work left | `orders.set_work` (`line`, `left`, `label`) |
| Read a line you sold | `orders.get_line` |

Another plugin or staff never posts on your line: `orders.adjust` asks you through
`decide_adjust`. An adjustment never refunds by itself; `orders.refund` does.
Your own statuses (reserved, ready, checked in) stay in your records. Ask for each call
with a `call:orders.<verb>` permission and a `publr.remote.operation` in your own words.

### A charge's tax

Give each charge its facts: the kind of supply and the tax class in `declare`, and per
charge when they differ (`supply` and `tax_class` on a `price` charge or on
`orders.charge_more`). `tax` answers each charge's VAT from its class's rate, as the
country's plugin (`tax_pl`) gives it, and `orders` keeps it on the order. Publr Commerce is
not accounting software: when VAT falls due, the VAT return and the books are the
accountant's, from the documents and exports.

A charge's rate comes from its tax class as the `tax` plugin names it: empty for the
standard rate; with `tax_pl` also `reduced` (8 %), `super_reduced` (5 %), `zero` and
`exempt`. A short stay is `accommodation` at `reduced`, a monthly contract for the same
berth `rental` at the standard rate. A charge's period (a stay, a month's rent) is a fact
recorded once the line is placed: `orders.facts` with the `line` (or the `charge`) and
`period_from`, `period_to`, from your `on_placed` for the first period and, for each later
one, after the `orders.charge_more` that charges it (with the `charge` it answered).

### The cart's other parts

| You write | Contract | Its parts |
|---|---|---|
| A choice in the cart (delivery, a tip, gift wrap) | `orders.cart_step` | `declare` (its label and data), `options`, `price` (order-level charges; a charge naming a `line` takes the line's facts); optional `on_set` (take a slot or refuse), `on_placed`, `on_paid`, `on_released` (give it back when the cart lapses or the order is cancelled) |
| A fee (service, small order) | `orders.fee` | `fees`; `after_payment_method` for a fee that depends on the way of paying |
| A typed code (a discount, a gift card, an affiliate's code) | `orders.code` | `recognise` (charges, `combines`, `problem`); optional `take` and `give_back` (a code's uses, once per order), `taken` (whether you hold a code), `automatic` (discounts without a code) |
| A checkout rule (a minimum, a required detail) | `orders.rule` | `check`: `problems`, `warnings`, `required` |
| What a sale must collect (eaten in, a VAT number) | `orders.data` | `declare` (fields, who may read each, where it is printed), `required` (which this cart needs) |
| Entries on an order's timeline | `orders.timeline` | `entries` |

The calculation asks them in this order: item types, cart steps, codes, fees, rules. Each
gets the cart's `summary` (lines, its data, codes, country, account and roles, the
order-level charges so far) and reads only that. A visitor's page never writes a plugin's
cart data: your own `app.` operation does, calling `orders.set_data` with your plugin's
name.

### A discount type

`discounts` brings codes (Shop › Discounts) with `percent` and `fixed`; a type of your own
provides `discounts.type`. `reckon` gets the discount (`code`, `percent`, `amount`,
`applies_to`) and the lines it applies to (`line`, `amount` with VAT, `quantity`), and
answers what is off each line, never more than the line. It reads and returns, nothing
else. The discount's admin form offers your type by its label.

```zig
.register_providers = .{.{
    .contract = discounts.contracts.type,
    .name = "per_piece_off",
    .label = "Per piece off",
    .operations = .{
        .reckon = Reckon,
    },
}},
```

### A shipping method

`shipping` is a cart step. The buyer sees the delivery methods on offer in
`app.orders.options` and picks with `app.shipping.choose` (`{ "name": "method", "value":
"<method>" }`, then `point` or `slot` when the method asks one); each answers the
calculated cart. The shop's own methods are named by their ids and priced by a
`shipping.rule` (`rate`: flat, by weight, by subtotal, pickup; `offer` sees the whole list
and may hide, rename, reorder or reprice). A carrier's methods are named
`<provider>.<id>` (`parcel_lockers.locker`). Whether a line ships and what it weighs is
the item's plugin's answer to the `shipping.parcel` mod; whether the carrier collects cash
on delivery is `shipping.collect`'s.

A carrier provides `shipping.method` (`@import("shipping")`, with `orders` and `shipping`
in `depends_on`). Amounts are minor units of the `currency` given, weights grams, sizes
millimetres.

| Part | Needed | Asked | Answers |
|---|---|---|---|
| `quote` | yes | while a cart is priced; read only, nothing outside called | the parcel (`lines`, `grams`, `country`, `postcode`, `subtotal`, the way of paying) → `methods` (`id`, `title`, `days`, `amount`, `points` when the buyer picks a point), or none and a `reason`. Rates it keeps, refreshed by a job |
| `point` | no | the buyer chose a pickup point | `valid`, a `label`, the `point` the order keeps (name, address, hours, kind, `cod`), or a `reason`. Its picker is the provider's `.component`, `components/<Name>.publr`, drawn in the checkout's `<ProviderSlot contract="shipping.method">` |
| `create_shipment` | no | staff make a shipment on the order's page (`shipping.create_shipment`), inside that write | given `shipment` (asked again with it, make nothing new), `order`, `number`, `method`, `point`, `recipient` (name, email, phone, address), `parcels`, `cod`: answer `reference`, `tracking`, `tracking_url`, `label`, or a `problem`. A label from an outside service is made by your job (`ctx.enqueue`): answer empty now |
| `cancel`, `track` | no | staff cancel a shipment, or read where it is | by `shipment`, `reference`, `tracking`: `cancelled`, or `status` and `events` |
| `protocol`, `courier_pickup` | no | staff hand shipments over, or book a courier for a `day` | a `reference` and a `document`, or a `problem` |

Afterwards the carrier tells shipping with `shipping.update_shipment` (`shipment`, and any
of `reference`, `tracking`, `tracking_url`, `label`, `state`, `events`). The first time a
shipment is `sent` its lines are reported sent and `shipping.sent` is raised (`order`,
`shipment`, `carrier`, `carrier_label`, `tracking`, `tracking_url`, `lines`, `sent_at`);
`delivered` reports them delivered. A fee the buyer owes the carrier later (a parcel
nobody collected) is `shipping.charge_buyer` (`shipment`, `id`, `currency`, `amount`,
`description`, `reason`): the carrier decides the amount and shipping charges it on the
order; never sell an item type for it.

### A payment method

Provide `payments.method`: `describe` (title, `ready`, whether staff may record its
payments by hand, the channel, whether its refunds count as sent when asked, test mode),
`settings` and `save` (its page under Shop › Settings › Payments), `methods` (the ways it
offers now, each with an `instrument`: card, transfer, BLIK, cash). Optional: `pay_now`
(what the buyer is told, a `redirect`, `valid_until`), `terms` (days to pay), `refund`
(send money back; asked from a job), `check` (asked when a notification is late),
`cancel` (the buyer chose another way). Its money arrives only through its webhook:

```zig
/// What the gateway sends once a payment went through.
pub const Paid = struct {
    /// The gateway's id for the payment
    id: []const u8,
    /// The order paid, by id
    order: []const u8,
    /// Its currency
    currency: []const u8,
    /// Why: whole minor units of the currency beside it, as the gateway sends them.
    amount: i64,
};

pub const PaymentsConfirm = publr.remote.operation("payments.confirm", struct {
    id: []const u8,
    order: []const u8,
    amount: publr.Money,
}, struct {
    payment: []const u8,
    made: bool,
});

fn paid(ctx: *publr.QueueCtx, event: Paid) publr.Error!void {
    const amount = publr.Money.of(ctx.arena(), event.currency, event.amount) catch {
        return error.OutOfMemory;
    };

    _ = try ctx.call(PaymentsConfirm, .{
        .id = event.id,
        .order = event.order,
        .amount = amount,
    });
}

/// Payments the gateway confirms, signed with its key.
pub const PaidHook = publr.webhook.define(Paid, .{
    .name = "paid",
    .secret = "GATEWAY_KEY",
    .signature = .{
        .hmac = .{
            .header = "Gateway-Signature",
            .prefix = "sha256=",
            .encoding = .hex,
        },
    },
    .delivery_id = .{
        .field = "id",
    },
    .run = paid,
});
```

with `.webhooks = &.{PaidHook}`, `GATEWAY_KEY` in `.secrets`, and `http.fetch` for the
gateway's domain and `call:payments.confirm` in `.permissions`. Verify against the
attempt you recorded, never the order's total today, and take every verified payment:
extra money is owed to the payer. A refund waits for the
gateway's word, passed on with `payments.refund_settled`; a refund made in the gateway's
own dashboard is `payments.refunded_outside`; a chargeback is `payments.reverse`.
`payments.schedule` decides what is due now and later, `payments.rule` which ways a cart
may use, `payments.surcharge` (the country's law) which instruments may carry a fee.

### A document provider

Provide `orders.document`: `declare` answers the kinds it issues (`invoice`, `simplified`,
`advance`, `settlement`, `correction`, `receipt`, `summary`, `note`, `pro_forma`,
`self_billed`) and its environments (`live`, `test`); optional `issue` answers the staff's
"Issue now". Record each document with `orders.issue_document`, sending only references:

```json
{ "issuer": "my_invoices", "reference": "op-77", "kind": "invoice", "pending": true,
  "claims": [{ "claimed": "charge", "id": "<charge id>" }] }
```

Orders reads every amount from its own records, keeps the claim (one document of a kind
per amount; a pro forma claims nothing) and refuses another seller's or another buyer's.
Record it pending before you call the service; afterwards `orders.confirm_document` (its
number and external id) or `orders.reject_document`. After an unclear answer never send
again: find it with `orders.document_by_reference`. A test order (paid with test money)
gets test documents only. A document is never changed: a correction is another one.

### The order's emails

The emails about an order are the shop's: listed under Shop › Settings › Emails, where the
shop writes their words. A plugin adds its own to the list with the `orders.emails` mod and
sends one, once per `key`, with `orders.send_email` from its queued work:

```zig
/// Who an email goes to: `recipient` is whoever gets the order (the recipient at their
/// email when the order names one, else the buyer).
pub const To = enum { buyer, shop, recipient };

pub const ValueDoc = struct {
    id: []const u8,
    label: []const u8,
    sample: []const u8 = "",
};

pub const Described = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    to: To = .buyer,
    subject: []const u8,
    preheader: []const u8 = "",
    body: []const u8,
    values: []const ValueDoc = &.{},
};

pub const Emails = struct {
    emails: []const Described,
};

/// Adds the email telling whoever collects a parcel where it waits
fn listed(ctx: *publr.Ctx, emails: *Emails) publr.Error!void {
    const values = try ctx.alloc(ValueDoc, 1);

    values[0] = .{
        .id = "code",
        .label = ctx.t("Pickup code", .{}),
        .sample = "042917",
    };

    const all = try ctx.alloc(Described, @intCast(emails.emails.len + 1));

    @memcpy(all[0..emails.emails.len], emails.emails);
    all[emails.emails.len] = .{
        .id = "parcel_waiting",
        .label = ctx.t("Parcel waiting", .{}),
        .to = .recipient,
        .subject = ctx.t("Order {number} is waiting", .{}),
        .body = ctx.t("Your pickup code is {code}.\n\n{shop}", .{}),
        .values = values,
    };
    emails.emails = all;
}

pub const Value = struct {
    id: []const u8,
    value: []const u8,
};

pub const SendEmail = publr.remote.operation("orders.send_email", struct {
    email: []const u8,
    order: []const u8,
    key: []const u8,
    values: []const Value = &.{},
}, struct {
    sent: bool,
});

// in define: .hooks = &.{publr.modify("orders.emails", listed)}, .remotes = &.{SendEmail},
// and `call:orders.send_email` in .permissions; from a job or a `publr.on` hook:
// _ = try ctx.call(SendEmail, .{ .email = "parcel_waiting", .order = order, .key = parcel,
//     .values = &.{.{ .id = "code", .value = code }} });
```

The order's own values (`{number}`, `{name}`, `{shop}`) fill in beside yours. A text
message goes out as `publr.messaging.Sms` (Emails and text messages, above).

### Reading money

| Read | Gives |
|---|---|
| `orders.get` | an order's number, buyer, `email`, `currency`, total and due (money maps), money status, who gets it (`ship_to`, with the recipient's `email` when given), and your plugin's data on it |
| `orders.money` | one order: charges with their facts, payments, refunds, costs, adjustments, documents, net |
| `orders.requests` | an order's payment requests, and whether any is overdue |
| `orders.allocations` | which charges each payment paid |
| `orders.buyer_balance` | what a buyer owes, or is owed, across all their orders; a signed-in buyer reads their own |
| `orders.store_credit` | a payer's store credit |
| `publr.ledger.balance`, `history`, `find`, `totals` | your own ledger accounts; an order's whole money story with `find` about it needs `ledger.read` on `orders` |
| `orders.money_between` | moves across orders between two dates, by kind; administrators and the Reports role |

Follow what happens with events (`publr.remote.event`, hooked in `.hooks`; with `publr.on`
they run as queued work, so they may call out): `orders.paid`, `orders.completed`,
`orders.posted` (`what`: charge, adjustment, payment), `orders.allocated`,
`orders.released`, `orders.request_ended`, `orders.refund_requested`, `orders.refunded`,
`orders.refund_failed`, `orders.credited`, `orders.payment_reversed`,
`orders.document_issued`, and every operation's own (`orders.place`, `orders.facts`).
`publr event list --plugin orders` shows each one's payload. Check again when a delayed
step runs ("not if paid since"), and record which order each run was for, so nothing runs
twice.

### Money with others

| The money is | You call |
|---|---|
| Collected for someone (a consignor sold through you, city tax, tips) | set the charge's seller or shares with the `orders.charge` mod, or `owed_on` on `orders.charge_more` |
| Owed to someone for what they supplied (a label, a fee, a commission, goods on consignment) | `orders.cost` (`id`, `kind`, `amount`, your `account` as a `publr.ledger.Account`, `order`, `line`): debits the shop's costs of that kind, credits your account; answers the `transfer` |
| Taken back (a commission on a return) | `Ledger.reverse(ctx, .{ .id, .transfer, .amount, .reason })` on the cost's transfer: it was made for you, so you reverse it |
| Settled with them (a payout by bank transfer or in cash, money collected from them) | `orders.settle` (`id`, your `account` for them, `amount`, `way`: `pay_out` or `collect`, `through`: `bank` or `cash`): the other side is the shop's own bank or cash, an account of `orders` |
| Moved between your own accounts | `Ledger.transfer` or `Ledger.chain` (steps sent together post whole or not at all) |
| Paid by someone else for the buyer (an insurer) | `orders.request_payment` with them as `payer`; the money goes onto the buyer's receivable |
| Sold to someone other than the order's buyer (a recipient charged at pickup) | `orders.facts` with the charge's `buyer`, then `orders.request_payment` for it: a payment towards that request is on their receivable |
| Owed to the payer, as store credit with consent | `orders.credit`, spent with `orders.spend_credit` |

Declare an account for a party on your own ledger (`owed: publr.ledger.Liability(.{})`,
`.never_below_zero = true` when it may not go under) and open it with
`Ledger.open(ctx, .owed, .{ .holder = .{ .record = party }, .unit = publr.ledger.unit("PLN") })`;
keep it on the party's record as a `publr.ledger.Account`. A payout pays an account's
balance, never a list of commissions, so a clawback after a payout nets in the next one
(on an account that may go below zero). Whether a cost comes
back when a sale is adjusted is your choice: hook `orders.posted` and reverse it, or not.

### Changing what the base decides

| Mod | Over | Changes |
|---|---|---|
| `orders.charge` | `ChargeFacts` | a charge's facts you own: seller, buyer's status, voucher kind. Never its amount |
| `orders.price` | `LinePrice` | a line's price for the signed-in buyer (a price list, a member price) |
| `orders.allocation` | `Plan` | which charges a payment pays (oldest first) |
| `orders.release` | `Releasing` | which payments an adjustment frees (newest first) |
| `orders.emails`, `orders.email` | `Emails`, `Email` | the order emails (above), and one as it goes |
| `products.price`, `products.adjust` | | a variant line's price (options, extras); what a request to adjust it is granted |
| `discounts.applies` | `Applies` | which lines a discount applies to |
| `shipping.parcel`, `shipping.free_from`, `shipping.collect` | | what ships and weighs, the free-delivery threshold, cash collected on delivery |
| `tax.pricing`, `tax.chosen` | | gross or net pricing, the rate code a charge is taxed at |
| `customers.buyer_status`, `checkout.asks`, `inventory.left` | | business or consumer, what checkout asks, stock shown |

A modifier takes a struct of only the fields it reads and changes
(`publr.modify("orders.charge", set_seller)`, `fn (ctx: *publr.Ctx, charge: *ChargeSeller)
publr.Error!void`). It never writes or calls out. Tax exemption is never a toggle: set the
buyer's status and VAT number; the country's law decides.

### Building a checkout

`checkout` is the shop's own flow; any other calls the same public operations, from pages
at `<mount>/_actions/app.orders.<verb>`. Each answers the whole calculated cart: draw what
you get.

| Operation | Does |
|---|---|
| `app.orders.cart`, `app.orders.view` | open the visitor's cart; read it |
| `app.orders.add`, `change`, `remove` | lines: `item_type`, `item`, `quantity`, `parent`, `data` |
| `app.orders.options` | the cart steps' options (delivery methods) |
| `app.shipping.choose` | the delivery method, pickup point or slot |
| `app.orders.apply_code`, `remove_code` | a code |
| `app.orders.set_customer`, `set_recipient`, `set_method` | who buys, who gets it (a recipient may have an `email`: a gift's pickup code goes there), how they pay |
| `app.orders.preview` | price and availability of many items without a cart (a seat map, a calendar) |
| `app.orders.place` | place the cart; paying starts with `payments.start` (`app.checkout.place` does both) |
| `app.orders.last`, `app.payments.last` | the confirmation page's order and what the buyer was told |

Staff: `orders.draft`, the same operations on the draft, `orders.override` (a price, with a
reason), `orders.place_for`. A sale made elsewhere (a till offline, a marketplace) comes in
with its own amounts through `orders.import_sale`.

## Working on a Publr elsewhere

When the project runs on another machine (a server, Publr Cloud), sign in to it as a
device, then send it commands:

```sh
publr login https://example.com          # prints a link; your person approves you there
publr --site https://example.com record list --type post
publr --site https://example.com --help  # its own commands, plugins included
publr whoami                             # whose device this is, and what it may do
```

Where the site keeps copies (environments and branches), work on one unless your person let
you write on production. Make one for each task and name it on every command; in it you may
do anything, publishing included, and visitors see none of it until the person merges it:

```sh
publr --site https://example.com environments create --kind branch --name "Recipes section"
publr --site https://example.com --env recipes-section record list --type post
```

When you are done, always end with the `merge` address that making it answered: they
review the branch there and merge it. A self-hosted Publr usually has no copies: your
changes go to the site itself.

Only when your person asks, a project is brought down to this computer: `publr clone
<address>` makes a folder you work in as any local site, and `publr push` sends it up as a
branch for your person to review and merge. A folder with `.publr/clone.json` is such a
copy: it never writes to the live site, and an agent opened in it works on the project
itself.

The person chooses what you may do: read only; read and write (on copies, where there are
any); write on production, where your changes wait as drafts; and publish. Never ask them
for a password or a token, and never paste a token anywhere: the link is the only way in.
Removing is safe: what you delete (a record, a content type, a plugin, a file, a user) goes
to the trash whole, and the person can restore it (`trash list`, `trash restore`). Only
what is final waits for them: purging a record or a term, or removing something from the
trash, is not run but put on their removal list (`ListedForRemoval`); they remove it
themselves. Without publish, a write that would publish is refused with `DraftsOnly`: save
drafts and tell them what waits to be published.

With no files of your own to edit, the project's apps are reached through operations:
`apps files`, `apps read`, `apps write --path <app>/<path> --content <text>`, `apps
remove`, each live as soon as it is written (`apps load` answers why they do not load when
they do not). A file that is not text (an icon, an image) goes with `apps write --encoding
base64 --content <base64>`. A plugin is built on a computer: with its source in this
folder, `publr plugin build --name <name>` builds it here against the site's release and
sends the module. A site builds nothing itself.

Where the `publr` command may not write in your home folder (a sandbox), point its cache at
the project: `PUBLR_CACHE_DIR=$PWD/.publr/cache`.

## Where to read more

- `publr skill`: the short version of how to decide where each need goes, and when Publr
  itself may change (only as a generic pull request).
- `publr --help`, and `--help` on any namespace or command.
- The SDK's source, as this release builds plugins against it: `publr plugin sdk --out
  <folder>` writes it. Start at `publr.zig` and `publr/`.
