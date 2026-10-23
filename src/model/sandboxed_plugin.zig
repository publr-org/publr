//! An installed plugin as data: its manifest (what the build wrote into the module), what it
//! asks an administrator for, and what installing or updating it grants. Nothing here runs a
//! plugin; the sandbox does.
const std = @import("std");
const permission = @import("permission.zig");
const content_type = @import("content_type.zig");
const role = @import("role.zig");
const internal_record = @import("internal_record.zig");
const contract = @import("contract.zig");
const plugin_contracts = @import("plugin_contracts.zig");
const flow = @import("flow.zig");
const status = @import("status.zig");

pub const name_len_max: u32 = 32;
pub const version_len_max: u32 = 32;
pub const reason_len_max: u32 = 200;
pub const requests_max: u32 = 128;
/// How many plugins, plugins and apps together, one project holds.
pub const sandboxed_plugins_max: u32 = 500;
/// The largest module a plugin ships.
pub const bytes_max: u32 = 16 << 20;
/// Bumped when the manifest's shape changes; a host refuses a format it does not know.
pub const format: u32 = 1;

pub const Kind = enum { read, write };

pub const Namespace = struct {
    name: []const u8,
    summary: []const u8,
    details: []const u8,
};

/// A permission a plugin asks for, by the key the administrator sees, with its own reason,
/// the content types or taxonomies it names and its flags.
pub const Ask = struct {
    key: []const u8,
    reason: []const u8,
    records: []const []const u8 = &.{},
    taxonomies: []const []const u8 = &.{},
    /// `http.fetch`'s: where it may send.
    domains: []const []const u8 = &.{},
    drafts: bool = false,
    private: bool = false,
    internal: bool = false,
    publish: bool = false,

    /// The grant it asks for.
    pub fn held(ask: *const Ask) permission.Held {
        std.debug.assert(ask.key.len > 0);
        std.debug.assert(ask.records.len <= names_max and ask.taxonomies.len <= names_max);

        return .{
            .key = ask.key,
            .records = ask.records,
            .taxonomies = ask.taxonomies,
            .domains = ask.domains,
            .drafts = ask.drafts,
            .private = ask.private,
            .internal = ask.internal,
            .publish = ask.publish,
        };
    }
};

pub const Secret = @import("secrets.zig").Declared;

/// How many content types or taxonomies one request may name.
pub const names_max: u32 = 64;

/// More than the defaults, asked for with a reason; each raised limit waits for approval.
pub const Limits = struct {
    cpu_ms: ?u32 = null,
    memory_mib: ?u32 = null,
    calls: ?u32 = null,
    output_kib: ?u32 = null,
    reason: []const u8 = "",
};

pub const Manifest = struct {
    format: u32 = format,
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    namespaces: []const Namespace = &.{},
    operations: []const Operation = &.{},
    hooks: []const Hook = &.{},
    /// Its queued jobs; each one's entry follows the hooks', in this order.
    jobs: []const Job = &.{},
    /// What other servers send it (`.webhooks`): each one's delivery runs as its job
    /// `webhook_<name>`.
    webhooks: []const Webhook = &.{},
    /// Its location rules (`.register_location_rules`); each one's `values` and `matches`
    /// entries follow the jobs', in this order.
    location_rules: []const LocationRule = &.{},
    /// Its field kinds (`.field_kinds`); each one's `validate` and `text` entries follow the
    /// rules', in this order.
    field_kinds: []const FieldKind = &.{},
    permissions: []const Ask = &.{},
    /// The secrets it declares (`.secrets`): not permissions, filled in by an administrator.
    secrets: []const Secret = &.{},
    depends_on: []const []const u8 = &.{},
    limits: Limits = .{},
    content_types: []const content_type.Def = &.{},
    custom_fields: []const content_type.Def = &.{},
    roles: []const role.Declared = &.{},
    /// The statuses it adds to other plugins' flows (`.register_statuses`), each a request.
    statuses: []const flow.Added = &.{},
    internal_records: []const internal_record.Collection = &.{},
    /// What it uses of other plugins (`.remotes`): operations, records and events.
    remotes: []const RemoteUse = &.{},
    /// The events it declares (`.events`), by full name, with their payloads' shapes.
    events: []const Event = &.{},
    compatible_with: []const []const u8 = &.{},
    /// The providers it registers into contracts.
    providers: []const @import("provider.zig").Registered = &.{},
    pages: []const Page = &.{},
    menu: []const MenuEntry = &.{},
    icons: []const PluginIcon = &.{},
    panels: []const Panel = &.{},
    columns: []const Column = &.{},
    top_bar: []const Item = &.{},
    row_actions: []const RowAction = &.{},
    /// What the plugin says about itself on its page in the admin: its `main.zig`'s `//!`
    /// past the first line, shown through the admin's sanitizer in a box the admin draws.
    about: []const u8 = "",
    /// What the plugin brings that its sandboxed build left out, each with why.
    left_out: []const []const u8 = &.{},
};

