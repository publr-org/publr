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

pub const Namespace = struct { name: []const u8, summary: []const u8, details: []const u8 };

/// A permission a plugin asks for, by the key the administrator sees, with its own reason.
pub const Ask = struct { key: []const u8, reason: []const u8 };

/// More than the defaults, asked for with a reason; each raised limit waits for approval.
pub const Limits = struct {
    cpu_ms: ?u32 = null,
    memory_mib: ?u32 = null,
    calls: ?u32 = null,
    output_kib: ?u32 = null,
    reason: []const u8 = "",
};

/// Which content a plugin recommends it be given; the administrator decides.
pub const ContentAccess = struct {
    recommend: Scope = .public,
    note: []const u8 = "",

    pub const Scope = enum { public, all, specific };
};

pub const Manifest = struct {
    format: u32 = format,
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    namespaces: []const Namespace = &.{},
    operations: []const Operation = &.{},
    hooks: []const Hook = &.{},
    permissions: []const Ask = &.{},
    allowed_domains: []const []const u8 = &.{},
    depends_on: []const []const u8 = &.{},
    limits: Limits = .{},
    content_access: ContentAccess = .{},
    content_types: []const content_type.Def = &.{},
    custom_fields: []const content_type.Def = &.{},
    roles: []const role.Role = &.{},
    internal_records: []const internal_record.Collection = &.{},
    remotes: []const RemoteUse = &.{},
    compatible_with: []const []const u8 = &.{},
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
    fields: []const Field = &.{},
    /// Its `--help`, rendered by the build as a compiled-in operation's is.
    help: []const u8 = "",
    /// The shapes it takes and answers: its published contract.
    input: []const contract.Node = &.{},
    output: []const contract.Node = &.{},
    /// Input fields never written to the logs.
    secret: []const []const u8 = &.{},
};

/// Another plugin's operation as this plugin uses it: what it sends and what it reads.
pub const RemoteUse = plugin_contracts.Used;

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

    return .{ .plugin = manifest.name, .version = manifest.version, .operations = operations };
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

    pub const Shape = enum { string, integer, number, boolean, strings, json };
};

/// A hook a plugin asks for; its entry is the number of operations plus its position here.
pub const Hook = struct {
    stage: Stage,
    /// The operation a `before` or `after` hook runs on, or the event an event hook sees.
    target: []const u8,
    reason: []const u8,

    pub const Stage = enum { before, after, event };
};

/// The defaults every call into a plugin runs within.
pub const limits_default: Effective = .{
    .cpu_ms = 100,
    .memory_mib = 16,
    .calls = 1000,
    .output_kib = 1024,
};

pub const Effective = struct { cpu_ms: u32, memory_mib: u32, calls: u32, output_kib: u32 };

pub const limit_keys = [_][]const u8{
    "limit.cpu_ms",
    "limit.memory_mib",
    "limit.calls",
    "limit.output_kib",
};

/// One thing an administrator sees on the install page and grants or revokes on the
/// plugin's page: a catalog permission, a hook, a raised limit or a secret.
pub const Request = struct {
    key: []const u8,
    sentence: []const u8,
    reason: []const u8,
    tier: permission.Tier,
    /// False when nothing installed provides the key: the plugin runs without it.
    available: bool = true,
};

