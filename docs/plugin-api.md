# Plugin API reference

Every declaration a plugin's `main.zig` can make, the shape it takes, and where it runs.
[Plugins](plugins.md) explains why each exists and how they fit together; this page is the
list. A plugin imports one module, `publr`:

```zig
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;
```

**Runs** says where a declaration works: **both** (compiled in and installed), or
**built-in** (compiled in only; an installed build leaves it out, `publr plugin build`
names it, and a call to a left-out operation answers `Unavailable`).

Everything is checked when the plugin compiles. A missing or misshapen declaration is a
compile error naming the plugin and the declaration.

## Declarations at a glance

| Declaration | Shape | Runs |
|---|---|---|
| `manifest` | `publr.plugin.Manifest` | both, required |
| `namespaces` | `[_]sdk.operation.Namespace` | both |
| `operations` | `[_]type` | both (each must take `*PluginCtx` to run installed) |
| `middleware` | `[_]type` (hooks) | both, except `pre` hooks |
| `content_types` | `[_]publr.plugin.ContentTypeDef` | both |
| `custom_fields` | `[_]publr.plugin.ContentTypeDef` with a `group` | both |
| `internal_records` | `[_]publr.plugin.InternalCollection` | both |
| `roles` | `[_]publr.plugin.Role` | both |
| `permissions` | `[_]publr.plugin.Permission` | both (checked at compile time, enforced installed) |
| `allowed_domains` | `[_][]const u8` | both |
| `limits` | `publr.plugin.Limits` | installed |
| `content_access` | `publr.plugin.ContentAccess` | installed |
| `depends_on`, `compatible_with` | `[_][]const u8` | both |
| `remotes` | `[_]type` of `publr.plugin.Remote(...)` | both |
| `pages` | `[_]publr.plugin.Page` | both |
| `top_bar` | `[_]publr.plugin.Item` (at most 4) | both |
| `sections` | `[_]publr.plugin.Section` | both |
| `row_actions` | `[_]publr.plugin.RowAction` | both |
| `about` | `[]const u8` (HTML) | both |
| `uninstall` | one of its own write operations | both |
| `routes` | `[_]publr.plugin.Route` | built-in |
| `settings_pages` | `[_]publr.plugin.SettingsPage` | built-in |
| `app_picker_segment`, `sign_in_at` | functions | built-in |
| `State` | a struct | built-in |
| `before_command`, `serving` | functions | built-in |
| `operator_commands` | `[_]publr.plugin.OperatorCommand` | built-in |
| `bootstrap` | `fn (*sdk.Ctx) sdk.Error!void` | built-in |
| `schema_sql`, `migrations` | SQL, `[_]publr.db.migration.Migration` | built-in |
| `sign_in_provider` | `publr.plugin.SignInProvider` | built-in |
| `policies`, `statuses`, `transitions`, `field_kinds`, `filters`, `delivery_gates` | see source | built-in |

`rail` is a compile error: the rail belongs to the person.

## Manifest

```zig
pub const manifest: publr.plugin.Manifest = .{
    // [a-z_], at most 32 characters; not a core namespace, not `app`.
    .name = "notes",
    // 1 to 32 characters; raise it to ship a new version.
    .version = "0.1.0",
    // 1 to 200 characters.
    .summary = "Short notes",
};
```

## Namespaces

Every operation's namespace is documented, or the build fails.

```zig
pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "notes",
    .summary = "Short notes",
    .details = "Who calls what, in a few sentences. `publr notes --help` shows it.",
}};
```