/// An operation a plugin brings; its entry in the module is its position here.
pub const Operation = struct {
    name: []const u8,
    kind: Kind,
    description: []const u8,
    details: []const u8 = "",
    open: bool = false,
    /// Listed in the published API reference (`.public_api`).
    public_api: bool = false,
    /// Made with `publr.operation.define`: whether callers without credentials may call it.
    /// Null for an operation declared part by part.
    untrusted_callers: ?bool = null,
    /// Its ready answer to who may call, checked by the host before it runs.
    answer: ?@import("caller_answer.zig").Answer = null,
    /// Its own rate limit (`.limit`), calls a minute per caller; 0 for none.
    limit: u32 = 0,
    /// It destroys what cannot be had back (`.destructive`): only then may the core
    /// operations it calls destroy, and a device never runs it.
    destructive: bool = false,
    fields: []const Field = &.{},
    /// Its `--help`, rendered by the build as a compiled-in operation's is.
    help: []const u8 = "",
    /// Its `Example:` as JSON, `in:` and `out:`: what the plugin's build runs.
    example: []const u8 = "",
    example_out: []const u8 = "",
    /// The shapes it takes and answers: its published contract.
    input: []const contract.Node = &.{},
    output: []const contract.Node = &.{},
    /// Input fields never written to the logs.
    secret: []const []const u8 = &.{},
    /// What its `.validate` checks, in its words; empty for none.
    checked: []const u8 = "",
    /// Who may call it, as its code says it.
    who_may_call: []const u8 = "",
    /// What every caller is told when it is on its way out: since when, and what to call
    /// instead. Empty for an operation that is not.
    deprecated: []const u8 = "",
};

/// Another plugin's operation, record or event as this plugin uses it.
pub const RemoteUse = plugin_contracts.Used;

/// An event the plugin declares, as other plugins are checked against it.
pub const Event = plugin_contracts.ProvidedEvent;

/// The plugin as a user of others' operations.
pub fn contract_user(manifest: *const Manifest) plugin_contracts.User {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.remotes.len <= plugin_contracts.findings_max);

    return .{
        .plugin = manifest.name,
        .depends_on = manifest.depends_on,
        .compatible_with = manifest.compatible_with,
        .remotes = manifest.remotes,
    };
}

/// The plugin as a provider of its operations' shapes.
pub fn contract_provider(
    arena: std.mem.Allocator,
    manifest: *const Manifest,
) error{OutOfMemory}!plugin_contracts.Provider {
    std.debug.assert(manifest.name.len > 0);

    const operations = try arena.alloc(plugin_contracts.Provided, manifest.operations.len);

    for (manifest.operations, operations) |operation, *provided| {
        provided.* = .{
            .name = operation.name,
            .input = operation.input,
            .output = operation.output,
        };
    }

    const types = manifest.content_types;
    const internal = manifest.internal_records;
    const records = try arena.alloc(plugin_contracts.ProvidedRecord, types.len + internal.len);

    for (types, records[0..types.len]) |def, *record| {
        const fields = try arena.alloc(plugin_contracts.ProvidedField, def.fields.len);

        for (def.fields, fields) |field, *provided| {
            provided.* = .{
                .name = field.name,
                .kind = field.kind,
                .many = field.many,
            };
        }

        record.* = .{
            .name = def.handle,
            .fields = fields,
        };
    }

    for (internal, records[types.len..]) |collection, *record| {
        record.* = .{
            .name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ manifest.name, collection.kind }),
            .fields = collection.fields,
        };
    }

    return .{
        .plugin = manifest.name,
        .version = manifest.version,
        .operations = operations,
        .records = records,
        .events = manifest.events,
    };
}

