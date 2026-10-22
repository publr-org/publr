# Plugin API reference

Every option a plugin registers, the shape it takes, and where it runs.
[Plugins](plugins.md) explains why each exists and how they fit together; this page is the
list. A plugin imports one module, `publr`, and registers once, last in its `main.zig`:

```zig
//! Short notes, kept by editors.
//!
//! Add one with `notes add`; every note is a private record.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "notes",
    .version = "0.1.0",
};

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Notes},
    .operations = &.{Add},
});
```

**Runs** says where an option works: **both** (compiled in and installed), or
**built-in** (compiled in only; an installed build leaves it out, `publr plugin build`
names it, and a call to a left-out operation answers `Unavailable`).

Everything is checked when the plugin compiles. An option `define` does not have, a
missing doc comment, or a misshapen part is a compile error naming the plugin and the
part. Publr never looks inside a file for a name: every part is written out where it is
used (`.records = &.{Notes}`).

## Words

A plugin's words are its doc comments, read from the source by `publr plugin build` and
Publr's `zig build`:

| Where | Gives |
|---|---|
| `//!` at the top of `main.zig` | the first line: the plugin's description; the rest: its settings page text and its namespace's details |
| `///` above an operation, or its file's `//!` | the description (first line), the details, `Fails:`, `Example:` |
| `///` on every field of an operation's `In` and `Out` | each field's help |
| `///` on a record's struct | the type's name (first line) and description |
| `///` on every field of a record | the field's label (first line) and help |
| `///` on a value of a status enum | the status's label |
| `///` on a field of the `.secrets` struct | what the secret is and where to find it |
| `Why:` in a field's `///` | the reason a plugin check does not apply |

A missing one fails the build and says where it goes.

## Options at a glance

