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
| `taxonomies` | `&.{ ... }` of `publr.taxonomy.define` | both |
| `register_taxonomies` | `.{ .{ .taxonomy, .to } }` | both |
| `operations` | `&.{ ... }` of `publr.operation.define` | both |
| `hooks` | `&.{ ... }` of `publr.before`, `publr.after`, `publr.on`, `publr.modify` and `publr.hook.request` (built-in for now) | both |
| `events` | `&.{ ... }` of `publr.event.define` | both |
| `jobs` | `&.{ ... }` of `publr.job.define` | both |
| `ledger` | one `publr.ledger.define`, see [The ledger](#the-ledger) | both |
| `webhooks` | `&.{ ... }` of `publr.webhook.define`, see [Webhooks](#webhooks) | both |
| `permissions` | `&.{ .{ .key, flags, .reason } }` | both (checked at compile time, enforced installed) |
| `secrets` | a struct of `publr.Secret` fields | both |
| `limits` | `publr.plugin.Limits` | installed |
| `depends_on`, `compatible_with` | `.{"newsletter@^1.2"}` | both |
| `remotes` | `&.{ ... }` of `publr.remote.operation`, `.record`, `.event` | both |
| `field_kinds` | `&.{ ... }` of `publr.field.kind` | both |
| `register_fields` | `&.{ .{ .fields, .location } }` | both |
| `roles` | `&.{ ... }` of `publr.plugin.Role` | both |
| `user_types` | `&.{ ... }` of `publr.plugin.UserType`, see [User types](#user-types) | both |
| `contracts`, `register_providers` | see [Contracts and providers](#contracts-and-providers) | both |
| `pages`, `panels`, `menu`, `icons` | see [Admin entries](#admin-entries) | both |
| `translations` | `&.{ .{ .locale, .label, .po } }` | both |
| `dimensions` | `&.{ ... }` of `publr.dimension.define`, see [Dimensions](#dimensions) | both |
| `extend` | `fn (host: *publr.Host) publr.Error!void`, see [Built-in only](#built-in-only) | built-in |
| `row_actions` | see [Panels and row actions](#panels-and-row-actions) | both |

Any other option is a build error.

Decided but not built: `register_components`. Outside search engines and field editors in the
plugin frame come with later gates too.

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
other than slices, no functions. Defaults make a field optional for the caller. Money is
`publr.Money` (`publr.Money.of(arena, "PLN", 12300)`, `price.get("PLN")`, `price.in("PLN")`,
`price.single()`, `price.put`, `price.add`; JSON writes it `{ "PLN": 12300 }`).

A record, a list or a map in `In` or `Out` is a value: a struct or a slice, or
`publr.sdk.operation.Json` where its shape comes with the data. Text holding JSON does not
compile: a text field whose example is a JSON object or array, or whose words say JSON, is
refused with the operation and the field named. Core's operations follow the same rule
(`record.get` answers `document` as an object), and an installed plugin's typed reads
(`Record.get`, `publr.fields.get`, a query's result, a provider's answers) arrive laid out
as their structs, never as text to read. What it sends goes the same way: an operation's
input, `publr.fields.save`, an event's payload (`ctx.emit`) and a queued job's input
(`ctx.enqueue`) are handed over as they lie, and a call to another installed plugin's
operation reaches it with no JSON in between
([how values cross](plugins.md#how-values-cross)). An optional holding nothing arrives as
`null`. A `publr.sdk.operation.Json` is read with `json.as(Shape, arena)` or part by part
with `json.read(arena)`, and made with `Json.of(arena, value)`: a plugin never touches JSON
text to talk to Publr. An operation named only when the plugin runs is called with
`ctx.call_named(Out, name, in)`.

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

`publr.Error` is `Denied`, `Invalid`, `NotFound`, `Conflict`, `Throttled`,
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
| `ctx.translate(label)` | words marked where they were written (`publr.t`, another plugin's `ctx.t`) and kept as written, such as a label another plugin stored, in the caller's language |
| `ctx.log(.info, "Charged {s}", .{amount})` | a log line with a level, `.info`, `.warn` or `.err`, kept with the call: under its entry in the Activity log (a write) or Error log (a refusal or failure, rolled back or not), and on the plugin's Log tab (`plugin log`). A queued job's run keeps its own (`job:<plugin>.<name>`), an event's `on` hooks theirs (`event:<name>`). An `.err` line in a call that answered adds an Error log entry, error `Logged`. At most 100 lines a call, 1 KiB each |
| `ctx.now()` | `publr.Time`, the call's time (on a test site, as `project set_clock` moved it): `.ms`, `before`, `after`, `add_minutes`, `add_days`; on the site's clock (`zone`, below) `local_date(zone)` (a `publr.Date`), `start_of_day(zone)`, `end_of_day(zone)` (the next day's start), `add_months(zone, n)` and `add_years(zone, n)` (the same time of day, on the month's last day when it has fewer: 31 January and a month is the end of February), `days_until(zone, other)` (whole days between their dates: the nights of a stay) |
| `ctx.time_zone()` | `publr.TimeZone`, the site's: `.name` (`Europe/Warsaw`, `UTC` until one is chosen) and its `.rule`, summer time included. A `publr.Date` (`.year`, `.month`, `.day`) has `add_days`, `add_months`, `add_years` (month-end clamped), `days_until`, `before` |
| `try ctx.random(&buffer)` | fills `buffer` (1 to 64 bytes) from the host's cryptographic source, compiled in and installed alike: for codes a person must not guess (a pickup code, a voucher), never a hash of an id |
| `ctx.caller()` | who calls: `.from` (`admin`, `command_line`, `api`, `app`, or `.{ .plugin = name }`: a plugin whose code called, compiled in or installed, its queued work too, Publr's own work `publr`), `.visitor` (the app visitor's stable id), `.referer` (the other site whose page sent the request, empty for the site's own; it tells, never grants), `signed_in()`, `has_role(name)`, `granted()`, `is(id)`, `account()` (the signed-in person's account as a `publr.Account`, null for nobody: keep it in a `publr.Account` field, a `user` field holding the id, never in text) |
| `ctx.grant(key)` | `.{ .on, .publish, .drafts, .domains }`: what the plugin was given for a request |
| `ctx.emit(Event, payload)` | emits an event declared with `publr.event.define`: its `after` hooks run now, inside the write (a refusal rolls it back); its `on` hooks hear it from the queue once the write commits |
| `ctx.enqueue(Job, in)`, `ctx.enqueue_at(Job, in, at)` | queues a job declared with `publr.job.define` |
| `ctx.make_file(type, filename)` | a file the plugin makes: `write(bytes)` as it goes (one 256 KiB piece held at a time, never the file), then `done()`, the file kept as a published file of one of the plugin's media types (`publr.record.define(..., .{ .kind = .media })`): `.id` (for a `reference` field, a signed link, an email's attachment), `.key`, `.size`. Its bytes must be what its name says (a PDF, a CSV, a PNG); past `.limits.file_mib` it fails `FileTooLarge`. A file of a private type opens to whoever may read the type; a link the plugin signed whose operation answers `{ "file": id }` downloads it for anyone holding the link |
| `ctx.arena()` | `std.mem.Allocator`, freed when the call ends |
| `ctx.alloc(T, n)`, `ctx.print(fmt, args)` | memory and formatted text freed when the call ends |
| `ctx.scope()` | memory of its own for one step of the call, given back at `end()` (below) |

`publr.json.parse(T, ctx.arena(), text)` and `publr.json.stringify(ctx.arena(), value)` read and
write JSON as `std.json` does (unknown fields skipped), at a cost close to the bytes: use them
over `std.json`, whose scanner spends hundreds of an installed plugin's instructions on a byte.
Within one call, a read the plugin made already answers again without the host until the
plugin writes.

### Memory for one step: `ctx.scope()`

Everything a call allocates and reads stays until the call ends. An operation with several
large steps (read an order, change it, read it again) would hold all of them at once. A
scope gives a step memory of its own:

```zig
var step = ctx.scope();
defer step.end();

const order = try Order.get(ctx, id);
const total = sum(order.lines);
```

- From `ctx.scope()` until `end()`, `ctx.arena()`, records read and answers of calls are in
  the scope's memory. `end()` gives all of it back.
- Nothing made inside may be used after `end()`. Carry a number or an enum out by value.
  Copy text out with `try step.keep(text)`, which puts it in the memory the call had before
  the scope.
- `step.leave()` goes back to the call's memory while what the scope holds stays readable
  until `end()`: for something read once and used by the steps after it.
- Scopes nest. End the inner one first, as `defer` does.
- A read made inside a scope is forgotten at `end()`: the same read after it asks the host
  again.

A plugin then takes the memory of its largest step, not the sum of its steps, installed or
compiled in. Compiled in, the scope's memory comes from the memory Publr sets aside for
compiled-in plugins' work ([plugins.md](plugins.md#limits)); where a process sets none aside
(the browser build), the step works in the memory it began in and `keep` still copies.

What must outlive a loop or a scope goes in the SDK's own collections: `publr.List(T)`,
`publr.IdMap(V)` (keyed by text that is mostly ids) and `publr.IdList(V)` (one that keeps the
order keys were put in). Each is made with `init(ctx)` and remembers the memory it was made
in: `var at = publr.IdMap(u32).init(ctx);` before a walk, then `try at.put(id, 1)` inside it
keeps what each row puts there, while the row's own memory goes. None takes an allocator:
`put`, `get`, `get_ptr`, `get_or_put`, `contains`, `count`, `reserve`; a list `append`,
`append_slice`, `items()`, `len()`; an `IdList` `keys()` and `values()` in order. A standard
library container takes an allocator on each call and grows in whatever memory is open, so
inside a walk it grows in the row's. Each collection tells how much it holds as it grows: a
plugin that runs out of memory, or that a request leaves holding more than half of what it
may, is named in the log with the largest collection it made ([plugins.md](plugins.md#limits)).
The maps hash eight bytes at a time in 64 bits; the standard text map hashes with 128-bit
multiplies, which an installed plugin runs in software.

The SDK opens a scope for you where it calls core in a loop: each page of `create_many` and
`save_many`, and each item of a hook run over many items. What a call into core left behind
in core is given back as soon as the plugin has its answer.

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
a handle's `Ref` or `publr.record.AnyRef` `reference` (both kept and sent as the id
alone), a slice of them many. As an operation's input, an `AnyRef` is read before `run`:
its `type`, its `value` (the record's JSON) when the caller may read it, `missing` when it
is gone. A field with
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

An internal record runs the same field rules as content on every write, in the write's
transaction: whatever `.fields.<field>.validation` gives (bounds, lengths, shapes), a
`ProviderRef` naming a provider of its contract, and the record's `.validate`. A `.unique`
field is held by one record of the collection at most (in its scope): another write of the
same value is a conflict, so a caller's id is an idempotency key. A unique field is indexed
whether `.indexed` names it or not, and found by it with `find_one`:

```zig
pub const Transfers = publr.record.define(Transfer, .{
    .name = "orders.transfer",
    .internal = true,
    .append_only = true,
    .fields = .{
        .key = .{ .validation = .{ .unique = true } },
        .amount = .{ .kind = "money", .validation = .{ .min = 1 } },
    },
});
// The same transfer sent twice is kept once:
if (try Transfers.find_one(ctx, .key, key)) |kept| return kept.id;
_ = try Transfers.create(ctx, transfer); // error.Conflict if another write took the key
```

A field `.visibility` says who reads its value; by default whoever reads its record.
`.restricted = true` keeps it to the plugin declaring the type, people holding one of
`.roles`, and administrators; `.special = true` (special-category data, such as health) keeps
it to the plugin and `.roles` alone, never administrators, the system or a device. A record
read through `record.get`, `record.list`, GROQ, snapshots and `internal.*` leaves out the
fields its caller may not read; a list's filter or order on one is refused as on a field the
type does not have, so a GROQ condition on it matches nothing; writing one is refused. The
admin's record form and lists leave it out for whoever may not read it: special-category
data shows only on its declaring plugin's own pages. Devices (agents, the CLI) and the
system never read a special one. Such a field is never searchable, unique or indexed:

```zig
.fields = .{
    .prescription = .{ .visibility = .{ .special = true, .roles = &.{"pharmacist"} } },
},
```

A list of structs is a repeater: its rows' fields come from the row struct the same way,
each with its `///`, overridden through `.fields.<list>.fields.<field>`. A text field's
default (`= "Placed"`) is the field's default in the form.

The handle reads and writes typed values: `Notes.get(ctx, id, .{})` (a record in the trash is
not found; `Notes.get(ctx, id, .{ .trashed = true })` reads it),
`Notes.find_one(ctx, .slug, value)`, `Notes.create(ctx, value)` (the new id, in the flow's
start), `Notes.save(ctx, held, .{ .note = "..." })` (writes only the fields named onto the
record read; a conflict only when one of them changed since `held` was read; never the
status), `Notes.transition(ctx, held, .publish)`. `Notes.Held` is `{ id, version, status,
changed, value }`, its `status` the record's enum; `Notes.Ref` takes one by id. An internal
record has no status: `{ id, version, value }`, and `Lines.delete(ctx, held)` erases it. `Lines.clear(ctx, held, .{ .note })` empties
optional fields of one (a field `save` gives as `null` is left as it was; `internal.save`
takes the same as `clear`, a list of names).
Many internal records at once: `Lines.create_many(ctx, values)` (their ids, in order) and
`Lines.save_many(ctx, ids, changes)` (each change onto the id at its place), a page of 200 a
call, so a write over thousands of records costs a few calls, never one each. Many read by
id are one call too: `Lines.many(ctx, ids)`, and `Lines.many_of(ctx, Shown, ids)` for only
the fields `Shown` names (up to 200 ids; one that is not there is left out).
Many internal records are walked, found by an indexed field: `var lines =
Lines.where(ctx, .order, id);` then `while (try lines.next()) |line|`, a page of 200 held at a
time and each row's own memory given back at the next (`Lines.all(ctx)` for every record;
`.newest()`, `.first(n)`, `.as(Shown)` before the first row; `.count()`, `.any()`, `.one()`
without walking; `lines.keep(text)` and `lines.kept(line)` for what outlives the loop;
[Reads are walks and pages](plugins.md#reads-are-walks-and-pages)). A screen reads a page:
`Lines.page(ctx, .order, id, .{ .limit = 10, .offset = 0, .oldest = true })` (50 rows unless
it says, 200 at most; the newest first unless `.oldest`), and `Lines.page_of(ctx, Shown,
.order, id, .{})` for only the fields the struct `Shown` names.
Lists of content are GROQ ([Queries](#queries)). Its own types need no permission.

Every list an operation takes or answers holds at most 200 items unless the struct holding
it says fewer (`pub const limits = .{ .tags = 20 };`); what may hold more is answered a page
at a time, `after: []const u8 = ""` in and `next: []const u8` out. A walk hands over one page
and its `next` with `Lines.where(ctx, .order, id).page_after(in.after)`; a caller walks every
page of such an operation with `var pages = publr.pages(ctx, Operation, in);` and
`while (try pages.next()) |page|`, one page held at a time: a page's memory goes at the next,
so what outlives the loop is copied with `pages.keep(text)` and grows in `pages.memory()`
([Lists in an operation hold a page](plugins.md#lists-in-an-operation-hold-a-page)).

### Computed fields

A field of an internal record worked out by the plugin, stored with the record and worked
out again when anything it read has changed
([Computed fields](plugins.md#computed-fields)):

```zig
.fields = .{
    .priced = .{
        .kind = "virtual",
        .options = .{
            .virtual = .{
                .computed = priced,
            },
        },
    },
},

fn priced(ctx: *publr.Ctx, line: *const Line) publr.Error!Priced { ... }
```

| Part | What it does | Mode |
|---|---|---|
| `.virtual = .{ .computed = fn }` | `fn (*publr.Ctx, *const Doc) publr.Error!Field` works the field out (`fn (*publr.Ctx, id: []const u8, *const Doc)` when it needs the record's id); `.kind = "virtual"`; internal records only, at most 8, never indexed | both |
| reading the record | the stored value, worked out again first when stale: when a record, list or operation it read changed, its time passed, or its modifiers changed | both |
| `create`, `save` | work the values out in the same write, after it; a value the caller sends is ignored | both |
| `ctx.holds_until(time)` | inside the function: the answer holds until `time`, the earliest said | both |
| `publr.modify("<record>.<field>", run)` | changes the value as it is worked out, before it is stored; `run` takes `*publr.Computed(Doc, Field)`: `.id`, `.record`, `.value` | both |
| `.sum("path")` on a walk | `Lines.where(ctx, .cart, id).sum("priced.total")`: a whole number added up by the database, the values worked out first where stale; the path is checked against the type | both |

The function and its modifiers only read, and get no reader: the caller is the system, no
person, visitor, cookie or page, the main language, live records. Installed, they reach
what their plugin's grant reaches. Values reading other computed values nest 4 deep; past
that the stored value is read. `computed.<record>.<field>` is the name core works a value
out under: `publr.modify` refuses it.

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
names, fails the build. `.{ .trashed = true }` includes records in the trash. A content
record's `status` is a field like any other (`status == "published"`). A plugin's
code reads its own internal records the same way (`_type == "cart.line"`, in the request's
app), and another plugin's only through a `records.read` naming them (or `.internal`).

### Taxonomies

```zig
//! Topics
//!
//! What a post is about. Topics nest, each with a colour.

const Topic = struct {
    /// Colour
    colour: ?[]const u8 = null,
};

pub const taxonomy = publr.taxonomy.define(Topic, .{
    .name = "topic",
    .public = true,
    .hierarchical = true,
    .fields = .{
        .colour = .{
            .kind = "color",
        },
    },
});
```

A taxonomy is stored as `<plugin>.<name>` (`blog.topic`), listed in `.taxonomies`. Its name
and description are the `///` above it or its file's `//!`. Every term has a name and a slug;
`Term` holds the rest, each field labelled by its `///` and overridden by name as a record's
fields are. `.public` lets any visitor read its live terms (private by default, read by the
roles that reach it); `.hierarchical` lets terms nest, and filing a record under a term files
it under every ancestor; `.single` takes one term per record; `.internal` never reaches the
site: no term pages, nothing in templates, in a visitor's GROQ or in an app's call.

A taxonomy never names types. Your own type lists its taxonomies, yours or the site's:
`.taxonomies = &.{ "blog.topic", "tags" }` on `publr.record.define`. Each is a picker in the
editor's sidebar, a column and a filter on the list, and comes back on `get` under its name
with the dot an underscore (`blog_topic`, a list of term ids); GROQ filters on it
(`$topic in blog_topic`). A `terms` field of the form (`.kind = "terms"`,
`.options = .{ .taxonomy = "blog.topic" }`) puts the picker in the form instead, and the
taxonomy leaves the sidebar.

`.register_taxonomies = .{ .{ .taxonomy = "shipping.region", .to = &.{ "products.*",
"events.event" } } }` puts a taxonomy on other plugins' types, neither knowing the other: one
type by name, every type of a plugin (`plugin.*`), or every type (`*`), content types only.
A pattern never picks an internal taxonomy; name the type for that. It waits while nothing
matches. An administrator can take it off a type in the type's settings: it hides, and the
records keep their terms for when it is ticked again. A taxonomy's settings list the types it
is on and who put it there. When a plugin that is present lacks a type you name, your
plugin's page says so; a plugin that must have the type says so in `.depends_on`.

A plugin's own taxonomies are its own as its types are: reading and writing their terms takes
no permission. Uninstalling offers them, with their terms, among its data.

### Dimensions

A field may hold a value per combination of dimensions: a site's languages, an A/B test's
variations. A plugin declares a dimension and, beside it, how others use it: a *wrapper*
in its own words, a field option (`.translatable = .required`) and a read option
(`.language = "pl"`). The core draws the field option on every field's panel, a picker in
the editor, stores each value beside the field (`title@language=pl,variation=b`) and
reads it with fallback.

```zig api.zig
//! Content per variation of the site's A/B test: how other plugins' fields and reads say it.

const publr = @import("publr");

/// Whether the field holds a value for each variation of the A/B test.
pub const Tested = enum {
    /// Not tested
    /// One value for every variation.
    no,
    /// Tested
    /// A value for each variation; one left empty shows the control's.
    yes,
};

fn holds(tested: Tested) publr.dimension.Holds {
    return switch (tested) {
        .no => .one,
        .yes => .fallback,
    };
}

/// Test variations
pub const field = publr.dimension.field_option(.{
    .name = "tested",
    .takes = Tested,
    .holds = holds,
});

/// Variation
pub const read = publr.dimension.read_option(.{
    .name = "variation",
});
```

```zig main.zig
/// Content per variation of the site's A/B test, chosen per visitor.
const variation = publr.dimension.define(.{
    .name = "variation",
    .priority = 10,
    .api = @import("api.zig"),
    .list = Variations.List,
});

// in define:
.dimensions = &.{variation},
```

```zig another plugin
// It lists "ab_test" in .depends_on or .compatible_with; it never imports it.
.fields = .{ .headline = .{ .tested = .yes } },

const product = try Products.record.get(ctx, id, .{ .variation = "b" });
```

- `.api` is the wrapper. Its words are its doc comments: the field option's `///` is the
  setting's name on the field panel, its enum's `///` what the setting means, each value's
  `///` a choice (a first line, then what it means), the read option's `///` the editor
  picker's word. A missing one fails the build.
- `field_option(.{ .name, .takes, .holds, .options })`: `.takes` an enum; `.holds` maps each
  value to a `publr.dimension.Holds`, no two the same and one `.one`. `.options` is a view
  that draws the setting itself in the plugin frame (`ctx.value` the value the field holds,
  null for none; `ctx.change(value)` hands another to the form): the languages plugin's is
  two rows, the second asked only for Optional. Without it the core draws a card per value.
- `read_option(.{ .name })`: what a read names the dimension by, on the CLI (`--variation b`),
  in JSON and in a record's `get`. The dimension's own name works too.
- A field of a plugin's record says it with the option's name (`.tested = .yes`): made
  into how the field holds the dimension's values when the plugin's types are applied, at
  boot or install; with no plugin offering the option, it does nothing. A value the option
  does not take fails the build when both plugins are compiled in, and refuses the install
  otherwise. Until published interfaces, an installed plugin's misspelt option name is not
  caught.

- `.name` is what values are stored and asked for under: `--variation b`, `"variation": "b"`.
- `.param` is its key in an address's query, where the editor keeps what it shows
  (`?lang=pl`); its name when left out.
- `.list` is a read of the plugin's own answering `values`, each a `publr.dimension.Value`
  (`code`, `label`, `address`, `main`), the main one first.
- `.priority`: a read with no value in a combination drops the lowest priority dimension
  first. The languages plugin's `language` is 100.
- `.addresses = true`: the values have pages of their own under their `address` (`/pl`).
  At most one on a site.
- Whether values are required is each field's, never the dimension's: a field holds a
  dimension as one value for all, required in each value going live, or optional with an
  empty value showing nothing or what it falls back to (`publr.dimension.Holds`). Checked
  when a record is published or moves to a live status, each missing value refused under
  its key (`body@language=pl`, `Required in Polski`); drafts always save.

Up to 64 dimensions on a site, from different plugins, combine: a field varying by
`language` and `variation` holds a value for each pair, one value naming at most four of
them. A read looks only at the values a field holds, so many dimensions cost a field no
more than its own.

### Field markers

Beside each field's label in the editor, plugins put markers: the languages plugin a pill
per language, green where the field holds a value in it; an A/B test the variations that
change it. The editor asks `record.markers` with the record as it stands, saved or not,
as values change; it applies `<type>.markers`, one `publr.FieldMarkers` item per field
(`field`, the dimensions it `varies_by`, the values it is `required` to hold, the whole
`record`, the `markers` so far), for modifiers to add their own `publr.Marker`:

```zig
// in define:
.hooks = &.{
    publr.modify("*.markers", Markers.run),
    publr.modify("*.*.markers", Markers.run),
},
```

- `.label`, and `.tone`: `outline`, `neutral`, `success`, or `danger` for a value that must
  be filled and is not.
- `.dimension` and `.code` make it a link: clicking it shows the field there (an empty code
  is the main value). Markers of one dimension are drawn together as one pill, `.group`
  first when given (a test's name); the one the editor shows is drawn selected.
- `.current = "hide"` leaves it out while the editor shows the field at its code.

### Field help

The help under a top-level field may follow the values: the editor applies
`<type>.<field>.help` when it draws the form and again as values change, with a
`publr.FieldHelp(Doc)` (`field`, the `record` as the editor holds it, typed, and the `help`
so far). Set `help`; up to 280 characters, plain text.

```zig
/// Says under a sample note how much of it is written, as it is typed
fn note_help(ctx: *publr.Ctx, item: *publr.FieldHelp(Note)) publr.Error!void {
    item.help = try ctx.print("{d} characters so far.", .{item.record.note.len});
}

// in define:
.hooks = &.{publr.modify("notes.note.note.help", note_help)},
```

`*` stands for one dotted part, and a plugin's type names carry its name
(`notes.note.note.help`), so `*.*.help` reaches only the site's own types.

Help may also be a view of the plugin's: a panel with `.field` is drawn under that
top-level field, in the plugin frame, on any type's form (a new record's too). Its view's
`ctx.value` is the field's text as the form holds it, empty for none, and changes as the
person types; copy it into the view's own store with `Publr.effect` to redraw:

```zig
// in define:
.panels = &.{.{
    .type = "post",
    .label = "SEO strength",
    .operation = SeoStrength, // a read taking `record` (empty on a new one) and `base`
    .field = "title",
}},
```

```tsx
export function SeoMeter({ ctx }: { ctx: EditorCtx & { value: string } }) {
  const state = Publr.reactive({ length: ctx.value.length });
  Publr.effect(() => {
    state.length = ctx.value.length;
  });
  return <p>{state.length > 60 ? "Too long" : "Fine"}</p>;
}
```

A view whose root is a layout (`PanelPage`) keeps its store in a component of its own, as
`SeoMeter` is here.

## The ledger

Exact counted balances: store credit, gift cards, points, a buyer's receivable, what a shop owes
an affiliate, credits. Core keeps a double-entry ledger, after TigerBeetle: accounts that count
one unit for the plugin that opened them, and transfers between them that are never changed
or removed. Core keeps the mechanism; what an account is for and why money moved stay the
plugin's. People only read it (a plugin's Ledger tab, Settings › Ledger, `publr ledger`);
plugin code moves it.

Declare it once, beside the records, and list it in `define`. Account names are the fields of
a struct, each with its kind and limit; reasons are an enum; declared units a struct. The
words come from doc comments, and a missing one fails the build.

```zig
/// Points
///
/// Earned on purchases, spent as a discount.
pub const Ledger = publr.ledger.define(struct {
    /// Points held
    held: publr.ledger.Liability(.{ .never_below_zero = true }),
    /// Points given
    given: publr.ledger.Expense(.{}),
}, .{
    .reasons = Reason,
    .units = Units,
});

pub const Reason = enum {
    /// Earned on an order
    earned,
    /// Spent at checkout
    spent,
};

pub const Units = struct {
    /// Points
    points: publr.ledger.Unit(.{ .scale = 0, .symbol = "pt" }),
};

pub const plugin = publr.plugin.define(manifest, .{
    .ledger = Ledger,
    .operations = &.{Earn},
});
```

**Kinds** are `Asset`, `Liability`, `Equity`, `Income` and `Expense`: assets and expenses grow
by debits, the rest by credits, and a balance reads on the side its kind grows on. **Limits**:
`.never_below_zero` or `.never_above_zero`, at most one, holds counted, checked inside the
write.

**Units.** A currency, `publr.ledger.unit("PLN")`, at its ISO 4217 scale; a declared unit,
`publr.ledger.unit("loyalty.points")`, at the scale it declares; either counted per record,
`publr.ledger.unit_of("inventory.pcs", variant)`. Any plugin may count in any unit. Amounts are
positive `i64` in the unit's smallest step; the direction is debit and credit. Two accounts
transfer only in the same unit, item included (`UnitMismatch`).

**Accounts** are opened on first use: `Ledger.open(ctx, .held, .{ .holder = .{ .person = account },
.unit = unit })` answers the same account every time for the same name, holder (a record or a
person's account), `.key` (a word, for many accounts tied to no record) and unit. Keep one in a
record as a `publr.ledger.Account` field, and a transfer as a `publr.ledger.TransferRef`: both are
references, never ids in text.

| Call | What it does | Answers |
|---|---|---|
| `Ledger.transfer(ctx, .{ .id, .debit, .credit, .amount, .reason, .about, .detail, .happened_at, .up_to })` | posted at once; `.up_to` moves what the limits allow, maybe nothing | `.{ .transfer, .amount, .made }` |
| `Ledger.hold(ctx, .{ …, .expires_at })` | pending: counts against limits, not in the posted balance | the same |
| `Ledger.post_hold(ctx, .{ .hold, .amount })` | posts the hold for its amount or less; left out, all | the same |
| `Ledger.void_hold(ctx, .{ .hold })` | releases it | the same |
| `Ledger.chain(ctx, &.{ .{ .transfer = … }, .{ .hold = … }, .{ .post_hold = … }, .{ .void_hold = … } })` | steps posted whole or not at all, each seeing the ones before | one answer per step |
| `Ledger.reverse(ctx, .{ .id, .transfer, .amount, .reason })` | the same accounts the other way, never more than is left | the same |
| `Ledger.convert(ctx, .{ .id, .from, .to, .amount, .rate, .source, .reason })` | two legs through exchange accounts, the second at `rate` (`publr.Decimal(6)`) rounded down | `.{ .from, .to }` |
| `Ledger.close(ctx, account)`, `Ledger.reopen(ctx, account)` | a closed account takes no transfer but voiding a hold on it | |
| `Ledger.get(ctx, id)` | one of the plugin's transfers by its own id | `publr.ledger.Transfer` |

**Retries are harmless.** The `.id` is the plugin's own: the same id with the same parts does
nothing and answers the transfer made then (`made = false`); with any part different it is
refused (`Taken`). A hold settles once: posting it again for the same amount answers the
first post. A chain is a savepoint in the call's write: refused, it undoes only itself, and the
caller may catch it and go on; uncaught, the whole call rolls back, the plugin's records with it.

**Holds expire.** A hold with `.expires_at` not settled by then is voided by core, as a queued
job of its own (a test site's clock moves it); the owner hears `publr.ledger.Expired`
(`publr.on(publr.ledger.Expired, run)`). Past its time a post is refused (`Expired`).

**Reads**, on any account the plugin may read: `publr.ledger.balance(ctx, account)` (unit,
posted, pending, available, the four totals; `balance_at(ctx, account, .{ .at })` the posted
balance as it stood then), `history(ctx, account, .{ .about, .from, .to, .before, .limit })`
(newest first, each line with its side, amount, balance after and status; the next page starts
`.before` the last), `get(ctx, transfer)` and `accounts(ctx, .{ .owner, .name, .holder, .unit })`.

Transfers about a record are read a page at a time, and a figure is never added up from them:

| Call | Answers |
|---|---|
| `publr.ledger.page(ctx, .{ .about, .detail, .reason, .account, .name, .after, .limit, .newest })` | `.{ .transfers, .after }`: one page (50 unless `.limit` says, 200 at most), oldest first unless `.newest`; the next page takes `.after` |
| `publr.ledger.totals(ctx, .{ .about, .detail, .details, .reason, .account, .name, .from, .to })` | debits and credits, posted and pending, per reason and unit; with `.details` (up to 200 ids) one sum per detail too |
| `publr.ledger.find(ctx, .{ .about, .detail, .reason, .account, .name })` | every transfer that matches, oldest first, read 200 at a time; more than 20,000 is refused |

Every filter given must match; at least one of `.about`, `.detail`, `.account` and `.name`
is given, and each is read through an index. `.reason` is the reason's name
(`@tagName(Reason.payment)`), `.name` one of the plugin's account names. A balance of the
plugin's accounts of one name for a record is `totals(ctx, .{ .about = order, .name =
"receivable" })`: the database adds it up and no transfer is read. A page that shows ten
charges asks `totals` once with their ids as `.details`. Use `find` only where every
transfer is really needed; a list shows a `page`.

**Refusals**, named so `ctx.failure()` tells them apart after `error.Failed`: `NotYours`,
`NoAccount`, `Closed`, `UnitMismatch`, `Unbalanced` (no amount, or one account on both sides),
`Overdrawn`, `Taken`, `NoHold`, `OverHold`, `Settled`, `Expired`, `OverReversed`, `TooLarge` (a
total past 64 bits).

**Who moves what.** A plugin moves its own accounts and no one else's (`NotYours`), with one
exception: while an operation runs that plugin P called directly, that operation may move P's
accounts for that call. P hands an account over by calling with it (`affiliates` calls
`orders.cost` with its `owed` account; `payments` calls `orders.pay` with its gateway account).
Hooks never get it. The transfer records both its maker and the plugin it was made for
(`made_for`), and either may reverse it. Writes take plugin code only: a person, an app or the
command line is refused.

**Reading another plugin's accounts** needs the `ledger.read` grant naming it, which the person
installing decides:

```zig
.permissions = &.{.{
    .key = "ledger.read",
    .plugins = &.{"orders"},
    .reason = "Shows a customer what they owe",
}},
```

Administrators read every account. A page drawn for the built site that reads an account is
built again when its totals change.

**Events.** Every write is one of core's operations and emits its event (`ledger.transfer`,
`ledger.chain`, …), so `after` hooks run inside the write and may refuse it, and `on` hooks
follow once it commits. A plugin removed keeps its accounts and transfers on the books, read
only, under its name.

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

An `after` hook that adds to a list read's rows (`out.extend(record, field, value)`) runs on
everyone's list reads but its own plugin's: what it adds is for others to read.

A `before` or `after` hook on an operation that names a content type (`type` in its input:
`record.list`, `record.create`) may say which type it is about:

```zig
publr.hook.about("orders.order", publr.after(publr.operations.record.List, money_column)),
```

Publr checks before it runs the hook, so an installed plugin is not started for a list or
a write of another type. A call that names no type (a list of every type, a save by id) is
still heard. A record's `.validate` is about its own type the same way: it runs only on a
write of that type, and once for all the records of a `create_many` or a `save_many`.

An `on` hook waits in the queue with what its own type names of the event. An event may be
of any size; a queued run holds 64 KiB. A hook that takes an operation's whole answer
waits with the whole answer; one declared on a remote with only the fields it reads waits
with those:

```zig
const Placed = publr.remote.operation("orders.place_for", struct {}, struct {
    id: []const u8,
});

publr.on(Placed, send_confirmation),   // waits with { "id": "…" }, whatever the order holds
```

A hook whose share of an event is still over 64 KiB is not run: its run is kept failed at
once, saying so, on the plugin's Log and in `publr job list`, and the server's log has an
error. It is never left out without a word.

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
// discounts: which of a cart's lines a code applies to, for others to change
const decided = try ctx.mod("discounts.applies", Applies{ .code = code, .lines = candidates });

// orders: every charge of a cart through `orders.charge` in one pass: each modifier hears
// them in batches, its reads made together for all
const changed = try ctx.mod_all("orders.charge", ChargeFacts, charges);

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
loaded. A modifier's function takes the value by pointer, typed by its parameter, in its own
words: only the fields it uses. What it writes is laid over the value where it lies, with
no JSON in between ([How values cross](plugins.md#how-values-cross)): the fields it left
out stay; a field only it has is kept beside the value's own, so a later modifier can read
it (the owner never sees it); items of a list that all have a text `id` are matched by it,
so a modifier may drop, reorder or add them, and another list of the same length is laid
over item by item; money is laid over currency by currency. Anything else is replaced,
read as the value's own type. A value that does not read as its type is left as it was,
and so is one for which the function answers an error of its own (`NotFound` for a record
that is gone), and one its answer cannot lie over (it wrote nothing where the value must
hold something, or a number the value's field cannot hold). A modifier that fails any other way (out of its time, its memory or its calls, a
trap, a plugin it called stopped) refuses the whole apply with `ModifierFailed`, and with
it the operation that asked: a value is never used as if every modifier had seen it when
one did not. What the
owner does with the answer is its own: shown, or saved. Core applies every record's title as `<type>.title`
(`publr.Title(Doc)`: `.id`, `.record` typed, `.title` to change). Core applies titles a
list at a time; a modifier is still written for one, and Publr runs it over them in
passes: the first only notes what each reads, then every noted `get` is read in one list and
anything else once per distinct input, and the next pass answers from them, at most 4
rounds. A modifier is pure: no writes, no outside calls. `publr mod list` shows every
modifier, whose it is and why. A `pre` hook is built-in only, registered with
`host.middleware` (see [The server](#the-server)).

A mod runs where its owner applies it, each time. A computed field's mod,
`<record>.<field>`, runs when the value is worked out, and its answer is stored and seen by
everyone ([Computed fields](#computed-fields)). Change a value there when the change
depends on the record and what it reads (a member price from the cart's roles); change it
in a mod the owner applies where it shows the value when it depends on who reads (a price
in the visitor's currency).

A modifier that needs every value at once is written for the batch:

```zig
/// Prices every charge of a cart in one go
fn price_all(ctx: *publr.Ctx, charges: []Charge) publr.Error!void {
    const priced = try ctx.call(Pricing, .{ .charges = charges });   // one call for all

    for (charges, priced.amounts) |*charge, amount| {
        charge.amount = amount;
    }
}

.hooks = &.{ publr.modify_all("orders.charge", price_all) },
```

`publr.modify_all(name, run)` calls `run` once with every value applied (up to 200 a call)
and it changes them where they lie. What it reads or asks another plugin, it reads or asks
once for all of them (`Records.many(ctx, ids)`, one call to an operation that takes a
list), where a modifier written for one value would ask once a value. A value that does
not read as its type never reaches it. Its error refuses the apply. Apply many values in
one call the same way: `ctx.mod_all(name, Value, values)`, never `ctx.mod` in a loop.

Inside a modifier written for one value, `Records.get(ctx, id)` costs one read for the
whole batch: the ids are noted on the first pass and read together, laid out as the
record's own struct.

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

`publr event list` (`--plugin <name>`) lists every declared event, compiled in and installed, with
its payload's fields and kinds; `publr event get --name <event>` adds the hooks on it
([CLI](cli/event.md)).

### Request hooks

`publr.hook.request(run)` sees a page request before the page is drawn. It reads the path,
headers, cookies and the address's query; it may set a header, choose a dimension's value
for the page, redirect (301, 302, 303) or refuse (403, 503). It reads only and never calls
out: a page waits on it. Hooks run in plugin order until one redirects or refuses.

```zig
/// Reads each page in the visitor's variation of the A/B test
fn bucket(ctx: *publr.Ctx, request: *publr.PageRequest) publr.Error!publr.Answered {
    const kept = request.cookie("publr_variation") orelse "control";

    if (!publr.text.equals(kept, "control")) {
        request.choose("variation", kept);
    }

    return request.next();
}

// in define:
.hooks = &.{publr.hook.request(bucket)},
```

A page read in a value a hook chose is drawn live and kept out of shared caches; the built
page stays the main one's. Compiled-in plugins only, for now.

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

- A run is one write, as an operation is: what it changes and the events it emits
  (`ctx.emit`) commit together when it ends well, and roll back together when it fails, so
  a run tried again finds nothing half done. An outside call never waits inside a write:
  before one (`ctx.fetch`, a stream, a download, a mail sent), what the run wrote so far
  commits and a new write starts. `.on_failure` and `.on_conflict` run after the run's
  writes are undone, and what they write is kept. An `on` hook hears what committed: each
  call it makes is a write of its own.
- `ctx.enqueue(Job, in)` queues it to run as soon as the server gets to it;
  `ctx.enqueue_at(Job, in, at)` never before `at`, within about a second after it. Inside a
  write, the job is queued in its transaction: a write rolled back queues nothing.
- The input is kept as JSON, up to 64 KiB: send references, and read the record when the job
  runs, as it is then.
- A run that fails runs again: a minute later, then two, four, up to a day, eight runs in
  all. After the last, `.on_failure` (`fn (*publr.QueueCtx, In, publr.Error) void`)
  hears the error the run ended with (`ctx.failure()` names a declared refusal), and the job is kept as failed. Each failed try is a line on the plugin's Log
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
      .at = .{ .hour = 3 }, // in the site's time zone (`project set_time_zone`), UTC without one
  });
  ```

  Runs missed while the server was down run once, then it keeps its rhythm. List it in
  `.jobs` like any other.
- `publr.QueueCtx` has every call `publr.Ctx` has, and `ctx.fetch`: queued work alone calls
  other servers. Record handles and queries take either. An `on` hook whose `run` takes
  `*publr.QueueCtx` gets one too.
- Installed plugins queue and run jobs as compiled-in ones do; their manifest lists them.
  `publr job list` shows what waits and what failed for good, `on` hooks' runs among them.

## Webhooks

What another server sends: a payment provider saying an order was paid, a courier saying a
parcel moved. Publr takes it at `/_webhooks/<plugin>.<name>`, checks its signature and runs
`run` as queued work.

```zig
/// What the shop's provider sends when a payment goes through.
pub const Paid = struct {
    /// The provider's id for this delivery
    id: []const u8,
    /// The order it pays for
    order: []const u8,
};

fn paid(ctx: *publr.QueueCtx, event: Paid) publr.Error!void {
    ctx.log(.info, "Order {s} paid", .{event.order});
}

/// Payments the provider confirms, at `/_webhooks/shop.paid`.
pub const PaidHook = publr.webhook.define(Paid, .{
    .name = "paid",
    .secret = "SHOP_WEBHOOK_KEY",
    .signature = .{ .timestamped = .{ .header = "Shop-Signature" } },
    .delivery_id = .{ .field = "id" },
    .run = paid,
});

// in define:
.webhooks = &.{PaidHook},
.secrets = struct {
    /// The signing key, under Webhooks in the provider's dashboard
    SHOP_WEBHOOK_KEY: publr.Secret,
},
```

- `.secret` names one of the plugin's `secrets`, the key the sender signs with. Its value
  is set under Settings, then Secrets, or in the environment.
- `.signature` is how the sender signs:
  - `.hmac`: an HMAC-SHA256 of the body in a header, with `.prefix` (`"sha256="`) and
    `.encoding` (`.hex` or `.base64`).
  - `.timestamped`: `t=<seconds>,v1=<hex>` over `<seconds>.<body>`, the way payment
    providers sign. Refused when the time is more than five minutes off.
  - `.token`: the secret itself, in a header.
  - `.verify`: signed in a way only the plugin reads, such as Przelewy24's digest of
    fields in the body. Publr takes the delivery as it comes, and `run` confirms it before
    acting, with any of the plugin's secrets: with `secret.digest` (below), or by asking the sender's API back.
    These deliveries are never dropped as repeats, so `.delivery_id` is not allowed; make
    `run` safe to run twice instead.
- `.body` is `.json` (the default) or `.form`, read as the event's struct. `.raw` hands
  `run` a `publr.webhook.Delivery`: `.body` as it came and `.header(name)`.
- `.delivery_id` says where the sender's own id is, a `.header` or a top-level `.field`.
  A delivery sent again is answered 200 and not run twice.
- Publr answers at once: 200 once the delivery is kept and its run queued, 401 when the
  signature does not verify, 400 when the body does not read, 413 past 256 KiB. A sender
  over the general rate limit gets 429. `run` fails and runs again like any job.
- It is not an operation. It has no caller and no `.authorize`; the signature is its only
  credential.
- The plugin's Webhooks tab in the admin shows the address to give the sender and every
  delivery: when it came, whether it verified, how its run ended and its log lines, with
  Run again. Of the deliveries whose signature did not verify, a webhook keeps the newest
  200: anyone can send those.
- Installed plugins declare webhooks the same way; their manifest lists them.

### Testing on your machine

A sender can only reach an address on the internet. To send deliveries to a site running on
your machine, expose it with a tunnel such as ngrok, and tell Publr the site's address:

```bash
ngrok http 8080
publr serve --port 8080 --url https://<site-tunnel>.ngrok-free.app --admin-url http://admin.localhost:8080
```

Give the sender the address the plugin's Webhooks tab shows,
`https://<site-tunnel>.ngrok-free.app/_webhooks/shop.paid`, and the same signing secret your
site has. Deliveries then show on the tab as they would on a public site. `--url` also puts
the tunnel's address in the sitemap and the language links.

The admin never answers on the site's address: `/admin` there sends you to `--admin-url`,
here the admin on your own machine. To reach the admin from another device too, open a
second tunnel to the same port and name it instead:

```bash
ngrok http 8080   # the site:  https://<site-tunnel>.ngrok-free.app
ngrok http 8080   # the admin: https://<admin-tunnel>.ngrok-free.app
publr serve --port 8080 --url https://<site-tunnel>.ngrok-free.app --admin-url https://<admin-tunnel>.ngrok-free.app
```

Publr tells the two apart by the host each request comes in on, so the tunnel must pass its
own host through, as ngrok does by default.

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
| `users.own` | | | medium |
| `site.read` | | | low |
| `settings.write` | | | high |
| `http.fetch` | `.domains` | | high |
| `mail.send` | | | high |
| `media.read` | | `.private` | low; high with private files |
| `media.write` | | | medium |
| `messaging.send` | | | medium |

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
- `messaging.send` lets a plugin emit message events (`publr.messaging.Email`, `Sms`,
  `Push`) beside its own; without it a message is not sent and the write fails.
- `mail.send` lets a plugin hand an email to an SMTP server it names, from queued work only
  (`publr.operations.mail.Send`, [mail](cli/mail.md)): how a messaging provider reaches a
  site's own mail server.

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
where to find it; at most 32. A plugin with secrets asks for `http.fetch` or `mail.send`. It uses exactly
what it declares: a `{secret:NAME}` its code writes without declaring it fails the build
(`plugin build` and compiled in alike), and one made at run time is refused. At install
each secret's field sits under the first of those requests: optional, fillable later on the
plugin's page, write-only ("Set", or "Set, shared with" the other plugins naming it, and
Replace). Names are site-wide: plugins naming the same one share its value. With no value
a request naming it is refused: "Chat token isn't set". Default limits per call: 100 ms CPU
(`cpu_ms`), 16 MiB memory (`memory_mib`), 1,000 calls (`calls`), 1 MiB output
(`output_kib`); a file it makes, 4 MiB (`file_mib`, never past the 32 MiB a site keeps).
The CPU limit covers everything the call runs in the plugin, calls it makes of its own
operations and hooks included.

One request starts an installed plugin at most once: that instance serves every call into
the plugin the request makes (its operations, its hooks, its modifiers, calls nested in its
own) and is gone when the request ends. A request is one HTTP request, one top-level call
from the CLI or an agent, or one queued run. So nothing a plugin leaves in its module's
memory reaches another request, and nothing may be expected to stay from one call to the
next either: each call's own memory (`ctx.arena()`) is given back when it returns, and a
call that traps, runs out of its budget or fills the plugin's memory drops the instance, so
the next call starts on a fresh one. Keep what must last in records.

Where core fires one hook for many items of one write (a bulk transition's records), the
plugin is entered once and the hook runs for each item in turn, each with memory of its own
and each refused or let through on its own. The hook is written for one item, as always.

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

### Signing with a secret

A gateway's signature is often a hash of text that holds a secret: Przelewy24 signs
`sha384` over a JSON with its CRC key, PayU appends a key to the body. Core makes the hash,
so the plugin never holds the value:

```zig
const signed = try ctx.call(publr.operations.secret.Digest, .{
    .algorithm = .sha384,
    .text = "{\"sessionId\":\"a1b2\",\"amount\":1250,\"crc\":\"{secret:P24_CRC}\"}",
});
// signed.digest: lower-case hex
```

- `.algorithm`: `md5`, `sha1`, `sha256`, `sha384`, `sha512`, or an HMAC (`hmac_sha256`,
  `hmac_sha384`, `hmac_sha512`) keyed with `.key`, which may hold `{secret:NAME}` too.
- `.chain`: steps that each turn the key into the HMAC of the step first, the way AWS
  derives its signing key. The keys made along the way never leave core.
- `.encoding`: `.hex` (the default) or `.base64`.
- `.compare`: a signature the plugin was sent. `matches` says whether it is the digest,
  compared in constant time. Check a webhook's signature this way, never with `==`.

Any of the plugin's code may call it, queued or not. Each secret named must be declared
and set.

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
.depends_on = .{"newsletter@^1.2"},     // exact `1.2.3` or caret `^0.2`
.compatible_with = .{"inventory@^0.3"}, // used only when present
.remotes = &.{ Subscribe, Variants, OutOfStock },
```

A plugin never imports another. Every remote is listed in `.remotes` and checked against
the real thing: when both are compiled in, when the plugin is enabled, and whenever the
other plugin is installed, enabled, updated, disabled or removed. Every listed field must
be there with a fitting kind: an operation's and an event's by their JSON shape (a field
grown since, with a default, needs nothing of the other side: one sent that an older
operation does not know is left out of what it reads, one read that it does not answer takes
its default, with everything inside it; money is `publr.Money`, `{ "PLN": 12300 }`), a record's by field kind (text reads any text kind and a reference's id, a number a number
field, an `X.Ref` a reference, money's JSON map money). An internal record's
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
yes or no, a struct kept as JSON); `.validate` runs on every write; `.text` is how a value
reads in list columns, search and templates; `.icon` is optional. Structure offers the kind
for any type's fields, installed or built in.

`.editor = publr.views.all.LocationEditor` draws the field on the edit form, in the plugin
frame: a view (`PanelPage`) whose `ctx` is `EditorCtx & { value: Location | null }`
(`@publr/admin/Document.ptsx`): `value` (null on a new record), `problems` from a refused
save, `options.placeholder`, and `change(value)`, which hands the value to the form. Without
one the form shows core's control for the value's shape.

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
rules, any group matching), named after the plugin (`<plugin>`, then `<plugin>_1`...). On
another plugin's type (`destination` `content`, `type` its handle) it is a `group` field of
each record's document under that name, published with the record and shown in its form,
never stored on the type. A field whose value is one of the plugin's own struct kinds takes
that kind. `.code_only = true` on `publr.field.kind` keeps a kind out of Structure.

## Roles

```zig
// in define:
.roles = &.{.{
    // A new name is a new role; the name of one there already changes nothing.
    .name = "moderator",
    .label = "Moderator",
}},
```

A role grants nothing by itself: an operation names who may call it
(`.authorize = publr.authorize.user_has_role(&.{"moderator"})`), and administrators grant
the rest in the roles editor.

## User types

```zig
// in define:
.user_types = &.{.{
    // [a-z][a-z0-9_]*, unique on the site; not staff, admin or editor.
    .name = "customer",
    .label = "Customer",
    // The apps (app.zon's `.name`) its people sign in to until an administrator chooses.
    .apps = &.{"shop"},
}},
```

A type of user: people with an account on the site (customers, members, students), on the
one identity system (sign-in, passwords, set-password links, sessions, sign-in providers).
An account holds any number of types, staff accounts included: an administrator may also be
a customer of the shop. An account holding types and no role but the ones they give is
somebody only in the apps one of its types opens, a setting administrators change under
Settings › User types and agents with `user_type set`; staff reach every app their roles
reach. The admin is reached by roles alone. The plugin makes its accounts with
`user.create` and `.user_type = "customer"`, gives its type to an account that has one
(`user.add_type`, with the type's roles) or takes it (`user.remove_type`), and draws its
list itself (`user.list` with `.user_type`): Settings › Users lists staff. Its roles say what
its people may call (`.roles`, above). It asks for `users.own`, not `users.write`:
`user.list` and `user.get` then reach only accounts holding a type it registers;
`user.create`, `user.update` and `user.delete` only accounts wholly its own (its types, and
no role but theirs), never staff or another plugin's, and never give a role its types do not
give; `user.add_type` and `user.remove_type` its own types on any account, staff included,
touching no other role, password or sign-in. With either permission a plugin never gives a
staff role. It hears
a new account with `publr.after(publr.auth.SignedUp, …)` and a sign-in with
`publr.auth.SignedIn`.

```zig
.user_types = &.{.{
    .name = "customer",
    .label = "Customer",
    .apps = &.{"shop"},
    // Visitors make their own account on the shop, holding these roles.
    .sign_up = true,
    .roles = &.{"customer"},
    // The shop's page where a link sets the password (the default).
    .password_page = "/account/password",
}},
.permissions = .{.{ .key = "users.own", .reason = "Makes and changes customers' accounts" }},
```

A type gives visitor roles only: staff and visitors are two ladders. A role is staff when
its grants reach past what visitors call (an operation for untrusted callers or open to
everyone); the grants decide, never the name. A type naming `admin`, `editor` or
`contributor` fails the build and is refused at install; one naming a role that is staff
now is refused at enable (`StaffRoleGiven`), and the roles editor refuses grants that would
make a role a type gives staff (`GivenByType`). Declare the type's role in `.roles` and let
its people call your operations through `.authorize` or `.untrusted_callers`.

Visitors make an account of a type that allows it, and ask for a new password, from the
app's own pages: `POST /api/auth/sign-up` (`{ "app", "user_type", "email", "display_name" }`)
and `POST /api/auth/reset` (`{ "app", "email" }`). Each sends a one-hour link by email
(through the site's messaging provider) to the type's `password_page` on that app, with
`?token=`; the page posts the token and the new password to `/api/auth/set-password`, which
also makes a new account active. Both answer `{ "sent": true }` whether or not an account
exists; an address already signed up gets a new-password link instead. Staff never use them.
A few from one address, or for one email, go through; then each waits longer (a minute,
five, fifteen, sixty), as sign-in does, account or not (`429`). The email is in the
language the body names (`"language": "pl"`, the page's), else the account's own, else the
site's.

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
bridge: the view's `ctx.query("<own read>")`, `ctx.call("<own write>")` and
`ctx.navigate("<own page>?q=1")`. No
network, no session. Compiled in, a page can render the admin's own layouts with
`publr.admin.render.document(arena, publr.admin.chrome.in_plugin_frame(ctx, in.base),
View, props)`, in the person's language.

A page by declaration needs no markup; the admin draws the form:

```zig
const settings: publr.plugin.Page = .{
    .path = "settings",
    .label = "Notes settings",
    .icon = "settings",
    .form = .{ .read = Read, .save = Save },
};

// in define
.pages = &.{settings},
```

`Read` is a read with no input answering the values; `Save` is a write taking every
field. Each field's `///` is its help; an enum is a dropdown, each value named by its `///`
(`/// 1,000`); a list of plain items is a table whose rows are added, removed and
reordered, and its columns only `Read` answers are shown. `.only_one = &.{"main"}` names a
list's boolean columns true in one row only, drawn as a radio; `.blank_in_one = &.{.{ .column =
"address", .says = "The site's own" }}` leaves a column empty and disabled in that row. A new
row starts from each item field's default. `.suggest` (a read, no input, answering items by list) offers items to add, each named by its `name`;
`.preview` (a read taking `Save`'s input, answering as `Read`) keeps the shown columns in
step as people type. Pages, their top bar counts, panels, row actions and
Settings pages may name operations made with `publr.operation.define`.

A page that says `.tabs = true` is a tabbed page the admin draws; a page naming it in
`.parent` (`&.{ "products.settings", "core.system" }`, the first that exists, else System
settings; Users is `core.users`, AI `core.ai`) is one of its tabs: a form, or drawn by its operation in
the frame under the tab bar, with `.action = .{ .label, .href }` in the header.

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

A panel is a read taking `record` and `base`, answering `html` drawn by its view on the
`PanelPage` layout (`publr.views.render`), shown in the plugin frame on every record of the
type; with `.field`, under that field as its help (see [Field help](#field-help)). A row
action is a menu item on the rows of another plugin's list (`.slot`, `.kind` for one kind of
row), shown to whoever may call its operation, `{name}` in its path filled with the row's
name. An installed plugin's actions lead only into the admin (`/admin/...`) through its own
operations. What the plugin's page in the
admin says about it is its `//!` past the first line, through the admin's sanitizer.

### Admin views in PTSX

Views live in `ui/<Name>.ptsx` beside `main.zig`, import `@publr/ui/<Name>.ptsx` and
`@publr/admin/<Name>.ptsx`, and return an admin layout (`IndexPage`, `FormPage`,
`HubPage`, `CardPage`, `ListDetailPage`; `PanelPage` for a panel). A page's read draws one and answers it, the same
either way the plugin runs:

```zig
return .{
    .html = try publr.views.render(ctx, in.base, publr.views.all.AnswersPage, .{
        .rows = rows,
    }),
};
```

Installed, `publr plugin build` lowers the plugin's views itself. A view describes its page
(its own markup and every design-system component it reaches, with its props) and the host
draws the whole page in one call ([Core draws the page](plugins.md#core-draws-the-page)), so
the plugin carries none of the components; what its views do
in the browser (state, clicks, `ctx.query`, `ctx.call`, `ctx.navigate`) travels in the
module and runs in its frame. For now a plugin's own markup takes no classes (style through
the components).
Icons named only at runtime go in `ui/icons.txt`. In the page, `publr/operations` gives
`call("<op>")`, `query("<op>")` and ``query(groq`...`)``; `publr plugin build` writes
`ui/operations.d.ts`.

A page follows what its reads read: while it is on screen, the admin asks every few
seconds whether a record a `ctx.query` read changed elsewhere (a payment arriving on the
order the page shows), and when one did, every read runs again, as the person looking, and
the page draws what they answer, with no reload. Nothing to write: a read through the
plugin's own operations is followed, compiled in or installed.

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

`.extend` is the one way past the plugin API. Publr calls it once, as it is compiled, and
having it makes the plugin built-in only (`publr.zon`, `.plugins.native`): its sandboxed
build leaves it out, and `publr plugin build` says so.

```zig
fn extend(host: *publr.Host) publr.Error!void {
    try host.table(.{
        .name = "notes_seen",
        .schema = @embedFile("tables/seen.sql"),
    });
    try host.route(.{
        .method = .get,
        .path = "/admin/notes",
        .handler = &settings,
    });
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Seen},
    .extend = extend,
});
```

### Routes

`host.route(.{ .method, .path, .handler })`: `.get` or `.post`, under `/admin/<own>`,
`/api/<own>` or `/auth/<own>` (`:id` segments are parameters), a `handler` of `fn
(*publr.http.Request, *publr.http.Response, *publr.http.Context) publr.http.Error!void`, or
a `stream` for a large POST body. At most 16 routes. `publr.admin.require` gives the
signed-in session, `publr.admin.screen` draws an admin page;
`publr.plugin_routes.caller_context` gives an SDK context as whoever sent the request (CSRF
checked on writes); `publr.plugin_routes.set_session` signs someone in.

### Tables

`host.table(.{ .name, .schema })`: one `CREATE TABLE` (with its indexes), named under the
plugin (`<plugin>` or `<plugin>_...`), made when the database opens. Operations read and
write it with `ctx.database()`, inside the call's transaction:
`try ctx.database().exec("INSERT INTO notes_seen (note, at) VALUES (?, ?)", .{ in.note,
ctx.now() })`; `prepare(sql, values)` gives a statement to step through. Prefer records.

### State and the process

`host.state(State)`, a struct with optional `init(state: *State, process:
publr.plugin.Process)` and `deinit`, reached with `publr.plugin_states.of(ctx, @This())`;
`host.bootstrap` (`fn (*sdk.Ctx) sdk.Error!void`, every start, as the system);
`host.before_command` (`fn (*publr.plugin_hooks.Command) anyerror!void`); `host.serving`
(`fn (publr.plugin_hooks.Serving) anyerror!void`); `host.operator_command` (`{ name,
handler }`, answered at `POST /_publr/<plugin>/<name>` with the operator key only).
`Process` is `{ io, gpa, arena, db_path, runtime }`, `Command` `{ io, arena, args, db_path
}`, `Serving` `{ io, arena, project, port }`. Never use a top-level `var`.

### The admin

`host.app_picker_segment` (`fn (*const publr.admin.Session, bool,
?publr.admin.render.Node) publr.admin.Error!?publr.admin.render.Node`), `host.sign_in_at`
(`fn (*const publr.admin.Session) anyerror!?[]const u8`), `host.admin_brand` (whose admin
it is: its name and mark), `host.copies` (see [Plugins](plugins.md#copies-of-a-site)).

### The server

`host.sign_in_provider` (see [Plugins](plugins.md#writing-a-built-in-plugin)),
`host.policy`, `host.delivery_gate` ([Apps](apps.md#delivery-gates)), `host.hosted()` (the
site runs on Publr Cloud). `host.middleware` takes only the two hooks `publr.before/after/on`
don't say: on every operation before it runs (`stage = .pre`) and on every event inside the
write (`stage = .on` with no `event`). An operation whose `run` takes `*sdk.Ctx` has full
access to the host and runs only built-in.

## Contracts and providers

```zig
// payments/method.zig: the contract, owned by `payments`.
pub const Method = publr.contract.define(.{
    .name = "payments.method",
    .operations = .{ .start = Start },
    .optional = .{ .refund = Refund },
});

// bank_transfer/main.zig: one provider of it.
.register_providers = .{.{
    .contract = payments.Method,
    .name = "bank_transfer",
    .label = "Bank transfer",
    .operations = .{ .start = StartTransfer },
}},

// orders: a field naming the provider an order was paid with.
pub const Order = struct {
    /// Paid with
    payment: ?publr.ProviderRef(payments.Method) = null,
};
```

A contract is a named set of parts its providers implement; its owner calls the enabled ones
in the administrator's order (`publr.providers(ctx, Method, .{})`, `chosen.call(ctx,
.start, in)`). `.label` is what people see; the name when left out.

A provider's part takes only the fields it uses: its operation's `In` names any of the
fields the part sends, at the same path, and the others are left out of what it reads
(compiled in and installed alike). Each field it names must be one the part sends, of the
same kind, null only where the provider takes null, its values ones the provider knows; its
`Out` gives every field the part reads that has no default. So a contract grows without
breaking its providers: a field added to a part's `In` is simply not read by a provider
built before it, one added to its `Out` with a default takes that default. A provider is
refused, at build or install, with the field named, only when it truly cannot answer: a
field it names that the part does not send ("is not one the contract sends"), a field of
another kind, or a field read that it does not give.

`publr.ProviderRef(Contract)` is a record field naming one provider of the contract, kept
and sent as its name (`"bank_transfer"`). A write naming no provider registered into the
contract is refused, except a name the record held already: a provider removed later stays
named, and the record form shows it as "bank_transfer (removed)"; the form offers the
contract's providers by label. `ref.provider(ctx)` is the provider while it is registered and
on, null otherwise. The check runs on content and internal records alike. The field's kind
is `provider` (`.options.provider.contract`), which the type builder never offers: only code
puts one on a type.

A contract may ask one required part once per provider, when it is installed and again when
it updates, never per call: `.at_install = .declare` (its `In` takes nothing). Core keeps each
provider's answer, with the version it came from, as the provider's defaults (an item type's
tax facts); the owner reads it with `chosen.answers(ctx)`, administrators with
`provider answers`. A provider whose answer is not kept yet (a compiled-in one before the
first plugin change) is asked then, and nothing is kept. The provider's plugin page in the
admin (Settings › Plugins) shows what it answered, read only.

```zig
pub const Item = publr.contract.define(.{
    .name = "orders.item",
    .at_install = .declare,
    .operations = .{ .declare = Declare, .price = Price },
});
// in orders: what the item type said of itself when installed.
const facts = try chosen.answers(ctx); // Declare.Out
```

A contract's owner shows its providers on its own settings page with the admin's
`ProviderList` view: dragged into order, each switched on or off, each with its settings
(`settings` names the address, `{name}` and `{plugin}` filled in; the provider's plugin page
when left out). The page's plugin must own the contract; the list reads and saves
`provider.list` and `provider.set` as the person looking.

```tsx
import { ProviderList } from "@publr/admin/ProviderList.ptsx";

<ProviderList contract="shipping.method" label={Publr.t("Shipping methods")}
  empty={Publr.t("No shipping method is installed.")}
  settings="/admin/plugin/shipping/shipping?method={name}" ctx={ctx} />
```

A contract whose providers bring a UI (`.component = .optional` on the contract, the
provider's `.component = "LockerMap"`, its `components/LockerMap.publr`) is drawn where the
owner's page leaves a slot for the chosen one. The slot names the contract and the provider
chosen; every other attribute is handed to the component as written. A provider with no
component, or from a plugin the app does not reach, draws nothing:

```astro
<ProviderSlot contract="shipping.method" chosen={cart.shipping} country="PL" />
```

The slot is drawn when the app loads, one branch per provider with a component, in apps
read from the project's folder and apps compiled in alike, and drawn again when plugins
change. An installed plugin carries its `components/` in its module (`publr plugin build`
puts them there), so its component is drawn as a compiled-in one's.

`.with` types what the slot hands over: a struct, one field per attribute.

```zig
pub const Method = publr.contract.define(.{
    .name = "shipping.method",
    .operations = .{ .quote = Quote },
    .component = .optional,
    .with = struct {
        /// The buyer's country
        country: []const u8,
    },
});
```

Every attribute of the slot is a field of `.with`, each required field is given, and a
quoted value is only for a text field; otherwise the app does not load, and `apps load`
says which attribute. A provider's component reading a prop `.with` does not name
(`props.town`) is not drawn, and the log says why.

On the owner's admin pages a provider draws its piece with `.panel`, one of its own reads
taking `record` and `base` and answering `html`, as any panel's:

```zig
.register_providers = .{.{
    .contract = shipping.contracts.method,
    .name = "lockers",
    .operations = .{ .quote = Quote },
    .component = "LockerMap",
    .panel = PickerPanel,
}},
```

A record whose provider field (`publr.ProviderRef`) names the provider shows its panel beside
the record's form, and beside the owner's own page drawing the record (`.record`), in the
provider's frame: the pickup point picker on the order that chose the lockers, and on no
other order. Compiled in or installed alike.

## Model providers

A plugin becomes a model provider by writing its operations for the parts of core's
`ai.model` contract (`describe_provider`, `complete`, and `transcribe` when it turns speech
into text, `read_page` when it reads pages; `publr.ai.completed`, `publr.ai.transcribed`
and `publr.ai.read_page` do their common work) and registering them with
`.register_providers`:
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
references, money, a title modifier, its own icons, menu items) and `site/plugins/waitlist` (an operation untrusted
callers reach).