pub const Field = struct {
    name: []const u8,
    shape: Shape,
    required: bool,
    doc: []const u8 = "",
    /// What a value looks like (`integer`, `calm|loud`, `list of text`), as errors say it.
    label: []const u8 = "",
    /// The names a value may be, when it is one of a set.
    values: []const []const u8 = &.{},
    /// Each value's words, the first line of its `///` (`1,000`), in step with `values`;
    /// empty where it has none.
    words: []const []const u8 = &.{},
    /// A list of items' fields, each plain (`json`, a list of `{ code, label }`).
    fields: []const Field = &.{},
    /// An item field's value when a new item is added (`{symbol}{amount}`), as text.
    default: []const u8 = "",

    pub const Shape = enum { string, integer, number, boolean, strings, json };
};

/// A column a declared form's list leaves empty in the row an `only_one` column picks (the
/// main language's address), and what its field says there instead (`The site's own`).
pub const Blank = struct {
    column: []const u8,
    says: []const u8,
};

/// A page of the plugin's own: drawn by its read `operation` in the plugin frame, or, by
/// declaration, a form the admin draws from `save`'s input filled from `read`.
pub const Page = struct {
    path: []const u8,
    label: []const u8,
    icon: []const u8,
    operation: []const u8 = "",
    read: []const u8 = "",
    save: []const u8 = "",
    /// A list's boolean columns true in one row only.
    only_one: []const []const u8 = &.{},
    /// Columns the row an `only_one` column picks leaves empty.
    blank_in_one: []const Blank = &.{},
    /// A form's read offering items to add to its lists, and its read previewing a save.
    suggest: []const u8 = "",
    preview: []const u8 = "",
    /// `.menu = .none`: left out of the menu, still opened at its address.
    hidden: bool = false,
    /// A tabbed page, filled by other pages naming it in `parent`.
    tabs: bool = false,
    /// The tabbed pages this page is a tab of, the first that exists (`products.settings`).
    parent: []const []const u8 = &.{},
    /// A tab's primary action in its tabbed page's header: its label and admin address.
    action_label: []const u8 = "",
    action_href: []const u8 = "",
};

/// An entry in the top bar: to one of the plugin's pages or an admin
/// address, shown to whoever may call `operation`, `count` (a read) beside the label.
pub const Item = struct {
    label: []const u8,
    icon: []const u8,
    page: []const u8,
    operation: []const u8,
    count: []const u8 = "",
};

/// A box on a content type's edit form, drawn in the plugin frame by `operation`, one of
/// the plugin's reads, told the record's id.
pub const Panel = struct {
    type: []const u8,
    label: []const u8,
    operation: []const u8,
};

/// A column on a list the plugin doesn't own (`.register_columns`): the field is its own,
/// stored on the type or added to each row by an `after` hook on the list's read.
/// A field kind of the plugin's own, named under it (`sampler.place`): what core keeps of it,
/// and whether it runs a `.validate` and a `.text` in the sandbox.
pub const FieldKind = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    icon: []const u8,
    storage: kinds.Storage,
    control: kinds.Control,
    validates: bool,
    texts: bool,
};

const kinds = @import("kinds.zig");

/// A location rule of the plugin's own, named under it when placed (`sampler.has_motto`).
pub const LocationRule = struct {
    name: []const u8,
    label: []const u8,
};

pub const Column = struct {
    /// A type's list (`orders.order`), `users`, `media`, or a pattern (`orders.*`).
    list: []const u8,
    /// The row's field, under the plugin's name: `loyalty.points`.
    field: []const u8,
    label: []const u8,
    kind: ColumnKind,
    /// A field the plugin stores on the type: read with the list, and the list sorts on it.
    stored: bool = false,
};

/// How a column's cells are drawn.
pub const ColumnKind = enum { number, money, date, text, status, link };

/// An icon a plugin brings, named `<plugin>.<name>`: a 24×24 drawing, sanitized as any SVG
/// before a page shows it.
pub const PluginIcon = struct {
    name: []const u8,
    svg: []const u8,
};

pub const plugin_icons_max: u32 = 16;
pub const plugin_icon_bytes_max: u32 = 4096;

/// Whether `name` may be an icon's: letters, digits, `_`, `-`, one `.` after the plugin.
pub fn icon_name_valid(name: []const u8) bool {
    std.debug.assert(plugin_icon_bytes_max > 0);

    if (name.len == 0 or name.len > 64) {
        return false;
    }

    var dots: u32 = 0;

    for (name) |char| {
        const word = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_' or
            char == '-';

        dots += @intFromBool(char == '.');

        if (!word and char != '.') {
            return false;
        }
    }

    return dots == 1 and name[0] != '.' and name[name.len - 1] != '.';
}