| Option | Shape | Runs |
|---|---|---|
| `records` | `&.{ ... }` of `publr.record.define` | both |
| `operations` | `&.{ ... }` of `publr.operation.define` | both |
| `hooks` | `&.{ ... }` of `publr.before`, `publr.after`, `publr.on` and `publr.modify` | both |
| `events` | `&.{ ... }` of `publr.event.define` | both |
| `jobs` | `&.{ ... }` of `publr.job.define` | both |
| `permissions` | `&.{ .{ .key, flags, .reason } }` | both (checked at compile time, enforced installed) |
| `secrets` | a struct of `publr.Secret` fields | both |
| `limits` | `publr.plugin.Limits` | installed |
| `depends_on`, `compatible_with` | `&.{ "newsletter@^1.2" }` | both |
| `remotes` | `&.{ ... }` of `publr.remote.operation`, `.record`, `.event` | both |
| `field_kinds` | `&.{ ... }` of `publr.field.kind` | built-in |
| `register_fields` | `&.{ .{ .fields, .location } }` | both |
| `roles` | `&.{ ... }` of `publr.plugin.Role` | both |
| `pages`, `panels`, `menu`, `icons` | see [Admin entries](#admin-entries) | both |
| `translations` | `&.{ .{ .locale, .label, .po } }` | both |
| `middleware`, `row_actions`, `routes`, `settings_pages`, `settings_tabs`, `app_picker_segment`, `sign_in_at`, `State`, `before_command`, `serving`, `operator_commands`, `bootstrap`, `schema_sql`, `migrations`, `sign_in_provider`, `policies`, `filters`, `delivery_gates`, `variants`, `agents_tab`, `admin_brand`, `work_start`, `hosted` | see [Built-in only](#built-in-only) | built-in |

Any other option is a build error.

Decided but not built: `define` refuses these and names the gate that brings them:
`register_taxonomies`, `register_columns`, `register_components`, `register_providers`, `register_location_rules`, `taxonomies`, `webhooks`. Jobs for
installed plugins, `.due` and `transition_at`, outside calls from queued work, email, outside search engines and field editors
in the plugin frame come with later gates too.

## Manifest

```zig
const manifest: publr.Manifest = .{
    // [a-z_], at most 32 characters; not a core namespace, not `app`.
    .name = "notes",
    // 1 to 32 characters; raise it to ship a new version.
    .version = "0.1.0",
};
```

The description is the first line of `main.zig`'s `//!`, 1 to 200 characters. The plugin's
namespace (`publr notes --help`) is made from the same words.

## Operations

```zig
pub const AddIn = struct {
    /// The note, 1 to 280 characters
    note: []const u8,
};

pub const AddOut = struct {
    /// The new note's id
    id: []const u8,
};

/// Keeps a note.
///
/// Editors may call it.
///
/// Fails:
/// - Full (409): the plugin keeps at most 1,000 notes
///
/// Example:
///   in: { "note": "hello" }
///   out: { "id": "3f9c1e0a5b7d2c4e6f8a9b0c" }
pub const Add = publr.operation.define(AddIn, AddOut, .{
    .name = "add",
    .kind = .write,
    .authorize = publr.authorize.user_has_role(&.{"editor"}),
    .validate = check_add,
    .run = add,
});

fn check_add(in: AddIn, problems: *publr.Problems(AddIn)) void {
    if (in.note.len == 0 or in.note.len > 280) {
        problems.add(.note, "A note is 1 to 280 characters");
    }
}

fn add(ctx: *publr.Ctx, in: AddIn) publr.Error!AddOut {
    return .{ .id = try Notes.create(ctx, .{ .note = in.note }) };
}
```

| Option | Type | Meaning |
|---|---|---|
| `.name` | `[]const u8` | the verb, `[a-z_]`, at most 48; the operation is `<plugin>.<verb>`; required |
| `.kind` | `.read` or `.write` | a write runs in a transaction; required |
| `.run` | `fn (*publr.Ctx, In) publr.Error!Out` | the work; required |
| `.authorize` | a ready answer, or `fn (*publr.Ctx, In) bool` | who may call; left out: administrators and roles granted it, or anyone with `.untrusted_callers`. A site overrides it with `operation authorize` (beside a function of the code's own, only narrowing) |
| `.untrusted_callers` | `bool` | anyone may call it without credentials |
| `.public_api` | `bool` | listed in the published API reference; changes nothing about who may call |
| `.validate` | `fn (In, *publr.Problems(In)) void` | every problem at once; refused before `run`: `422 { "error": "Invalid", "problems": [ { "field", "message" } ] }` |
| `.destructive` | `bool` | a write that erases for good; devices may not call it |
| `.limit` | `.{ .per_minute = n }` | calls a minute per untrusted caller (a site's pages, or anyone without credentials; per visitor, else address), on top of the general 600; over it: `429` with `Retry-After`. A site overrides it with `operation limit` |
| `.secret` | `&.{.password}` | input fields masked wherever the call's input is shown; a name that is no field fails the build |
| `.deprecated` | `publr.Deprecated` | `.{ .since = "0.4.0", .instead = "notes.save", .why = "" }`: every caller is told (the `Deprecation` header, `--help`) |

Ready answers, checked by the host before anything runs: `publr.authorize.user_is_signed_in`
(needs `.untrusted_callers`), `user_has_role(&.{"editor"})`, `plugin_calls`. Anyone is no
answer to write: it is what `.untrusted_callers = true` means when `.authorize` is left out. Administrators pass every ready answer, except through an app's address. A
function of the plugin's own runs first in the call, reading `ctx.caller()`.

`In` and `Out` are named structs of text (`[]const u8`), integers, floats, `bool`, enums,
optionals, slices and nested structs, at most 64 fields and 8 levels deep. No pointers
other than slices, no functions. Defaults make a field optional for the caller.

The words above the operation: the first line is its description, then its details, then
`Fails:` (each `- Name (status): what it means`; 409 when the status is left out; any 4xx
but 401 and 429), then `Example:` with an `in:` and an `out:` line of JSON, read into `In`
and `Out` when it compiles. `--help` shows all of it.

A site's pages call an operation at `<mount>/_actions/app.<plugin>.<verb>`: forms, islands
(JSON with `Publr-Request: 1`), and `Publr.request.call('app.<plugin>.<verb>')` in a
page's frontmatter, which reaches any of its reads. Through that address an administrator
is a signed-in person like any other, and an operation without `.authorize` is never
reached. Another site's page may call an `.untrusted_callers` operation too, without
cookies.

### Taking a record by reference

The caller sends an id; core reads the stored record with the caller's access before
`run`. Unknown, another type's, or not readable answers `NotFound`.

```zig
pub const ReserveIn = struct {
    /// The variant to hold
    variant: Variants.Ref,
    /// How many
    quantity: i64,
};
// in run: in.variant.id, in.variant.value.?  (the stored document)
```

### Errors

`publr.Error` is `Denied`, `Invalid`, `NotFound`, `Conflict`, `Vetoed`, `Throttled`,
`Failed`, `Unavailable`, `BadCredentials`, `InvalidationFailed`, `OutOfMemory` and the
database's errors. A failure of the plugin's own is `ctx.fail` (below). Any error from a
write rolls back the write, its hooks and every call it made.

## The context: `*publr.Ctx`

The same calls compiled in (direct) and installed (each call a message to the host).

| Call | Answers |
|---|---|
| `ctx.call(Operation, in)` | `publr.Error!Operation.Out`: runs any operation through the full pipeline, as the plugin, narrowed to the person it acts for; its own operations too (`ctx.call(Add, .{ .note = "hi" })`) |
| `ctx.fail(.Name, "Only {left} left", .{ .left = left })` | `error.Failed`: refuses in the plugin's words, translated, with the status its `Fails:` line gives (409 when none) |
| `ctx.t(text, values)`, `ctx.tn(one, many, count, values)` | text for people in the caller's language, each `{name}` filled; installed plugins get the source text until their catalogues ship |
| `ctx.log(.info, "Charged {s}", .{amount})` | a log line with a level, `.info`, `.warn` or `.err`, kept with the call: under its entry in the Activity log (a write) or Error log (a refusal or failure, rolled back or not), and on the plugin's Log tab (`plugin log`). A queued job's run keeps its own (`job:<plugin>.<name>`), an event's `on` hooks theirs (`event:<name>`). An `.err` line in a call that answered adds an Error log entry, error `Logged`. At most 100 lines a call, 1 KiB each |
| `ctx.now()` | `publr.Time`, the call's time: `.ms`, `before`, `after`, `add_minutes`, `add_days` |
| `ctx.caller()` | who calls: `.from` (`admin`, `command_line`, `api`, `app`, or `.{ .plugin = name }`: a plugin, its queued work too, Publr's own work `publr`), `.visitor` (the app visitor's stable id), `.referer` (the other site whose page sent the request, empty for the site's own; it tells, never grants), `signed_in()`, `has_role(name)`, `granted()`, `is(id)` |
| `ctx.grant(key)` | `.{ .on, .publish, .drafts, .domains }`: what the plugin was given for a request |
| `ctx.emit(Event, payload)` | emits an event declared with `publr.event.define`: its `after` hooks run now, inside the write (a refusal rolls it back); its `on` hooks hear it from the queue once the write commits |
| `ctx.enqueue(Job, in)`, `ctx.enqueue_at(Job, in, at)` | queues a job declared with `publr.job.define` |
| `ctx.arena()` | `std.mem.Allocator`, freed when the call ends |
| `ctx.alloc(T, n)`, `ctx.print(fmt, args)` | memory and formatted text freed when the call ends |

Core's operations are under `publr.operations.<namespace>` (`record`, `user`, `media`,
`http`, `internal`, `taxonomy`, `term`, `snapshot`, ...). Calling one that none of the
plugin's permissions opens fails the build, naming the key to add.

## Records

```zig
/// Note
///
/// A short note an editor keeps.
pub const Note = struct {
    /// Note
    note: []const u8,
    /// Slug
    slug: ?[]const u8 = null,
};

/// A note says more than its slug.
fn says_more(note: Note, problems: *publr.Problems(Note)) void {
    if (note.slug) |slug| {
        if (publr.text.equals(note.note, slug)) {
            problems.add(.note, "Write a note, not the slug again.");
        }
    }
}

pub const Notes = publr.record.define(Note, .{
    .name = "notes.note",
    .validate = says_more,
    .fields = .{
        .note = .{ .validation = .{ .min_len = 1, .max_len = 280 } },
        .slug = .{ .kind = "slug", .options = .{ .source = "note" } },
    },
});
```

Fields come from the struct. Kinds follow the Zig types: `[]const u8` text, an integer
`integer`, a float `number`, `bool` `boolean`, `publr.Time` `datetime`, an enum `select`,
a handle's `Ref` or `publr.record.AnyRef` `reference`, a slice of them many. A field with
no default is required. `.fields.<name>` overrides `kind`, `searchable`, `filterable`
(lists offer it in Filter; on by default), `sortable` (lists order by it; by default
numbers, money, dates and times do), `help`, `validation` and `options`; with a `kind`
given, the Zig type may be any plain value (`std.json.Value` for `money`).

`validation` holds the field's rules and nothing else: `required` (set from the struct,
changed here), `unique`, `min`/`max`, `min_len`/`max_len`, `items_min`/`items_max`,
`words_min`/`words_max`, `preset`, `pattern`, the per-rule `messages`, the kind's own
rules (`media` sizes and types, `email.domains`, `url.schemes`, ...) and `hint`. Every
write of the record checks them, whoever writes: the admin, REST, the CLI, your own
operations; a refusal names each field (`problems`). The admin writes the rules out beside
the field's help (`1 to 280 characters`), so help never repeats them; `hint` replaces that
line and may name a bound: `.hint = "Up to {max_len} characters, emoji count as two"`.
`options` is how the field is shown and edited (`source`, `choices`, `rows`,
`placeholder`, the kind's controls). Checking stored data in an operation instead is a
mistake: the admin's editor never runs it.

| Option | Meaning |
|---|---|
| `.name` | the type's name, under the plugin's: `notes.note` (`<plugin>.<type>`, each `[a-z][a-z0-9_]*`); required. Apps, GROQ (`_type == "notes.note"`), `--type` and other plugins use it whole |
| `.validate` | `fn (T, *publr.Problems(T)) void`: rules across fields, run on every create and save of the type, whoever writes; a problem refuses the write like a field's rule |
| `.internal` | the plugin's bookkeeping: internal records, never in the admin's content list |
| `.indexed` | an internal record's fields it is found by, named: `&.{.page}` |
| `.scope` | `.project` (default) or `.app`, for an internal record kept per app |
| `.public` | apps' built pages may read its live records |
| `.url` | records get pages at `/<url>/<slug>` |
| `.title_field` | the field a record is listed by, named: `.title`; the first text field when left out, none for `.settings` or `.none` |
| `.editor`, `.plural_name`, `.app` | as on any content type |
| `.kind` | `.record` (default), `.settings` (one record; the admin draws its page), `.component` |
| `.status` | its statuses and transitions (below) |
| `.append_only` | an internal record written once, never changed or deleted: a ledger |
| `.menu` | `.{ .parent = &.{ "checkout.orders", ... }, .icon }`: where its list sits in the admin's menu ([Menu items](#menu-items)); `.none`: no entry, its pages still open at their addresses |
| `.data_view` | its list's default view: `.columns`, `.filters`, `.order` ([Default view](#default-view)) |

A list of structs is a repeater: its rows' fields come from the row struct the same way,
each with its `///`, overridden through `.fields.<list>.fields.<field>`. A text field's
default (`= "Placed"`) is the field's default in the form.

The handle reads and writes typed values: `Notes.get(ctx, id, .{})` (a record in the trash is
not found; `Notes.get(ctx, id, .{ .trashed = true })` reads it),
`Notes.find_one(ctx, .slug, value)`, `Notes.create(ctx, value)` (the new id, in the flow's
start), `Notes.save(ctx, held, .{ .note = "..." })` (writes only the fields named onto the
record read; a conflict only when one of them changed since `held` was read; never the
status), `Notes.transition(ctx, held, .publish)`. `Notes.Held` is `{ id, version, status,
changed, value }`, its `status` the record's enum; `Notes.Ref` takes one by id. Its own
types need no permission.

### Statuses

```zig
pub const GreetingStatus = enum {
    /// Draft
    draft,
    /// Waiting for review
    in_review,
    /// Shown
    published,
};

const flow = [_]publr.record.Transition(GreetingStatus){
    .{ .name = .submit, .from = &.{.draft}, .to = .in_review, .label = "Submit for review" },
    .{
        .name = .publish,
        .from = &.{ .draft, .in_review },
        .to = .published,
        .label = "Show",
        .authorize = publr.authorize.user_has_role(&.{"editor"}),
    },
    .{ .name = .withdraw, .from = publr.record.any, .to = .draft, .label = "Withdraw" },
};

.status = .{
    .list = GreetingStatus,
    .start = .draft,
    .flow = &flow,
    .published = &.{.published},
},
```

`.start` is required. `.from` is a list of the record's statuses, or `publr.record.any`
(every status but the target and the trash). `.authorize` takes the answers operations
take; the transition is refused to anyone it does not let in, on every path that moves a
record (a named transition, `record publish`, a save into a status, bulk changes), and
administrators always pass. Core's `draft`, `published`, `archived` keep their meaning; a
record's own statuses are stored under its plugin's name (`hello.in_review`), at most 32
characters. A record changes status only by a named transition:
`Greetings.transition(ctx, held, .publish)` (a name not in the flow fails the build), which
answers `.done`, or `.pending` when the caller may only draft: a transition into or out of
a live status by code whose `records.write` lacks `.publish` (on another plugin's types; its
own it always may), or for a person who may not publish. It is kept on the record until
someone who may runs it or declines it. `held.status` is the
record's enum, `.other` for a status an administrator added. A type with a flow allows only
the transitions it lists, plus core's three, names no flow may use: `trash` (from anywhere
to `trashed`), `restore` (back to the status it had; a published one comes back where
records start) and `destroy` (from the trash, gone for good: made when an administrator
asks, `.pending` for anyone else, plugin code included, and the record stays in the trash).
One without a flow has core's: `publish`, `unpublish`, `archive`, `unarchive`. The flow is
kept with the type's definition, so an installed plugin's types carry it as a compiled-in
plugin's do, and the editor offers each transition as a button. Reads leave the trash out:
`get`, `find_one`, GROQ (`publr.query.prepare(text, .{ .trashed = true })` reads it too).

`Notes.transitions.<name>` is one transition's hook point (`Notes.transitions.publish`,
`Notes.transitions.trash`; a name not in the flow fails the build), and
`Notes.any_transition` is one hook point for every transition on the type, trash and restore
included: `publr.before(Notes.any_transition, check)`, each run given
`publr.record.Transitioned`, `.{ .record, .transition, .from, .to }`. A `before` or
`after` hook refuses the transition by failing; `on` hears it from the queue once it is
kept. A move over many (`record transition_many`) raises it for `on` hooks once per record;
its `before` and `after` hooks run on `record.transition` instead.

`.status.alias = .{ .paid = "orders.paid" }` makes one of the record's statuses stand in for
another plugin's: with that plugin present, the status takes its label, colour and
visibility, and a filter asking for `orders.paid` finds it; without, it keeps its own. It is
stored under its own name, so nothing moves either way.

A plugin adds statuses and transitions to another plugin's flow with `.register_statuses`
in `define`:

```zig
.register_statuses = &.{.{
    .to = "orders.order",
    .status = "awaiting_stock",
    .label = "Awaiting stock",
    .transitions = &.{
        .{ .name = "await_stock", .from = &.{"paid"}, .to = "awaiting_stock", .label = "Wait for stock" },
        .{ .name = "stock_arrived", .from = &.{"awaiting_stock"}, .to = "paid", .label = "Stock arrived" },
    },
}},

_ = try Orders.transition(ctx, order, .await_stock); // a remote record, by name
```

The status is stored under the adding plugin's name (`inventory.awaiting_stock`); a
transition's statuses are the added one, core's, or the owner's own. Nothing of the owner's
flow changes: its transitions reach the added status only when written `from = any`, and its
code reads the record's status as `.other`.

Each added status needs a transition of the plugin's out of it into a status the plugin does
not add (`stock_arrived` above), or the build fails: when the status goes, its records leave
by it first. An installed plugin asks for each status at install (`status:inventory.awaiting_stock`,
granted at once); while granted it is in the owner's flow. Revoked, denied, the plugin
disabled or removed, or an update without it: its records leave first, in the same write,
and the change is refused when one may not.

### Queries

```zig
const recent = publr.query.prepare(
    \\*[_type == "notes.note" && _updatedAt > $since]{ "id": _id, note }
, .{});

const found = try recent.execute(ctx, []const Found, .{ .since = since });
```

GROQ, run as the caller with their access applied, trashed records left out. `$names` are
bound from the struct `execute` is given; a `$name` it lacks, or a field the query never
names, fails the build. `.{ .trashed = true }` includes records in the trash.

## Hooks and events

Publr is event-driven. Every operation emits an event under its own name when it succeeds,
carrying its answer; a plugin declares its own event for something that happens that is not
a call. Hooks sit on the main instance, each a target and a named function:

```zig
// in define:
.hooks = &.{
    publr.before(Add, shout),
    publr.after(publr.operations.record.Create, count),
    publr.on(Add, send_confirmation),
    publr.on(Recorded, thank),
},
```

| Hook | `run` | Runs |
|---|---|---|
| `before(Operation)` | `fn (*publr.Ctx, *Operation.In) publr.Error!void`: may change the input or refuse, inside the write | both |
| `after(Operation)` | `fn (*publr.Ctx, *Operation.In, *const Operation.Out) publr.Error!void`: inside the write; its error refuses, rolling it back | both |
| `after(Event)` | `fn (*publr.Ctx, Event.Payload) publr.Error!void`: inside the write that emitted it; its error refuses, rolling it back | both |
| `on(Operation)` | `fn (*publr.QueueCtx, Operation.Out) publr.Error!void`: the operation's answer as it was, from the queue once the write committed | both |
| `on(Event)` | `fn (*publr.QueueCtx, Event.Payload) publr.Error!void`: the payload, from the queue once the write committed | both |

`Operation` is an operation by type: the plugin's own, one of `publr.operations`, or a
remote; `Event` one declared with `publr.event.define`, core's (`publr.auth.SignedIn`,
a record type's transitions), or another plugin's (`publr.remote.event`). `before` takes
operations only: an event already happened, and `before` on one fails the build (the
sign-in events and transitions, which core lets refuse, are the exceptions). Hooks take no
options.

Some of core's events are kept outside the write that raised them and heard with `on`
only (`before` or `after` on one fails the build, and an installed plugin asking for it is
refused at install): the sign-ins refused (`publr.auth.SignInThrottled`, `SignInFailed`,
`SignInLocked` with `.email`; `SignOnReplayed` with `.email`; `SignOnFailed` with `.email`
and `.why`; `IdentityRefused` with `.provider` and `.why`) and `publr.errors.Failed`, raised
for everything that lands in the Error log as an error: a failed or crashed call, an `.err`
log line, a failed job or `on` run. Its payload: `.what` (the operation, `job:<plugin>.
<name>` or `event:<name>`), `.plugin`, `.error_name` (`Logged` for a line), `.message`,
`.caller` (`user`, `job`, `system` …), `.at` and `.entry`, the Error log entry's id; never
input values or secrets. A refusal the caller is told about (`Invalid`, `Denied`,
`NotFound`, `Conflict`, `Throttled`, a `ctx.fail` name) raises nothing. For an error
tracker: `publr.on(publr.errors.Failed, send)`.

`on` never runs in the caller's request: the event is queued inside the write's
transaction (a nested call's in its parent's), handed to the hook once the write
committed, and dropped when it rolls back. A failed call emits nothing. `on` is the only
hook that may call out (`ctx.fetch`); it gets the answer as it was, so read the record for
its state now. Each `on` hook runs on its own: one that fails runs again later, with the
jobs' waits and limit (a minute, doubling up to a day, eight runs in all), and never runs
the others on the event again. Its run is kept as a job named `on:<event>` (`on:<event>#2`
for the plugin's second hook on it) with the payload as its input, and is the author of
what it changes (`job:<plugin>.on:<event>`). Each failed try is a line on the plugin's Log
under `event:<name>`, beside what the hook logged; after the last, "failed for good", and
`publr job list` shows it `failed` with why. A `Conflict` is not run again. The record and
the person's values stay; a hook that needs its own handling enqueues a job, which has
`.on_failure` and `.on_conflict`.

The `///` on the `run` function is the hook's reason: the administrator reads it when an
installed plugin asks to hook in. The function may sit in the file listing the hook or in one
it imports (`publr.before(Note.operation, Shout.run)` with `const Shout =
@import("hooks/shout.zig")`). An installed plugin's hook without one is left out of its build,
and the build says so.

**Signing in, up and out.** `publr.auth.SignedIn`, `SignedUp` (someone creating their own
account, before their first `SignedIn`) and `SignedOut` are core's events, hooked by type.
Their payload is `.user`, `.visitor` (the id the person had before signing in) and `.method`
(`password`, `link`, or the provider's name); no payload carries a password, code, token or
session, and the build refuses one that would. `before` runs after the credentials are
checked and before the session exists: it gets the payload by value, may read but not
write, and can only refuse (`return error.Denied`, or `ctx.fail(.AccountSuspended, …)` with
the name in its `Fails:`, which the sign-in page shows). A hook that errors, crashes or runs
out of time refuses too. `after` runs inside the sign-in's write, so its error fails the
sign-in; `on` runs from the queue. No hook picks who signs in, their roles or the session.
An administrator is never refused: the refusal is logged and the sign-in goes on.
`SignedOut` takes `after` and `on` only (`before` stops the build, and an installed plugin
asking for it is refused at install), and signing out always goes through.

```zig
.hooks = &.{
    publr.after(publr.auth.SignedIn, merge_bag),
    publr.on(publr.auth.SignedUp, welcome),
},
```

**Mods** let plugins change a value wherever its owner makes it. The owner applies it under a
name; any plugin modifies that name:

```zig
// checkout: the methods on offer, for others to change
const offered = try ctx.mod("checkout.methods", methods);

// products: how a variant is named, wherever core shows a title
/// Shows each variant with its product's name, as Earl Grey, 50 g
fn title(ctx: *publr.Ctx, item: *publr.Title(Variant)) publr.Error!void {
    const product = try Products.get(ctx, item.record.product.?.id, .{});

    item.title = try ctx.print("{s}, {s}", .{ product.value.title, item.title });
}

.hooks = &.{ publr.modify("variant.title", title) },
```

A name is dotted parts of `a-z`, `0-9` and `_`; a modifier's may hold `*` for one whole part
(`*.title`, `checkout.*`). Nothing is declared ahead: a name nobody modifies comes back as it
went. Modifiers run in order: compiled-in plugins first, then installed ones as they were
loaded. A modifier's function takes the value by pointer, typed by its parameter; a value
that does not read as that type is left as it was. What the owner does with the answer is
its own: shown, or saved. Core applies every record's title as `<type>.title`
(`publr.Title(Doc)`: `.id`, `.record` typed, `.title` to change). `ctx.mod_all` applies a
list of values at once; a modifier is still written for one, and Publr runs it over them in
passes: the first only notes what each reads, then every noted `get` is read in one list and
anything else once per distinct input, and the next pass answers from them, at most 4
rounds. A modifier is pure: no writes, no outside calls; one that fails leaves the value as
it was. `publr mod list` shows every modifier, whose it is and why. A `pre` hook (built-in) is a `.middleware` struct.

```zig
/// A greeting was recorded.
pub const Recorded = publr.event.define(.{
    .name = "recorded",
    .payload = struct {
        /// The greeting text
        note: []const u8,
    },
});

// ctx.emit(Recorded, .{ .note = in.note });   emitted as `hello.recorded`
// a hook takes it as `Recorded.Payload`
```

Every event, a plugin's or core's, has this one shape: `.name` without the plugin's prefix
(a dot in it fails the build), `.payload` a struct with `///` on each field.

An event is its own file's declaration, words from `///`, a struct payload with `///` on
each field, listed in `.events`. Declare one for a condition reached mid-operation (stock
running out), one fact per record in a call over many, or something nobody called (a
session expiring); "X was done" is the operation's own event. `before` and `after` are part
of the write, in its transaction; `on` hooks, compiled in or installed, hear operations and
events alike from the queue the server's worker process works through, beside the server.

## Jobs

Work that runs later, as the plugin, in the server's worker process: never in the caller's
request, never delaying another.

```zig
pub const ShowIn = struct {
    /// The greeting to show
    greeting: Greetings.Ref,
};

/// Shows a greeting on the site, a minute after it was recorded.
pub const Show = publr.job.define(ShowIn, .{
    .name = "show",
    .run = show,
});

fn show(ctx: *publr.QueueCtx, in: ShowIn) publr.Error!void {
    const held = try Greetings.get(ctx, in.greeting.id, .{});

    _ = try Greetings.transition(ctx, held, .publish);
}

// in an operation:
try ctx.enqueue_at(Show, .{ .greeting = .{ .id = id } }, ctx.now().add_minutes(1));

// in define:
.jobs = &.{Show},
```

- `ctx.enqueue(Job, in)` queues it to run as soon as the server gets to it;
  `ctx.enqueue_at(Job, in, at)` never before `at`, within about a second after it. Inside a
  write, the job is queued in its transaction: a write rolled back queues nothing.
- The input is kept as JSON, up to 64 KiB: send references, and read the record when the job
  runs, as it is then.
- A run that fails runs again: a minute later, then two, four, up to a day, eight runs in
  all. After the last, `.on_failure` (`fn (*publr.QueueCtx, In, problem: []const u8) void`)
  hears why, and the job is kept as failed. Each failed try is a line on the plugin's Log
  ("The job <name> failed (try 1 of 8): …"), the last "… failed for good after 8 tries: …". A run lost to a crash runs again five minutes
  later, so a job is safe to run twice.
- A run that ends in `Conflict` (what it changes was changed meanwhile) is not run again:
  `.on_conflict` (`fn (*publr.QueueCtx, In) void`) hears it, the record and the person's
  values stay, and the job is kept as failed, "Conflicted".
- A job runs as its plugin, with the plugin's access, and is the author of what it changes:
  the activity log names it `job:<plugin>.<name>`.
- A repeating job takes no input and runs on its own:

  ```zig
  /// Clears out the day's expired holds.
  pub const Tidy = publr.job.define_recurring(.{
      .name = "tidy",
      .run = tidy, // fn (ctx: *publr.QueueCtx) publr.Error!void
      .every = .day, // or .hour, or .{ .minutes = 15 }
      .at = .{ .hour = 3 }, // UTC, for now: Publr has no site time zone yet
  });
  ```

  Runs missed while the server was down run once, then it keeps its rhythm. List it in
  `.jobs` like any other.
- `publr.QueueCtx` has every call `publr.Ctx` has, and `ctx.fetch`: queued work alone calls
  other servers. Record handles and queries take either. An `on` hook whose `run` takes
  `*publr.QueueCtx` gets one too.
- Installed plugins queue and run jobs as compiled-in ones do; their manifest lists them.
  `publr job list` shows what waits and what failed for good, `on` hooks' runs among them.

## Permissions, secrets, limits

```zig
.permissions = &.{
    .{ .key = "records.read", .drafts = true, .reason = "Shows drafts in the preview" },
    .{
        .key = "records.write",
        .records = &.{"products.variant"},
        .publish = true,
        .reason = "Puts new prices live",
    },
    .{ .key = "http.fetch", .domains = &.{"api.supplier.com"}, .reason = "Fetches prices" },
},
.secrets = Secrets,
.limits = .{ .memory_mib = 64, .reason = "Holds images" },
```

| Key | Narrowed by | Flags | Tier |
|---|---|---|---|
| `records.read` | `.records` | `.drafts`, `.private`, `.internal` | low; medium with drafts, high with private or internal |
| `records.write` | `.records` | `.publish` | medium; high naming no type |
| `records.destroy` | `.records` | | high |
| `terms.read` | `.taxonomies` | `.drafts`, `.private`, `.internal` | low, rising as `records.read` |
| `terms.write` | `.taxonomies` | `.publish` | medium |
| `schema.read`, `schema.write` | | | low, high |
| `users.names`, `users.read`, `users.write` | | | low, high, high |
| `site.read` | | | low |
| `settings.write` | | | high |
| `http.fetch` | `.domains` | | high |
| `media.read` | | `.private` | low; high with private files |
| `media.write` | | | medium |
| `email.send` | | | medium |

What each opens:

- `records.read` starts at what an anonymous visitor sees: published records of public
  types. `.drafts` opens drafts, pending changes and version history; `.private` content
  types marked Private; `.internal` other plugins' internal records. Naming types in
  `.records` covers those types whatever their kind; `.drafts` applies either way. A list
  or a query spanning several types answers each by its own grant: drafts of the types the
  plugin reads drafts of (or writes), live records only of the rest.
- `terms.read` does the same for terms: live terms of public taxonomies; `.drafts` draft
  terms, `.private` taxonomies not marked Public; naming them in `.taxonomies` covers
  them whatever their kind. `.internal` is for internal taxonomies, which core does not
  have yet. `terms.write` reads the taxonomies it writes, draft terms included.
- `records.write` reads the types it writes, drafts included. Without `.publish`, creating
  starts a record in its first status, changes to a published record wait as pending
  changes, and a transition into or out of a published status answers `.pending` for
  someone who may publish to approve; with it, they go live. Private and internal types
  only when named. `records.destroy` alone removes a record for good.
- Queued work (jobs, `on` hooks) runs with the plugin's own grant, `.publish` included.

A `call:<plugin>.<verb>` key, for another plugin's operation, and `ai.progress` pass as
they are. Any other key, or an option its key does not take (`.domains` on
`records.read`), fails the build. They are requests: the administrator sees each with its
flags as switches, may switch a flag or the key off before enabling and at any time after,
and `ctx.grant(key)` says whether the key is on and with which flags. A switched-off flag
shows in answers (`.pending`, `Denied`, a query finding nothing), never as a crash.
At most 64 permissions and 32 domains; a reason is at most 200 characters.

```zig
/// Secrets this plugin uses; an administrator fills them in.
const Secrets = struct {
    /// Chat token
    ///
    /// In the chat's settings under Integrations.
    CHAT_TOKEN: publr.Secret,
};
```

A secret is not a permission: declaring it is the request. Each field is one secret, its
name the secret's (capitals, digits, underscores), its `///` the label people see, then
where to find it; at most 32. A plugin with secrets asks for `http.fetch`. It uses exactly
what it declares: a `{secret:NAME}` its code writes without declaring it fails the build
(`plugin build` and compiled in alike), and one made at run time is refused. At install
each secret's field sits under the `http.fetch` request: optional, fillable later on the
plugin's page, write-only ("Set", or "Set, shared with" the other plugins naming it, and
Replace). Names are site-wide: plugins naming the same one share its value. With no value
a request naming it is refused: "Chat token isn't set". Default limits per call: 100 ms CPU
(`cpu_ms`), 16 MiB memory (`memory_mib`), 1,000 calls (`calls`), 1 MiB output
(`output_kib`).

### Calling out

From queued work, a job or an `on` hook taking `*publr.QueueCtx`:

```zig
const answer = try ctx.fetch(.{
    .method = "POST",
    .url = "https://chat.example.com/send?token={secret:CHAT_TOKEN}",
    .headers = &.{},
    .body = body,
});
// answer.status, answer.body
```

Only to the domains on the `http.fetch` grant: `api.example.com` exactly (no subdomains
implied), `*.example.com` for any name under it, or `"*"` for any public address (it always
waits for a person, who is warned it can send data anywhere). Administrators add and remove
domains on the grant; `ctx.grant("http.fetch").domains` reads the list as granted now. An
update's new domains join the administrator's list once they allow the update (its review
shows them); the ones they removed stay out, the ones the new version no longer asks for
leave. https only; in development (a site served over plain http) also
plain http to this machine, when listed. In production every local or private address
(loopback, private ranges, link-local and the cloud metadata address, shared, unique-local)
and the server itself (its host names, the addresses they resolve to, the public addresses
on its network interfaces) are refused whatever is listed, checked on the address the name
resolves to and connected to that address, IPv4 or IPv6. Redirects are followed, at most 3, only within the domains; headers stay
behind when the host changes. Every request is a line in the run's log (method, host,
path, status, time), never the query, headers or bodies. Compiled-in plugins follow the
same rules; only core's own downloads are not under a grant. A secret is written as
`{secret:NAME}` and filled in as the request leaves; the plugin never holds the value. Do
not call out from a write: nothing undoes it on rollback.

A request's `publr.Ctx` still reaches `publr.operations.http.Fetch` through `ctx.call`, for
the model providers and the plugins that call out from their operations today; it goes once
they run as queued work. Hooks never call out (`before`, `after`, `.authorize`, validation,
modifiers): queue a job from the hook instead. The one place a request waits on another
server is a sign-in provider's `exchange` (`publr.ExchangeCtx`: `fetch` to the plugin's own
domains, 10 seconds in all), a step of the provider, not a hook
([Plugins](plugins.md#writing-a-built-in-plugin)).

## Building on other plugins

```zig
pub const Subscribe = publr.remote.operation(
    "newsletter.subscribe",
    // What this plugin sends.
    struct { email: []const u8 },
    // The part of the answer it reads.
    struct { subscribed: bool },
);

pub const Variants = publr.remote.record("products.variant", struct {
    title: []const u8,
    sku: ?[]const u8 = null,
});

pub const OutOfStock = publr.remote.event("inventory.out_of_stock", StockPayload);

// in define:
.depends_on = &.{"newsletter@^1.2"},     // exact `1.2.3` or caret `^0.2`
.compatible_with = &.{"inventory@^0.3"}, // used only when present
.remotes = &.{ Subscribe, Variants, OutOfStock },
```

A plugin never imports another. Every remote is listed in `.remotes` and checked against
the real thing: when both are compiled in, when the plugin is enabled, and whenever the
other plugin is installed, enabled, updated, disabled or removed. Every listed field must
be there with a fitting kind: an operation's and an event's by their JSON shape, a
record's by field kind (text reads any text kind and a reference's id, a number a number
field, a `publr.records.Ref` a reference, money's JSON map money). An internal record's
fields have kinds too, from its Zig type (text `string`, whole numbers `integer`, a
`bool` `boolean`, `publr.Time` `datetime`, an enum `select`, any other struct `group`),
so a remote record on one is checked the same way.
A mismatch on a plugin in `.depends_on` keeps the plugin from being enabled, and its page
says why ("products 0.2.0 has no sku on products.variant"); an update of the other plugin
that would cause one is refused until the plugin is updated or removed. A mismatch on a
plugin in `.compatible_with`, or that plugin missing, switches only that remote off: a call
answers `error.Unavailable`, its hooks don't run, a read of its records answers
`error.Unavailable`; the rest of the plugin works, and its page lists what is off and why.
When both are compiled in, a mismatch on a plugin in `.depends_on` fails the build; one in
`.compatible_with` builds with a note (`note: stocktake: shelf.count is switched off: …`),
leaves that remote's hooks out of the binary, and the remote is off from the start, listed
on the Built-in tab under "Switched off".

A remote operation is called (`ctx.call(Subscribe, ...)`) and hooked like any operation; a
remote event is hooked (`publr.on(OutOfStock, run)`); an operation's own event is its
answer. A remote record is a typed handle (`get`, `find_one`, `find`, `many`, `save`,
`Ref`) that answers only the fields listed, the others never reaching the plugin; reading
it still needs a `records.read` permission naming it.

## Field kinds and field groups

```zig
/// Location
///
/// A point on a map, with its address.
pub const Location = struct {
    lat: f64,
    lng: f64,
    address: []const u8,
};

fn check(value: Location, problems: *publr.Problems(Location)) void {
    if (value.lat < -90 or value.lat > 90) {
        problems.add(.lat, "Must be between -90 and 90");
    }
}

// in define:
.field_kinds = &.{publr.field.kind(Location, .{ .name = "location", .validate = check })},
```

Named `<plugin>.<name>`; its storage follows the value (text, a whole number, a number,
yes or no, a struct kept as JSON); `.validate` runs on every write; `.icon` is optional.
Field editors are not built: the form shows such a value as JSON.

```zig
/// Loyalty
pub const Points = struct {
    /// Points held now
    points: i64 = 0,
};

// in define:
.register_fields = &.{.{
    .fields = Points,
    .location = &.{.{ .rules = &.{.{ .field = "destination", .value = "user" }} }},
}},
```

A group of fields on users, media or any type, placed by core's location rules (groups of
rules, any group matching), named after the plugin.

## Roles

```zig
// in define:
.roles = &.{.{
    // An existing role gains these grants; a new name is a new role.
    .name = "editor",
    .label = "Editor",
    // Operations, or a namespace ending in `.*`.
    .grants = &.{"notes.*"},
}},
```

Installed, a role grants only the plugin's own operations.

## Admin entries

### Pages in the plugin frame

```zig
const entries: publr.plugin.Page = .{
    // Lowercase letters, digits, dashes; at /admin/plugin/<plugin>/entries.
    .path = "entries",
    .label = "Notes",
    .icon = "list-unordered",
    // A read: `In` has `query` and `base`, `Out` has `html`, all `[]const u8`.
    .operation = Page,
};

// in define:
.pages = &.{entries},
```

The answered `html` runs in a sandboxed `<iframe>` with the admin's stylesheet and a
bridge: `publr.call("<own operation>", input)` and `publr.navigate("<own page>?q=1")`. No
network, no session. Compiled in, a page can render the admin's own layouts with
`publr.admin.render.document(arena, publr.admin.chrome.in_plugin_frame(ctx, in.base),
View, props)`, in the person's language.

A page by declaration needs no markup; the admin draws the form:

```zig
const settings: publr.plugin.Page = .{
    .path = "settings",
    .label = "Notes settings",
    .icon = "settings",
    .form = .{ .read = Read, .save = Save, .multiline = &.{"description"} },
};

// in define
.pages = &.{settings},
```

`Read` is a read with no input answering the values; `Save` is a write taking every
field. Each field's `///` is its help. Pages, their top bar counts, panels, row actions and
Settings pages may name operations made with `publr.operation.define`.

A page that also says `.top_bar = .{ .count = Count }` is in the top bar too, for whoever may
see it; `Count` is a read with no input answering `count: i64`, shown beside its label.

A page that says `.menu = .none` has no entry in the menu: it still opens at its address,
for links of the plugin's own. Records take the same, `.menu = .none`: a settings record
edited on the plugin's own form page then has no second entry of its own.

### Menu items

```zig
const shop_menu: publr.MenuItem = .{
    .name = "shop",
    .label = publr.t("Shop"),
    .icon = "products.bag",
};

const store_menu: publr.MenuItem = .{
    .name = "store",
    .label = publr.t("Store"),
    .icon = "tag",
    .parent = &.{"products.shop"},
};

// in define:
.menu = &.{ shop_menu, store_menu },

// on a record, its own or another plugin's: the first parent that exists
.menu = .{ .parent = &.{ "products.store", "checkout.orders" } },
```

The admin's menu is built from menu items. An item whose parents do not exist is a part of
the admin of its own, pinned to the rail by whoever wants it; its children are headings in
its sidebar, each listing what sits under it (deeper items list under their heading). An
item opens a page (`.page`), one of the plugin's own record types' lists
(`.record = Orders`), or nothing (a heading). Records and other plugins' items name it
`<plugin>.<name>` to sit under it; the plugin that owns it never knows them. The top item's
own plugin's headings and types come first.

### Default view

```zig
.data_view = .{
    .columns = &.{ .number, .name, .total, .fulfilment, .status },
    .filters = &.{
        .{ .field = .status, .is = .placed },
        .{ .field = .total, .more = 4999 },
        .{ .field = .placed_at, .in_the_past = "7d" },
    },
    .order = .{ .field = .number, .direction = .desc },
},
```

Where a record type's list starts: the columns after the title (fields a cell shows as
text, and core's `slug`, `status`, `updated`, `created`), filters people clear like any
filter, and the order. A filter is one operator the field's kind offers: text `is`,
`is_not`, `contains`, `not_contains`, `starts_with`; a choice `any_of`, `none_of`; yes/no
`is`; numbers and money `is`, `is_not`, `less`, `more`, `at_most`, `at_least`, `between`
(`.{ 10, 20 }`); a moment `on`, `not_on`, `before`, `after`, `before_inc`, `after_inc`,
`in_the_past`, `over` (`"7d"`, `"2w"`, `"3m"`, `"1y"`), `between`; a reference `any_of`,
`none_of`, `all_of` (several). A field that does not filter or order (`.fields.x.filterable`,
`.sortable`), or a name the type lacks, fails the build. This is only the start: each
person rearranges the list, saves it as their own default or a view, and administrators
save it for everyone.

### Icons of the plugin's own

```zig
.icons = &.{.{ .name = "bag", .svg = @embedFile("icons/bag.svg") }},
```

At most 16 drawings of 24×24, in strokes of `currentColor`, 4 KiB each, named
`<plugin>.<name>` wherever an icon is given (`.icon = "products.bag"`). A name neither in the
set nor in `.icons` fails the build. Every drawing goes through the admin's SVG sanitizer
before a page shows it; core writes the `<symbol>` around it.

### Panels and row actions

```zig
.panels = &.{.{ .type = "product", .label = "Stock", .operation = StockPanel }},
.row_actions = &.{.{
    .slot = "orders",
    .label = "Print slip",
    .path = "/admin/plugin/slips/print?order={name}",
    .operation = Print,
}},
```

A panel is a read taking `record` and `base`, answering `html`, drawn in the plugin frame
on every record of the type. Row actions are built-in only. What the plugin's page in the
admin says about it is its `//!` past the first line, through the admin's sanitizer.

### Admin views in PTSX

Views live in `ui/<Name>.ptsx` beside `main.zig`, import `@publr/ui/<Name>.ptsx` and
`@publr/admin/<Name>.ptsx`, and return an admin layout (`IndexPage`, `FormPage`,
`HubPage`, `CardPage`, `ListDetailPage`). A page's read draws one and answers it, the same
either way the plugin runs:

```zig
return .{
    .html = try publr.views.render(ctx, in.base, publr.views.all.AnswersPage, .{
        .rows = rows,
    }),
};
```

Installed, `publr plugin build` lowers the plugin's views itself and the host draws every
design-system component they reach, so the plugin carries none of them. For now a plugin's
own markup takes no classes (style through the components), and the frame runs no islands.
Icons named only at runtime go in `ui/icons.txt`. In the page, `publr/operations` gives
`call("<op>")`, `query("<op>")` and ``query(groq`...`)``; `publr plugin build` writes
`ui/operations.d.ts`.

## Removal

Removing a plugin keeps its data unless an administrator ticks pieces on its page (its
types, internal records, field groups). Ticked pieces go to the trash, or are erased now.
Core knows all of an installed plugin's data, so a plugin runs nothing of its own.

## Checks

`publr plugin check --dir <folder>` prints, with file and line, money kept as a plain
number, a time as a number, a reference as text, JSON in text, an untrusted write taking
facts the server owns, and an import reaching outside the plugin's folder. A `Why:` line in
the field's `///` passes a name check. `plugin build` and `zig build` run the same checks on
every plugin registered through `define`.

## Built-in only

These run only when the plugin is compiled in (`publr.zon`, `.plugins.native`). Each is an
option of `define` under the name shown.

### Routes

```zig
.routes = &.{.{
    // .get or .post.
    .method = .get,
    // Under /admin/<own>, /api/<own> or /auth/<own>; `:id` segments are parameters.
    .path = "/admin/notes",
    .handler = &settings,
}},

fn settings(
    request: *publr.http.Request,
    response: *publr.http.Response,
    ctx: *publr.http.Context,
) publr.http.Error!void {
    var session = try publr.admin.require(request, response, ctx) orelse return;
    ...
    try publr.admin.screen(&session, .ok, publr.admin.views.NotesSettings, props, .{});
}
```

At most 16 routes. `publr.plugin_routes.caller_context` gives an SDK context as whoever
sent the request (CSRF checked on writes); `publr.plugin_routes.set_session` signs
someone in.

### Admin hooks

`.settings_pages` (each `{ label, icon, path, operation }`), `.settings_tabs`,
`.app_picker_segment` (`fn (*const publr.admin.Session, bool, ?publr.admin.render.Node)
publr.admin.Error!?publr.admin.render.Node`) and `.sign_in_at` (`fn (*const
publr.admin.Session) anyerror!?[]const u8`).

### State and the process

`.State`, a struct with optional `init(state: *State, process: publr.plugin.Process)` and
`deinit`, reached with `publr.plugin_states.of(ctx, @This())`; `.before_command` (`fn
(*publr.plugin_hooks.Command) anyerror!void`); `.serving` (`fn
(publr.plugin_hooks.Serving) anyerror!void`); `.operator_commands` (each `{ name, handler
}`, answered at `POST /_publr/<plugin>/<name>` with the operator key only). `Process` is
`{ io, gpa, arena, db_path, runtime }`, `Command` `{ io, arena, args, db_path }`,
`Serving` `{ io, arena, project, port }`. Never use a top-level `var`.

### Database

`.bootstrap` (`fn (*sdk.Ctx) sdk.Error!void`, every start, as the system),
`.schema_sql` and `.migrations` (`publr.db.migration.Migration`s). Prefer records; a table
of its own makes the plugin built-in only. An operation whose `run` takes `*sdk.Ctx` has
full access to the host and runs only built-in.

### Other built-in options

`.sign_in_provider` (see [Plugins](plugins.md#writing-a-built-in-plugin)), `.policies`,
`.filters`, `.delivery_gates` ([Apps](apps.md#delivery-gates)), `.variants`, `.agents_tab`,
`.admin_brand`, `.work_start`, `.hosted`, `.row_actions`. `.middleware` takes only the two
hooks `publr.before/after/on` don't say: on every operation before it runs (`stage = .pre`)
and on every event inside the write (`stage = .on` with no `event`). Their shapes are in
`src/sdk/plugin.zig` and the `src/model/` file each names.

## Model providers

A plugin becomes a model provider by listing operations built by `publr.ai` in
`.operations` (`publr.ai.Describe("<name>", .{...})`, `publr.ai.Complete("<name>",
complete)`, and `publr.ai.Transcribe("<name>", transcribe)` when it turns speech into
text) and registering them into core's `ai.model` contract with `.register_providers`:
`.{ .contract = publr.ai.contract, .name, .operations = .{ .describe, .complete } }`. See
[Plugins](plugins.md#model-providers).

## Building

```sh
publr plugin check --dir plugins/notes
publr plugin build --name notes        # plugins/notes/main.zig, for the sandbox
publr --as-admin plugin get --name notes
publr notes --help
```

Built-in: list it in `publr.zon` and run `zig build`. Worked examples:
`publr/plugins/hello` (records with a flow, an operation, hooks, an event), the
`plugin scaffold` templates (a list page, a settings form), `plugins/products` (records,
references, money, a filter, its own icons, menu items) and `site/plugins/waitlist` (an operation untrusted
callers reach).