A plugin owns two namespaces: `<name>` (for the people running the site) and
`app.<name>` (for an app's visitors). Operations outside them fail the build.

## Operations

An operation is a struct listed in `operations`.

```zig
pub const operations = [_]type{Add};

pub const Add = struct {
    pub const name = "notes.add";
    pub const description = "Keep a note";
    pub const details = "Editors may call it. Fails `Invalid` on an empty note.";
    pub const kind: sdk.operation.Kind = .write;

    pub const In = struct {
        note: []const u8,
    };

    pub const Out = struct {
        id: []const u8,
    };

    pub const example: In = .{
        .note = "hello",
    };

    pub const example_out: Out = .{
        .id = "3f9c1e0a5b7d2c4e6f8a9b0c",
    };

    pub fn run(ctx: *PluginCtx, in: In, grant: *const sdk.Grant) sdk.Error!Out {
        ...
    }
};
```

### Required

| Declaration | Type | Meaning |
|---|---|---|
| `name` | `[]const u8` | `<plugin>.<verb>` or `app.<plugin>.<verb>`, `[a-z_.]`, at most 64 |
| `description` | `[]const u8` | one line |
| `kind` | `sdk.operation.Kind` | `.read` or `.write`; a write runs in a transaction |
| `In`, `Out` | `type` | plain data (see below) |
| `example` | `In` | proves the operation behaves the same in every mode |
| `example_out` | `Out` | what `example` answers |
| `run` | `fn (*PluginCtx, In, *const sdk.Grant) sdk.Error!Out` | the work |

`In` and `Out` are structs of text (`[]const u8`), integers, floats, `bool`, enums,
optionals, slices and nested structs, at most 64 fields and 8 levels deep. No pointers
other than slices, no functions. Defaults make a field optional for the caller.

`run` may take `*sdk.Ctx` instead of `*PluginCtx`. It then has full access to the host and
runs only built-in.

### Optional

| Declaration | Type | Meaning |
|---|---|---|
| `details` | `[]const u8` | who may call it, what it changes, how it fails |
| `field_docs` | `sdk.operation.Docs(In)` | one line per input field |
| `output_docs` | `sdk.operation.Docs(Out)` | one line per output field |
| `rules` | `sdk.operation.Rules(In)` | bounds core checks before `run` (below) |
| `open` | `bool` | anyone may call it, signed in or not |
| `secret` | tuple of field names, `.{"password"}` | masked in the activity log |
| `failures` | `[]const sdk.operation.Failure` | the `ctx.fail` names it may end with, for `--help` |
| `destroys` | `bool` | a write that cannot be undone; devices may not call it |
| `deprecated` | `sdk.operation.Deprecated` | `.{ .since = "0.4.0", .instead = "notes.save" }` |
| `committed` | `fn (*sdk.Ctx, In, Out) sdk.Error!void` | runs after the outermost transaction commits; built-in |

`resource`, `seed`, `volatile_fields` and `example_caller` are gone and fail the build.

### Rules

```zig
pub const rules: sdk.operation.Rules(In) = .{
    .quantity = .{
        .min = 1,
        .max = 20,
    },
    .note = .{
        .min_len = 1,
        .max_len = 280,
    },
    .tags = .{
        .items_max = 10,
    },
    .code = .{
        .preset = .alphanumeric,
    },
};
```

A rule has `min`, `max` (numbers), `min_len`, `max_len` (text), `items_min`, `items_max`
(lists), `preset` (`any`, `digits`, `letters`, `alphanumeric`, `no_spaces`, `lowercase`,
`uppercase`, `phone`) and `pattern` (`*` any, `?` one, `#` digit, `@` letter). A call that
breaks one answers `Invalid`, naming the field, before `run`.

### Taking a record by reference

The caller sends an id; core reads the stored record with the caller's access before `run`.
Unknown, another type's, or not readable answers `NotFound`.

```zig
const Variant = struct {
    name: []const u8,
    stock: i64,
};

pub const In = struct {
    variant: publr.records.Ref(Variant, "variant"),
    quantity: i64,
};
// in run: in.variant.id, in.variant.value.?  (the stored document)
```

### Errors

`sdk.Error` is `Denied`, `Invalid`, `NotFound`, `Conflict`, `Vetoed`, `Throttled`,
`Failed`, `Unavailable`, `BadCredentials`, `InvalidationFailed`, `OutOfMemory` and the
database's errors. A failure of the plugin's own is `ctx.fail` (below). Any error from a
write rolls back the write, its hooks and every call it made.

## The context: `*PluginCtx`

The same methods compiled in (direct calls) and installed (each call a message to the
host).

| Method | Answers |
|---|---|
| `ctx.call(Operation, in)` | `sdk.Error!Operation.Out`: runs any operation through the full pipeline, as the plugin, narrowed to the person it acts for |
| `ctx.fail(name, message)` | `error.Failed`: refuse in its own words; `name` is letters starting upper-case (`NotEnoughStock`), answered with status 409 |
| `ctx.notice(name, subject)` | records a notice event hooks can see (`stage = .on`) |
| `ctx.arena()` | `std.mem.Allocator`, freed when the call ends |
| `ctx.now_ms()` | `i64`, the call's time |
| `ctx.caller()` | `sdk.Caller`: who the call is for |
| `ctx.visitor()` | `[]const u8`: the app visitor's stable id, signed in or not; empty outside an app |
| `ctx.log(line)` | a log line attributed to the plugin |

Core's operations are under `publr.operations.<namespace>` (`record`, `user`, `media`,
`http`, `internal`, `taxonomy`, `term`, `snapshot`, ...). Calling one that none of the
plugin's `permissions` opens fails the build, naming the key to add.