/// A menu item a plugin brings, as `publr.MenuItem` declares it: under the first of
/// `parents` that exists, else on its own; it opens one of the plugin's record types' lists,
/// one of its pages, or nothing (a heading).
pub const MenuEntry = struct {
    /// `<plugin>.<name>`: what records and other items name to sit under it.
    name: []const u8,
    label: []const u8,
    icon: []const u8,
    /// A record type's handle; empty for none.
    record: []const u8 = "",
    /// One of the plugin's pages, by path; empty for none.
    page: []const u8 = "",
    parents: []const []const u8 = &.{},
};

/// An action on the rows of another plugin's page, as `publr.plugin.RowAction` declares it.
pub const RowAction = struct {
    slot: []const u8,
    label: []const u8,
    path: []const u8,
    kind: []const u8 = "",
    operation: []const u8,
};

/// A job a plugin queues: its name under the plugin, and when a repeating one runs (`every`
/// `day`, `hour` or `minutes`, empty for one queued by code).
pub const Job = struct {
    name: []const u8,
    every: []const u8 = "",
    minutes: u32 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    /// The record's datetime field it follows (`.due`); null for one queued or repeating.
    due: ?Due = null,
};

/// A plugin's webhook, at `/_webhooks/<plugin>.<name>`.
pub const Webhook = struct {
    name: []const u8,
    /// The secret it is signed with, by name.
    secret: []const u8,
    signature: Signature,
    body: Body = .json,
    delivery_id: ?DeliveryId = null,
};

/// How a webhook's sender signs.
pub const Signature = union(enum) {
    /// An HMAC-SHA256 of the body in a header (`X-Hub-Signature-256: sha256=<hex>`).
    hmac: struct {
        header: []const u8,
        prefix: []const u8 = "",
        encoding: Encoding = .hex,
    },
    /// The timestamped HMAC payment providers send: `t=<seconds>,v1=<hex>` over
    /// `<seconds>.<body>`, refused when the time is over five minutes off.
    timestamped: struct {
        header: []const u8,
    },
    /// The secret itself, in a header.
    token: struct {
        header: []const u8,
    },
};

pub const Encoding = enum { hex, base64 };

/// How a webhook's body is read: JSON, a form, or the bytes as they came.
pub const Body = enum { json, form, raw };

/// Where a delivery's own id is, so a repeat is dropped: a header, or a top-level field.
pub const DeliveryId = union(enum) {
    header: []const u8,
    field: []const u8,
};

/// A record's datetime field a job follows: it runs once per value, `offset_ms` from it.
pub const Due = struct {
    /// The record's type, by its full name.
    type: []const u8,
    field: []const u8,
    /// Negative for `.before`.
    offset_ms: i64,
};

/// A hook a plugin asks for; its entry is the number of operations plus its position here.
pub const Hook = struct {
    stage: Stage,
    /// The operation a `before` or `after` hook runs on, the event an event hook sees, or
    /// the name a modifier takes (`variant.title`, `*.title`).
    target: []const u8,
    reason: []const u8,

    pub const Stage = enum { before, after, event, modify };
};

/// The defaults every call into a plugin runs within.
pub const limits_default: Effective = .{
    .cpu_ms = 100,
    .memory_mib = 16,
    .calls = 1000,
    .output_kib = 1024,
};

pub const Effective = struct {
    cpu_ms: u32,
    memory_mib: u32,
    calls: u32,
    output_kib: u32,
};

pub const limit_keys = [_][]const u8{
    "limit.cpu_ms",
    "limit.memory_mib",
    "limit.calls",
    "limit.output_kib",
};

/// One thing an administrator sees on the install page and grants or revokes on the
/// plugin's page: a catalog permission, a hook or a raised limit.
pub const Request = struct {
    key: []const u8,
    sentence: []const u8,
    reason: []const u8,
    tier: permission.Tier,
    /// False when nothing installed provides the key: the plugin runs without it.
    available: bool = true,
    /// For a catalog permission: the grant as asked, its flags and what it names.
    asked: ?permission.Held = null,
};