/// Everything the manifest asks for, each with its tier, in the manifest's order: catalog
/// permissions and secrets, then hooks, then raised limits. `hook_keys` holds the keys
/// written for hooks (`after:record.save`), which the requests point into.
pub fn requests(
    catalog: []const permission.Permission,
    manifest: *const Manifest,
    arena: std.mem.Allocator,
) error{ OutOfMemory, Invalid }![]const Request {
    std.debug.assert(catalog.len > 0);
    std.debug.assert(manifest.name.len > 0);

    var list: std.ArrayList(Request) = .empty;

    for (manifest.permissions) |ask| {
        const found = permission.find(catalog, ask.key);
        const tier = permission.tier_of(catalog, ask.key);

        try list.append(arena, .{
            .key = ask.key,
            .sentence = if (found) |entry| entry.sentence else ask.key,
            .reason = ask.reason,
            .tier = tier orelse .high,
            .available = tier != null,
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
                .before => .medium,
            },
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

    return switch (hook.stage) {
        .event, .after => std.fmt.allocPrint(arena, "See when {s} happens", .{hook.target}),
        .before => std.fmt.allocPrint(arena, "Change what is sent to {s}", .{hook.target}),
    };
}

/// `after:record.save`: the key a hook is granted and revoked by.
pub fn hook_key(arena: std.mem.Allocator, hook: Hook) error{OutOfMemory}![]const u8 {
    std.debug.assert(hook.target.len > 0);
    std.debug.assert(hook.reason.len > 0);

    return std.fmt.allocPrint(arena, "{s}:{s}", .{ @tagName(hook.stage), hook.target });
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

/// Why an installed plugin's roles cannot be installed, or null: a role from a plugin only
/// ever grants the plugin's own operations.
pub fn role_problem(name: []const u8, roles: []const role.Role) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(roles.len <= role.roles_max);

    for (roles) |declared| {
        for (declared.grants) |grant| {
            const wildcard = std.mem.endsWith(u8, grant, ".*");
            const namespace = if (wildcard) grant[0 .. grant.len - 2] else grant;
            const own = std.mem.eql(u8, namespace, name) or
                std.mem.startsWith(u8, namespace, name) and namespace.len > name.len and
                    namespace[name.len] == '.';
            const own_app = std.mem.startsWith(u8, namespace, "app.") and
                std.mem.eql(u8, namespace[4..], name);

            if (!own and !own_app) {
                return "a role from an installed plugin grants only the plugin's own operations";
            }
        }
    }

    return null;
}

const test_manifest: Manifest = .{
    .name = "greeter",
    .version = "0.1.0",
    .summary = "Greets",
    .permissions = &.{
        .{ .key = "content.write", .reason = "Keeps greetings" },
        .{ .key = "users.read", .reason = "Greets by name" },
        .{ .key = "newsletter.send", .reason = "Mails greetings" },
    },
    .hooks = &.{.{ .stage = .after, .target = "record.save", .reason = "Counts saves" }},
    .limits = .{ .cpu_ms = 2000, .reason = "Resizes images" },
};

test "requests carry tiers; install grants low and medium that are available" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = try requests(&permission.core, &test_manifest, arena);
    const granted = try granted_on_install(list, arena);

    try std.testing.expectEqual(@as(usize, 5), list.len);
    try std.testing.expect(!list[2].available);
    try std.testing.expectEqualStrings("after:record.save", list[3].key);
    try std.testing.expectEqualStrings("See when record.save happens", list[3].sentence);
    try std.testing.expectEqualStrings("Run up to 2000 ms of CPU in one call", list[4].sentence);
    try std.testing.expectEqual(permission.Tier.high, list[4].tier);
    try std.testing.expectEqual(@as(usize, 2), granted.len);
    try std.testing.expectEqualStrings("content.write", granted[0]);
    try std.testing.expect(update_needs_approval(list, granted));
    try std.testing.expect(!update_needs_approval(list, &.{ "users.read", "limit.cpu_ms" }));
}

test "limits count once granted; revoking one drops back to the default" {
    const raised = effective_limits(test_manifest.limits, &.{"limit.cpu_ms"});
    const default = effective_limits(test_manifest.limits, &.{});

    try std.testing.expectEqual(@as(u32, 2000), raised.cpu_ms);
    try std.testing.expectEqual(limits_default.cpu_ms, default.cpu_ms);
    try std.testing.expectEqual(limits_default.memory_mib, raised.memory_mib);
}

test "names and roles: own namespace only" {
    try std.testing.expect(valid_name("greeter"));
    try std.testing.expect(!valid_name("Greeter"));
    try std.testing.expect(!valid_name("9lives"));

    const own = [_]role.Role{.{
        .name = "editor",
        .label = "E",
        .grants = &.{ "greeter.*", "app.greeter.*" },
    }};
    const core = [_]role.Role{.{ .name = "editor", .label = "E", .grants = &.{"record.*"} }};
    const sneaky = [_]role.Role{.{ .name = "editor", .label = "E", .grants = &.{"greeters.*"} }};

    try std.testing.expect(role_problem("greeter", &own) == null);
    try std.testing.expect(role_problem("greeter", &core) != null);
    try std.testing.expect(role_problem("greeter", &sneaky) != null);
}