## Records: `publr.records.of`

Typed access to content records.

```zig
const Note = struct {
    note: []const u8,
};

const notes = publr.records.of(Note, "notes_note");
```

| Function | Answers |
|---|---|
| `notes.get(ctx, id)` | `Item`, the live record |
| `notes.find_one(ctx, .field, value)` | `?Item` by a unique field; two make `Conflict` |
| `notes.find(ctx, where, page)` | `[]const Item`, newest first; `where` is `.{}` or one field, `.{ .product = id }`; `page` is `.{ .limit = 50, .offset = 0 }`, limit at most 200 |
| `notes.many(ctx, ids)` | `[]const Item`, unreadable ids left out, no promised order |
| `notes.create(ctx, value, .{ .status = "published" })` | the new id; `status` null starts in the type's first status |
| `notes.save(ctx, id, fields, .{ .expected_version = v, .status = "published" })` | writes only the fields named in `fields` |

`Item` is `{ id, version, status, changed, value: Note }`. Its own types need no
permission, and the calls that name the type (`create`, `find`, `find_one`) reach them
whoever the plugin runs for: a visitor's order, placed through an `app.*` operation, is
the plugin's to write. Other types need `content.read` or `content.write` and the content
access an administrator gave it.

## Internal records: `publr.internal.of`

What only the plugin keeps (carts, holds, ledgers, logs). Declared first:

```zig
pub const internal_records = [_]publr.plugin.InternalCollection{.{
    // The collection's name.
    .kind = "movement",
    // The top-level fields `find` and `find_one` use: text, integers, booleans.
    .indexed = &.{"stock"},
    // Written once, never changed or deleted.
    .append_only = true,
    // True: one collection for the project. False: one per app.
    .shared = false,
}};

const Movement = struct {
    stock: []const u8,
    change: i64,
};

const movements = publr.internal.of(Movement, "movement");
```

`get`, `find_one`, `find` (on an indexed field), `create(ctx, value)`,
`save(ctx, id, fields, ...)` (its new version) and `delete(ctx, id)` (whether it was
there). They reach only the plugin's own records, need no permission, and never show in
the admin's content list.

## Hooks

A hook is a struct listed in `middleware`. Every hook carries a `reason` (shown to the
administrator like a permission) or it does not run installed.

| `stage` | Targets | `run` | Runs |
|---|---|---|---|
| `.before` | `operation = "<name>"` | `fn (*PluginCtx, *Op.In) sdk.Error!void`: may change the input or refuse | both |
| `.after` | `operation = "<name>"` | `fn (*PluginCtx, *Op.In, *const Op.Out) sdk.Error!void`: may refuse, which rolls back | both |
| `.on` | `event = "<operation or notice name>"` | `fn (*PluginCtx, sdk.middleware.Event) void`: sees, cannot refuse | both |
| `.display` | `point = "record.title"`, `content_type = "<handle>"` | `fn (*PluginCtx, *sdk.display_hooks.Batch) sdk.Error!void` | both |
| `.pre` | every call | `fn (*sdk.Ctx, []const u8) sdk.Error!void` | built-in |

```zig
pub const middleware = [_]type{Shout};

pub const Shout = struct {
    pub const stage: sdk.middleware.Stage = .before;
    pub const operation = "notes.add";
    pub const reason = "Keeps every note in capitals";

    pub fn run(ctx: *PluginCtx, in: *Add.In) sdk.Error!void {
        const upper = ctx.arena().alloc(u8, in.note.len) catch return error.OutOfMemory;

        in.note = std.ascii.upperString(upper, in.note);
    }
};
```

An event is `.completed`, `.rejected`, `.failed` or `.notice` (`{ operation_id, name,
subject }`).

Hooks are intrinsic or extrinsic. Intrinsic hooks are part of the write: `.before` and
`.after`, and an `.on` hook that declares `pub const intrinsic = true`. They run inside the
write's transaction, so what they keep commits or rolls back with it. Everything else an
`.on` hook does is a side effect, so it is extrinsic: it hears an operation's end as it
happens, but a notice only once the write has committed, from a queue the server works
through between requests, with the system as caller. An installed plugin's event hooks are
always extrinsic.