/// Everything the manifest asks for, each with its tier, in the manifest's order: catalog
/// permissions, then hooks, then raised limits. `hook_keys` holds the keys
/// written for hooks (`after:record.save`), which the requests point into.
pub fn requests(
    manifest: *const Manifest,
    arena: std.mem.Allocator,
) error{ OutOfMemory, Invalid }![]const Request {
    std.debug.assert(manifest.name.len > 0);

    var list: std.ArrayList(Request) = .empty;

    for (manifest.permissions) |ask| {
        const found = permission.find(ask.key);
        const asked = ask.held();
        const tier = if (found) |entry|
            permission.tier_of_held(entry, &asked)
        else
            permission.tier_of(ask.key);

        try list.append(arena, .{
            .key = ask.key,
            .sentence = if (found) |entry| entry.sentence else ask.key,
            .reason = ask.reason,
            .tier = tier orelse .high,
            .available = tier != null,
            .asked = if (found != null) asked else null,
        });
    }

    for (manifest.hooks) |hook| {
        const key = try hook_key(arena, hook);

        try list.append(arena, .{
            .key = key,
            .sentence = try hook_sentence(arena, hook),
            .reason = hook.reason,
            .tier = switch (hook.stage) {
                .event, .after => .low,
                .before, .modify => .medium,
            },
        });
    }

    for (manifest.statuses) |added| {
        try list.append(arena, .{
            .key = try status_key(arena, added),
            .sentence = try std.fmt.allocPrint(arena, status_sentence, .{
                added.status.label,
                added.to,
            }),
            .reason = try status_reason(arena, added),
            .tier = .low,
        });
    }

    try append_limits(&list, arena, manifest.limits);

    if (list.items.len > requests_max) {
        return error.Invalid;
    }

    return list.items;
}

fn append_limits(list: *std.ArrayList(Request), arena: std.mem.Allocator, limits: Limits) !void {
    std.debug.assert(limit_keys.len == 4);
    std.debug.assert(limits.reason.len <= reason_len_max);

    const asked = [_]?u32{ limits.cpu_ms, limits.memory_mib, limits.calls, limits.output_kib };
    const sentences = [_][]const u8{
        "Run up to {d} ms of CPU in one call",
        "Use up to {d} MiB of memory",
        "Make up to {d} calls in one call",
        "Answer with up to {d} KiB",
    };

    inline for (asked, limit_keys, sentences) |value_or_null, key, sentence| {
        if (value_or_null) |value| {
            try list.append(arena, .{
                .key = key,
                .sentence = try std.fmt.allocPrint(arena, sentence, .{value}),
                .reason = limits.reason,
                .tier = .high,
            });
        }
    }
}

/// What the administrator reads for a hook, by what it can do.
fn hook_sentence(arena: std.mem.Allocator, hook: Hook) error{OutOfMemory}![]const u8 {
    std.debug.assert(hook.target.len > 0);
    std.debug.assert(hook.reason.len > 0);

    // Core's sign-in events (`auth.signed_in`): a `before` hook there can only refuse.
    if (std.mem.startsWith(u8, hook.target, "auth.") and hook.stage != .modify) {
        return switch (hook.stage) {
            .before => std.fmt.allocPrint(arena, "Refuse a sign-in or sign-up ({s})", .{
                hook.target,
            }),
            else => std.fmt.allocPrint(arena, "See when {s} happens", .{hook.target}),
        };
    }

    return switch (hook.stage) {
        .event => std.fmt.allocPrint(arena, "See when {s} happens", .{hook.target}),
        .after => std.fmt.allocPrint(arena, "See when the {s} operation happens", .{hook.target}),
        .before => std.fmt.allocPrint(arena, "Change what is sent to the {s} operation", .{
            hook.target,
        }),
        .modify => std.fmt.allocPrint(arena, "Change {s} wherever it is used", .{
            hook.target,
        }),
    };
}

/// `after:record.save`: the key a hook is granted and revoked by.
pub fn hook_key(arena: std.mem.Allocator, hook: Hook) error{OutOfMemory}![]const u8 {
    std.debug.assert(hook.target.len > 0);
    std.debug.assert(hook.reason.len > 0);

    return std.fmt.allocPrint(arena, "{s}:{s}", .{ @tagName(hook.stage), hook.target });
}

const status_sentence = "Add the status \u{201c}{s}\u{201d} to {s}";

/// `status:inventory.awaiting_stock`: the key an added status is granted and revoked by.
pub fn status_key(arena: std.mem.Allocator, added: flow.Added) error{OutOfMemory}![]const u8 {
    std.debug.assert(added.status.id.len > 0);
    std.debug.assert(added.to.len > 0);

    return std.fmt.allocPrint(arena, "status:{s}", .{added.status.id});
}

/// The transitions records take into and out of an added status, as its reason.
fn status_reason(arena: std.mem.Allocator, added: flow.Added) error{OutOfMemory}![]const u8 {
    std.debug.assert(added.transitions.len > 0);
    std.debug.assert(added.status.label.len > 0);

    var labels: std.ArrayList(u8) = .empty;

    try labels.appendSlice(arena, "Records go in and out by: ");

    for (added.transitions, 0..) |step, index| {
        if (index > 0) {
            try labels.appendSlice(arena, ", ");
        }

        try labels.appendSlice(arena, step.label);
    }

    return labels.items;
}

/// What is wrong with the statuses a manifest adds, if anything: each stored under the
/// plugin's name, joining another type, its transitions not core's, a way out of it.
pub fn statuses_problem(name: []const u8, statuses: []const flow.Added) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= name_len_max);

    if (statuses.len > status.statuses_max) {
        return "too many statuses";
    }

    for (statuses) |added| {
        const id = added.status.id;
        const under = id.len > name.len + 1 and std.mem.startsWith(u8, id, name) and
            id[name.len] == '.';

        if (!std.mem.eql(u8, added.plugin, name) or !under or id.len > status.id_len_max) {
            return "a status is stored under the plugin's name";
        }

        if (std.mem.indexOfScalar(u8, added.to, '.') == null) {
            return "a status joins a type named <plugin>.<type>";
        }

        if (added.transitions.len == 0 or added.transitions.len > flow.transitions_max) {
            return "a status needs its transitions";
        }

        for (added.transitions) |step| {
            if (flow.reserved(step.name) or step.name.len == 0 or step.label.len == 0) {
                return "a transition is core's or unnamed";
            }
        }

        if (flow.way_out(added) == null) {
            return "a status needs a way out";
        }
    }

    return null;
}

/// What installing grants at once: every available low and medium request. The rest waits.
pub fn granted_on_install(
    list: []const Request,
    arena: std.mem.Allocator,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(list.len <= requests_max);

    var granted: std.ArrayList([]const u8) = .empty;

    for (list) |request| {
        if (request.available and request.tier != .high) {
            try granted.append(arena, request.key);
        }
    }

    std.debug.assert(granted.items.len <= list.len);

    return granted.items;
}

/// The permissions a plugin holds now: each one asked for and granted, with its flags as an
/// administrator left them (never more than asked; as asked when never stored) and the
/// types it names as asked; a call to another plugin by its key alone.
pub fn held_now(
    arena: std.mem.Allocator,
    asks: []const Ask,
    granted: []const []const u8,
    stored: []const permission.Held,
) error{OutOfMemory}![]const permission.Held {
    std.debug.assert(asks.len <= requests_max);
    std.debug.assert(stored.len <= requests_max);

    var held: std.ArrayList(permission.Held) = .empty;

    for (asks) |*ask| {
        if (!permission.contains(granted, ask.key)) {
            continue;
        }

        if (permission.find(ask.key) == null) {
            try held.append(arena, .{
                .key = ask.key,
            });
        } else {
            try held.append(arena, as_set(ask.held(), stored));
        }
    }

    return held.items;
}

/// A permission's flags as set now: as stored, never above what was asked; as asked when
/// nothing was stored. Its domains are the administrator's list once one was saved.
pub fn as_set(asked: permission.Held, stored: []const permission.Held) permission.Held {
    std.debug.assert(asked.key.len > 0);
    std.debug.assert(stored.len <= requests_max);

    var set = asked;
    const kept = stored_of(stored, asked.key) orelse return set;

    set.domains = kept.domains;

    inline for (std.meta.fields(permission.Flag)) |field| {
        const flag: permission.Flag = @enumFromInt(field.value);

        set.set(flag, asked.flag(flag) and kept.flag(flag));
    }

    return set;
}

/// The domains a manifest asks for on `key`; none when it does not ask for it.
pub fn asked_domains(manifest: *const Manifest, key: []const u8) []const []const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(manifest.permissions.len <= requests_max);

    for (manifest.permissions) |ask| {
        if (std.mem.eql(u8, ask.key, key)) {
            return ask.domains;
        }
    }

    return &.{};
}

/// The domains `newer` asks for on `key` that `older` did not: an update's new requests.
pub fn added_domains(
    arena: std.mem.Allocator,
    older: *const Manifest,
    newer: *const Manifest,
    key: []const u8,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(key.len > 0);

    const before = asked_domains(older, key);
    var added: std.ArrayList([]const u8) = .empty;

    for (asked_domains(newer, key)) |domain| {
        if (!permission.contains(before, domain)) {
            try added.append(arena, domain);
        }
    }

    return added.items;
}