A write over many records (`record transition_many`) does the write once for all of them,
but each record is still heard on its own: `.before` and `.after` hooks on `record
transition` run for every record, and one that refuses keeps only that record back. An
intrinsic hook may declare a set form, called once with the whole part instead of once per
item: `run_many(*sdk.Ctx, []const Op.In, refused: []?[]const u8) sdk.Error!void` for
`.before` (setting a reason refuses that item), the same with `[]const Op.Out` after the
inputs for `.after`, and `run_many(*sdk.Ctx, []const sdk.middleware.Event.Notice) void` for
an intrinsic `.on`. A display batch holds up to 200 items, each `{ id, value, fields }`: the hook
rewrites `value` (at most 512 bytes) and cannot write anything. A hook may target another
plugin's operation only through a `Remote` it declares.

## Content types

```zig
pub const content_types = [_]publr.plugin.ContentTypeDef{.{
    .handle = "notes_note",
    .name = "Note",
    .title_field = "note",
    // True: apps' built pages may read its live records.
    .public = false,
    // .record, .settings (one record; the admin draws its page) or .component.
    .kind = .record,
    .fields = &.{
        .{
            .name = "note",
            .label = "Note",
            .kind = "string",
            .required = true,
        },
        .{
            .name = "slug",
            .label = "Slug",
            .kind = "slug",
            .options = .{
                .source = "note",
            },
        },
        .{
            .name = "author",
            .label = "Author",
            .kind = "reference",
            .options = .{
                .to = &.{"person"},
                .reference = .{
                    .on_delete = .keep,
                },
            },
        },
    },
}};
```

Other type fields: `description`, `icon`, `url` (records get pages at `/<url>/<slug>`),
`statuses`, `editor`, `group`. A field has `name`, `label`, `kind`, and optionally
`required`, `unique`, `searchable`, `many`, `help`, `default`, `conditions`, `options`
and `fields` (for groups and repeaters). Declared fields are locked in the admin; fields
an editor adds survive the next redeclaration. At most 64 types per plugin.

Field kinds: `string`, `text`, `richtext`, `slug`, `email`, `url`, `password`, `integer`,
`number`, `boolean`, `select`, `datetime`, `time`, `money`, `color`, `media`, `reference`,
`user`, `terms`, `link`, `embed`, `location`, `group`, `repeater`, `accordion`, `tab`,
`message`, `virtual`. Options per kind are in `src/model/field/options.zig`.

`custom_fields` takes the same shape plus a location, and puts fields on accounts or media:

```zig
.group = .{
    .location = &.{
        .{
            .rules = &.{
                .{
                    .field = "destination",
                    .value = "user",
                },
            },
        },
    },
},
```

## Roles

```zig
pub const roles = [_]publr.plugin.Role{.{
    // An existing role gains these grants; a new name is a new role.
    .name = "editor",
    .label = "Editor",
    // Operations, or a namespace ending in `.*`.
    .grants = &.{"notes.*"},
}};
```

Installed, a role grants only the plugin's own operations.

## Permissions, domains, limits, content access

Anything beyond its own types and operations is asked for, each with a reason.

```zig
pub const permissions = [_]publr.plugin.Permission{
    .{
        .key = "content.read",
        .reason = "Lists posts on the notes page",
    },
    .{
        .key = "http.fetch",
        .reason = "Sends notes to the team chat",
    },
    .{
        .key = "secret.CHAT_TOKEN",
        .reason = "Signs the chat requests",
    },
};

pub const allowed_domains = [_][]const u8{"chat.example.com"};

pub const limits: publr.plugin.Limits = .{
    .memory_mib = 64,
    .reason = "Holds images",
};

pub const content_access: publr.plugin.ContentAccess = .{
    .recommend = .all,
    .note = "Indexes every type",
};
```

| Tier | Keys | On enabling |
|---|---|---|
| low | `content.read`, `taxonomy.read`, `schema.read`, `version.read`, `site.config`, `users.names`, `ai.progress` | granted |
| medium | `content.drafts`, `content.write`, `taxonomy.write`, `release.manage`, `schema.write`, `settings.own` | granted, listed |
| high | `content.purge`, `users.read`, `users.write`, `settings.global`, `http.fetch`, `secret.<NAME>`, any raised limit | waits for an administrator |