/// The stored grants once `newer` takes over from `older`. A saved domain list keeps what
/// the administrator chose: domains `older` asked for and they removed stay out, domains
/// they added stay in; domains `newer` no longer asks for leave; domains `newer` adds join
/// when `joining` (an update the administrator reviewed), never on a roll back.
pub fn grants_after(
    arena: std.mem.Allocator,
    stored: []const permission.Held,
    older: *const Manifest,
    newer: *const Manifest,
    joining: bool,
) error{OutOfMemory}![]const permission.Held {
    std.debug.assert(stored.len <= requests_max);

    const out = try arena.alloc(permission.Held, stored.len);

    for (stored, out) |held, *kept| {
        kept.* = held;

        const entry = permission.find(held.key) orelse continue;

        if (entry.narrowing != .domains) {
            continue;
        }

        const before = asked_domains(older, held.key);
        const after = asked_domains(newer, held.key);
        var domains: std.ArrayList([]const u8) = .empty;

        for (held.domains) |domain| {
            const dropped = permission.contains(before, domain) and
                !permission.contains(after, domain);

            if (!dropped) {
                try domains.append(arena, domain);
            }
        }

        if (joining) {
            for (after) |domain| {
                const fresh = !permission.contains(before, domain);

                if (fresh and !permission.contains(domains.items, domain) and
                    domains.items.len < @import("outside.zig").domains_max)
                {
                    try domains.append(arena, domain);
                }
            }
        }

        kept.domains = domains.items;
    }

    return out;
}

/// The stored grant for `key`, if any.
pub fn stored_of(stored: []const permission.Held, key: []const u8) ?*const permission.Held {
    std.debug.assert(key.len > 0);
    std.debug.assert(stored.len <= requests_max);

    for (stored) |*held| {
        if (std.mem.eql(u8, held.key, key)) {
            return held;
        }
    }

    return null;
}

/// Whether an update asks for a high-tier request the plugin does not hold now: then the
/// old version keeps running until someone approves.
pub fn update_needs_approval(list: []const Request, granted: []const []const u8) bool {
    std.debug.assert(list.len <= requests_max);
    std.debug.assert(granted.len <= requests_max);

    for (list) |request| {
        const held = permission.contains(granted, request.key);

        if (request.tier == .high and request.available and !held) {
            return true;
        }
    }

    return false;
}

/// The limits one call runs within: a raised limit counts only once granted.
pub fn effective_limits(limits: Limits, granted: []const []const u8) Effective {
    std.debug.assert(granted.len <= requests_max);
    std.debug.assert(limits.reason.len <= reason_len_max);

    var effective = limits_default;

    if (limits.cpu_ms) |value| {
        if (permission.contains(granted, "limit.cpu_ms")) effective.cpu_ms = value;
    }

    if (limits.memory_mib) |value| {
        if (permission.contains(granted, "limit.memory_mib")) effective.memory_mib = value;
    }

    if (limits.calls) |value| {
        if (permission.contains(granted, "limit.calls")) effective.calls = value;
    }

    if (limits.output_kib) |value| {
        if (permission.contains(granted, "limit.output_kib")) effective.output_kib = value;
    }

    return effective;
}

/// A plugin name: [a-z][a-z0-9_]*, 1 to 32 characters, as a plugin's.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max or !(name[0] >= 'a' and name[0] <= 'z')) {
        return false;
    }

    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or char == '_';

        if (!ok) {
            return false;
        }
    }

    return true;
}

const test_manifest: Manifest = .{
    .name = "greeter",
    .version = "0.1.0",
    .summary = "Greets",
    .permissions = &.{
        .{
            .key = "records.write",
            .records = &.{"post"},
            .publish = true,
            .reason = "Keeps greetings",
        },
        .{
            .key = "users.read",
            .reason = "Greets by name",
        },
        .{
            .key = "newsletter.send",
            .reason = "Mails greetings",
        },
    },
    .hooks = &.{.{
        .stage = .after,
        .target = "record.save",
        .reason = "Counts saves",
    }},
    .limits = .{
        .cpu_ms = 2000,
        .reason = "Resizes images",
    },
};

test "requests carry tiers; install grants low and medium that are available" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = try requests(&test_manifest, arena);
    const granted = try granted_on_install(list, arena);

    try std.testing.expectEqual(@as(usize, 5), list.len);
    try std.testing.expect(!list[2].available);
    try std.testing.expectEqualStrings("after:record.save", list[3].key);
    try std.testing.expectEqualStrings(
        "See when the record.save operation happens",
        list[3].sentence,
    );
    try std.testing.expectEqualStrings("Run up to 2000 ms of CPU in one call", list[4].sentence);
    try std.testing.expectEqual(permission.Tier.high, list[4].tier);
    try std.testing.expectEqual(@as(usize, 2), granted.len);
    try std.testing.expectEqualStrings("records.write", granted[0]);
    try std.testing.expect(list[0].asked.?.publish);
    try std.testing.expectEqual(permission.Tier.medium, list[0].tier);
    try std.testing.expect(update_needs_approval(list, granted));
    try std.testing.expect(!update_needs_approval(list, &.{ "users.read", "limit.cpu_ms" }));
}

test "a before hook on a sign-in reads as a refusal, never as a change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refusing = try hook_sentence(arena, .{
        .stage = .before,
        .target = "auth.signed_in",
        .reason = "Keeps suspended accounts out",
    });
    const seeing = try hook_sentence(arena, .{
        .stage = .after,
        .target = "auth.signed_out",
        .reason = "Empties the bag",
    });

    try std.testing.expectEqualStrings("Refuse a sign-in or sign-up (auth.signed_in)", refusing);
    try std.testing.expectEqualStrings("See when auth.signed_out happens", seeing);
}

test "limits count once granted; revoking one drops back to the default" {
    const raised = effective_limits(test_manifest.limits, &.{"limit.cpu_ms"});
    const default = effective_limits(test_manifest.limits, &.{});

    try std.testing.expectEqual(@as(u32, 2000), raised.cpu_ms);
    try std.testing.expectEqual(limits_default.cpu_ms, default.cpu_ms);
    try std.testing.expectEqual(limits_default.memory_mib, raised.memory_mib);
}

test "names" {
    try std.testing.expect(valid_name("greeter"));
    try std.testing.expect(!valid_name("Greeter"));
    try std.testing.expect(!valid_name("9lives"));
}

test "held now: granted keys only, flags never above what was asked, as asked when unset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const asks = [_]Ask{ .{
        .key = "records.write",
        .records = &.{"post"},
        .publish = true,
        .reason = "Keeps greetings",
    }, .{
        .key = "records.read",
        .drafts = true,
        .reason = "Reads posts",
    }, .{
        .key = "users.read",
        .reason = "Greets by name",
    } };
    const stored = [_]permission.Held{ .{
        .key = "records.write",
        .publish = false,
    }, .{
        .key = "records.read",
        .drafts = true,
        .private = true,
    } };
    const held = try held_now(arena, &asks, &.{ "records.write", "records.read" }, &stored);

    try std.testing.expectEqual(@as(usize, 2), held.len);
    try std.testing.expect(!held[0].publish);
    try std.testing.expectEqualStrings("post", held[0].records[0]);
    try std.testing.expect(held[1].drafts and !held[1].private);

    const fresh = try held_now(arena, &asks, &.{"records.write"}, &.{});

    try std.testing.expect(fresh[0].publish);
}

test "an update's new domains join a saved list; removed stay out, dropped leave" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const older: Manifest = .{
        .name = "courier",
        .version = "0.1.0",
        .summary = "Sends",
        .permissions = &.{.{
            .key = "http.fetch",
            .domains = &.{ "api.example.com", "old.example.com", "cut.example.com" },
            .reason = "Sends",
        }},
    };
    const newer: Manifest = .{
        .name = "courier",
        .version = "0.2.0",
        .summary = "Sends",
        .permissions = &.{.{
            .key = "http.fetch",
            .domains = &.{ "api.example.com", "cut.example.com", "new.example.com" },
            .reason = "Sends",
        }},
    };
    // The administrator removed cut.example.com and added chat.team.example.
    const saved = [_]permission.Held{.{
        .key = "http.fetch",
        .domains = &.{ "api.example.com", "old.example.com", "chat.team.example" },
    }};

    const updated = try grants_after(arena, &saved, &older, &newer, true);
    const expected = [_][]const u8{ "api.example.com", "chat.team.example", "new.example.com" };

    try std.testing.expectEqual(expected.len, updated[0].domains.len);

    for (expected, updated[0].domains) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }

    const rolled = try grants_after(arena, &saved, &older, &newer, false);

    try std.testing.expectEqual(@as(usize, 2), rolled[0].domains.len);

    const added = try added_domains(arena, &older, &newer, "http.fetch");

    try std.testing.expectEqual(@as(usize, 1), added.len);
    try std.testing.expectEqualStrings("new.example.com", added[0]);
}