At most 64 permissions and 32 domains; a reason is at most 200 characters. `publr agents`
ends with every key and the operations it opens. A revoked permission makes the next call
answer `Denied`.

Default limits per call: 100 ms CPU (`cpu_ms`), 16 MiB memory (`memory_mib`), 1,000 calls
(`calls`), 1 MiB output (`output_kib`). `content_access.recommend` is `.public` (default),
`.all` or `.specific`.

### Calling out

With `http.fetch` granted:

```zig
const answer = try ctx.call(publr.operations.http.Fetch, .{
    .method = "POST",
    .url = "https://chat.example.com/send?token={secret:CHAT_TOKEN}",
    .headers = &.{},
    .body = body,
});
// answer.status, answer.body
```

Only https to `allowed_domains` (or a subdomain), or plain http to this machine. A secret
is written as `{secret:NAME}` and filled in as the request leaves; the plugin never holds
the value. Do not call out from a write: nothing undoes it on rollback.

## Building on other plugins

```zig
// Exact `1.2.3` or caret `^0.2`.
pub const depends_on = [_][]const u8{"newsletter@^1.2"};

// Used only when present.
pub const compatible_with = [_][]const u8{"analytics@^0.3"};

pub const remotes = [_]type{Subscribe};

pub const Subscribe = publr.plugin.Remote(
    "newsletter.subscribe",
    // What this plugin sends.
    struct {
        email: []const u8,
    },
    // The part of the answer it reads.
    struct {
        subscribed: bool,
    },
);

// Called like any operation, or hooked with `operation = Subscribe.name`.
const answer = try ctx.call(Subscribe, .{
    .email = email,
});
```

A plugin never imports another plugin. A remote shape that does not fit the real one is a
compile error when both are compiled in, and refused when either is installed.

## Admin entries

### Pages in the plugin frame

```zig
pub const pages = [_]publr.plugin.Page{.{
    // Lowercase letters, digits, dashes; at /admin/plugin/<plugin>/log.
    .path = "log",
    .label = "Notes log",
    .icon = "stack",
    // A read: `In` has `query` and `base`, `Out` has `html`, all `[]const u8`.
    .operation = Page,
}};
```

The answered `html` runs in a sandboxed `<iframe>` with the admin's stylesheet and a
bridge: `publr.call("<own operation>", input)` and `publr.navigate("<own page>?q=1")`. No
network, no session. Compiled in, a page can render the admin's own layouts with
`publr.admin.render.document(arena, publr.admin.chrome.in_plugin_frame(ctx, in.base),
View, props)`, in the person's language.

A page by declaration needs no markup; the admin draws the form:

```zig
pub const pages = [_]publr.plugin.Page{.{
    .path = "settings",
    .label = "Notes settings",
    .icon = "gear",
    .form = .{
        .read = Read,
        .save = Save,
        .multiline = &.{"description"},
    },
}};
```

`Read` is a read with no input answering the values; `Save` is a write taking every
field. Each field's `field_docs` line is its help.

### Top bar, sections, row actions, about

```zig
pub const top_bar = [_]publr.plugin.Item{.{
    .label = "Notes",
    .icon = "file",
    // One of its pages, or `.href = "/admin/..."`.
    .page = "log",
    // Shown to whoever may call it.
    .operation = Logs,
    // Optional: a read with no input answering `count: i64`.
    .count = Count,
}};

pub const sections = [_]publr.plugin.Section{.{
    .label = "Shop",
    .icon = "folder",
    // Its own types, at most 8; at most 4 columns each.
    .types = &.{
        .{
            .handle = "product",
            .columns = &.{ "price", "stock" },
        },
        .{
            .handle = "order",
        },
    },
}};

pub const row_actions = [_]publr.plugin.RowAction{.{
    // The page as its owner names it.
    .slot = "orders",
    .label = "Print slip",
    .path = "/admin/plugin/slips/print?order={name}",
    // Only rows of this kind; every row when empty.
    .kind = "",
    .operation = Print,
}};

pub const about =
    \\<p>What this plugin does.</p>
;
```

Columns show `string`, `text`, `email`, `url`, `slug`, `select`, `integer`, `number`,
`boolean`, `datetime`, `money` and `color` fields. `about` passes the admin's sanitizer:
classes only `muted`, `success`, `warning`, `error`; scripts and styles dropped.

### Admin views in PTSX

Views live in `ui/<Name>.ptsx` beside `main.zig`, import `@publr/ui/<Name>.ptsx` and
`@publr/admin/<Name>.ptsx`, and return an admin layout (`IndexPage`, `FormPage`,
`HubPage`, `CardPage`, `ListDetailPage`). Compiled in they are `publr.admin.views.<Name>`.
Icons named only at runtime go in `ui/icons.txt`. In the page, `publr/operations` gives
`call("<op>")`, `query("<op>")` and ``query(groq`...`)``; `publr plugin build` writes
`ui/operations.d.ts`.

## Removal

```zig
// One of its own writes; its `In` has `remove: []const []const u8`.
pub const uninstall = Forget;
```

Runs when an administrator removes the plugin with some of its data. `remove` lists the
pieces: `type:<handle>`, `internal:<collection>`, `fields:<group>`. If it fails, nothing
is removed.

## Built-in only

These run only when the plugin is compiled in (`publr.zon`, `.plugins.native`).

### Routes

```zig
pub const routes = [_]publr.plugin.Route{.{
    // .get or .post.
    .method = .get,
    // Under /admin/<own>, /api/<own> or /auth/<own>; `:id` segments are parameters.
    .path = "/admin/notes",
    .handler = &settings,
}};

fn settings(
    request: *publr.http.Request,
    response: *publr.http.Response,
    ctx: *publr.http.Context,
) publr.http.Error!void {
    var session = try publr.admin.require(request, response, ctx) orelse return;
    ...
    try publr.admin.screen(&session, .ok, publr.admin.views.NotesSettings, props);
}
```

At most 16 routes. `publr.plugin_routes.caller_context` gives an SDK context as whoever
sent the request (CSRF checked on writes); `publr.plugin_routes.set_session` signs
someone in.

### Admin hooks

```zig
pub const settings_pages = [_]publr.plugin.SettingsPage{.{
    .label = "Notes",
    .icon = "stack",
    .path = "/admin/notes",
    .operation = Logs,
}};

pub fn app_picker_segment(
    session: *const publr.admin.Session,
    attached: bool,
    apps: ?publr.admin.render.Node,
) publr.admin.Error!?publr.admin.render.Node {
    ...
}

pub fn sign_in_at(session: *const publr.admin.Session) anyerror!?[]const u8 {
    ...
}
```

### State and the process

```zig
pub const State = struct {
    port: u16 = 0,

    pub fn init(state: *State, process: publr.plugin.Process) anyerror!void {
        ...
    }

    // Optional.
    pub fn deinit(state: *State) void {
        ...
    }
};
// publr.plugin_states.of(ctx, @This()), or .from(project.plugin_states.?, @This())

pub fn before_command(command: *publr.plugin_hooks.Command) anyerror!void {
    ...
}

pub fn serving(serve: publr.plugin_hooks.Serving) anyerror!void {
    ...
}

// POST /_publr/<plugin>/ping, with the operator key only.
pub const operator_commands = [_]publr.plugin.OperatorCommand{
    .{
        .name = "ping",
        .handler = &ping,
    },
};
```

`Process` is `{ io, gpa, arena, db_path, runtime }`. `Command` is `{ io, arena, args,
db_path }`. `Serving` is `{ io, arena, project, port }`. Never use a top-level `var`.

### Database

```zig
// Every start, as the system.
pub fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void {
    ...
}

pub const schema_sql = "CREATE TABLE IF NOT EXISTS ...";

pub const migrations = [_]publr.db.migration.Migration{
    ...
};
```

Prefer content types and internal records; a table of its own makes the plugin
built-in only.

### Other built-in declarations

`sign_in_provider` (see [Plugins](plugins.md#writing-a-built-in-plugin)), `policies`,
`statuses`, `transitions`, `field_kinds`, `filters` and `delivery_gates`
([Apps](apps.md#delivery-gates)). Their shapes are in `src/sdk/plugin.zig` and the
`src/model/` file each names.

## Model providers

A plugin becomes a model provider by listing two operations built by `publr.ai`:
`publr.ai.Describe("<name>", .{...})` and `publr.ai.Complete("<name>", complete)`. See
[Plugins](plugins.md#model-providers).

## Building

```sh
publr plugin build --name notes        # plugins/notes/main.zig, for the sandbox
publr --as-admin plugin get --name notes
publr notes --help
```

Built-in: list it in `publr.zon` and run `zig build`. A worked example of nearly every
declaration that runs both ways is `src/server/sandboxed_plugins/testdata/sampler/main.zig`.
