//! What a plugin may call, installed or compiled in: the permissions it holds, turned into
//! the grant `authorize` returns. One function over data, so every call a plugin makes is
//! decided the same way.
const std = @import("std");
const permission = @import("../model/permission.zig");
const operation = @import("operation.zig");
const grant_module = @import("grant.zig");
const Grant = grant_module.Grant;
const plugin_depends_on = @import("plugin/depends_on.zig");
const secrets = @import("../model/secrets.zig");
const plugin_contracts = @import("../model/plugin_contracts.zig");

pub const Access = struct {
    /// Every key granted now, as granted: a permission with the flags on and the types it
    /// names, a call by its key alone. Revoking one takes effect on the next call.
    held: []const permission.Held = &.{},
    /// The content types the plugin declared: always its own.
    own_types: []const []const u8,
    /// The plugins it declares it depends on: the only ones whose operations a `call:`
    /// grant reaches.
    depends_on: []const []const u8 = &.{},
    /// The plugins it works with when present: a `call:` grant reaches these too.
    compatible_with: []const []const u8 = &.{},
    /// The secrets it declares: the only ones its requests out may name.
    secrets: []const secrets.Declared = &.{},
    /// What it uses of other plugins (`.remotes`): a remote record is read with only the
    /// fields it lists.
    remotes: []const plugin_contracts.Used = &.{},

    /// The key as granted now; null when it is off.
    pub fn held_of(access: *const Access, key: []const u8) ?*const permission.Held {
        std.debug.assert(key.len > 0);
        std.debug.assert(access.held.len <= permission.operations_max * 4);

        for (access.held) |*held| {
            if (std.mem.eql(u8, held.key, key)) {
                return held;
            }
        }

        return null;
    }
};

pub const Request = struct {
    operation_name: []const u8,
    type_id: ?[]const u8 = null,
};

/// The grant a plugin `name` holds for one request. Its own namespace and the harmless
/// operations need nothing; its own content types' records need nothing; everything else
/// needs a granted permission naming the operation, held to what it names and its flags.
pub fn grant(
    arena: std.mem.Allocator,
    name: []const u8,
    access: *const Access,
    request: Request,
) error{OutOfMemory}!Grant {
    var granted = try decided(arena, name, access, request);

    std.debug.assert(name.len > 0);

    if (granted.allows() and access.remotes.len > 0) {
        granted.remote_user = name;
        granted.remotes = access.remotes;
    }

    return granted;
}

fn decided(
    arena: std.mem.Allocator,
    name: []const u8,
    access: *const Access,
    request: Request,
) error{OutOfMemory}!Grant {
    std.debug.assert(name.len > 0);
    std.debug.assert(request.operation_name.len > 0);

    const operation_name = request.operation_name;

    if (permission.contains(&permission.never, operation_name)) {
        return Grant.deny;
    }

    if (permission.contains(&permission.always, operation_name) or own(name, operation_name)) {
        return Grant.allow_all;
    }

    if (calls_dependency(access, operation_name)) {
        return Grant.allow_all;
    }

    const own_type = if (request.type_id) |type_id|
        permission.contains(access.own_types, type_id)
    else
        false;

    if (own_type and permission.contains(&permission.own_records, operation_name)) {
        return .{
            .types = access.own_types,
        };
    }

    const entry = naming(operation_name) orelse return own_or_deny(
        access,
        request,
    );

    const granted = switch (entry.narrowing) {
        .records => try records_grant(arena, access, entry, request, "records"),
        .taxonomies => try records_grant(arena, access, entry, request, "terms"),
        .none, .domains => plain_grant(access, entry),
    };

    // A call naming a type out of reach is refused here, so asking whether it may is exact.
    if (request.type_id) |type_id| {
        if (!granted.allows_type(type_id)) {
            return Grant.deny;
        }
    }

    return granted;
}

/// A key that names nothing: on or off; one taking `.private` (media) keeps private files out
/// of reach without it.
fn plain_grant(access: *const Access, entry: *const permission.Permission) Grant {
    std.debug.assert(entry.narrowing == .none or entry.narrowing == .domains);
    std.debug.assert(entry.key.len > 0);

    const held = access.held_of(entry.key) orelse return Grant.deny;
    const takes_private = std.mem.indexOfScalar(permission.Flag, entry.flags, .private) != null;

    if (takes_private and !held.private) {
        return .{
            .record_filter = .{
                .flags = .{
                    .public_types_only = true,
                },
            },
        };
    }

    return Grant.allow_all;
}

/// Without a permission, a record operation still reaches the plugin's own types; one that
/// names another type is refused here rather than by the operation.
fn own_or_deny(access: *const Access, request: Request) Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(access.own_types.len <= permission.operations_max * 4);

    const own_record = permission.contains(&permission.own_records, request.operation_name);

    if (own_record and request.type_id == null) {
        return .{
            .types = access.own_types,
        };
    }

    return Grant.deny;
}

/// What a `records.*` (or `terms.*`) permission reaches for one operation: a read through
/// `.read` and `.write` together, a write through `.write` (`.publish` for what puts things
/// live), a removal for good through `.destroy`.
fn records_grant(
    arena: std.mem.Allocator,
    access: *const Access,
    entry: *const permission.Permission,
    request: Request,
    comptime family: []const u8,
) error{OutOfMemory}!Grant {
    std.debug.assert(entry.narrowing == .records or entry.narrowing == .taxonomies);
    std.debug.assert(request.operation_name.len > 0);

    const operation_name = request.operation_name;
    const read = access.held_of(family ++ ".read");
    const write = access.held_of(family ++ ".write");

    if (std.mem.endsWith(u8, entry.key, ".write") or std.mem.endsWith(u8, entry.key, ".destroy")) {
        const held = access.held_of(entry.key) orelse return own_or_deny(access, request);
        const publishing = permission.contains(entry.publishing, operation_name);

        if (publishing and !held.publish) {
            return own_or_deny(access, request);
        }

        return reach(arena, access.own_types, null, held);
    }

    const history = permission.contains(entry.history, operation_name);
    const readable = if (read) |held| !history or held.drafts else false;

    if (!readable and write == null) {
        return own_or_deny(access, request);
    }

    return reach(arena, access.own_types, if (readable) read else null, write);
}

/// The types a read through `read` and a write through `write` reach together: the ones
/// they name, any kind, or (naming none) every public type, every type with `.private`;
/// drafts where `.drafts` is on, the plugin's own types and what it writes.
fn reach(
    arena: std.mem.Allocator,
    own_types: []const []const u8,
    read: ?*const permission.Held,
    write: ?*const permission.Held,
) error{OutOfMemory}!Grant {
    std.debug.assert(read != null or write != null);
    std.debug.assert(own_types.len <= grant_module.list_len_max);

    const read_wide = if (read) |held| held.names().len == 0 else false;
    const write_wide = if (write) |held| held.names().len == 0 else false;
    const every_kind = read_wide and read.?.private;
    const read_live = if (read) |held| !held.drafts else false;
    const read_names = if (read) |held| held.names() else &.{};
    const write_names = if (write) |held| held.names() else &.{};
    const named = try concat(arena, &.{ own_types, read_names, write_names });
    const written = try concat(arena, &.{ own_types, write_names });

    return .{
        .types = if (read_wide or write_wide) null else named,
        .any_kind_types = named,
        .draft_types = written,
        .drafts_public = write_wide,
        .record_filter = .{
            .flags = .{
                .public_types_only = (read_wide or write_wide) and !every_kind,
                .live_only = read_live,
            },
        },
    };
}

/// The lists joined, each name once.
fn concat(
    arena: std.mem.Allocator,
    lists: []const []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(lists.len <= 3);

    var joined: std.ArrayList([]const u8) = .empty;

    for (lists) |list| {
        for (list) |name| {
            if (!permission.contains(joined.items, name)) {
                try joined.append(arena, name);
            }
        }
    }

    std.debug.assert(joined.items.len <= grant_module.list_len_max);

    return joined.items;
}

/// Whether a core permission names `operation_name`.
pub fn names_operation(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);

    return naming(operation_name) != null;
}

/// The permission whose operations name `operation_name`, if any.
fn naming(operation_name: []const u8) ?*const permission.Permission {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(permission.core.len > 0);

    for (&permission.core) |*entry| {
        if (permission.contains(entry.operations, operation_name)) {
            return entry;
        }
    }

    return null;
}

/// Whether `operation_name` is in the plugin's own namespace: `<name>.*`.
pub fn own(name: []const u8, operation_name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(operation_name.len > 0);

    return std.mem.eql(u8, operation.namespace(operation_name), name);
}

/// Whether a granted `call:` permission names exactly this operation of a plugin it depends
/// on. A dependency alone grants nothing, and neither does a grant without one.
fn calls_dependency(access: *const Access, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(access.depends_on.len <= plugin_depends_on.depends_on_max);

    for (access.held) |held| {
        const target = permission.called_operation(held.key) orelse continue;

        if (!std.mem.eql(u8, target, operation_name)) {
            continue;
        }

        for ([_][]const []const u8{ access.depends_on, access.compatible_with }) |list| {
            if (plugin_depends_on.names_owner(list, operation_name)) {
                return true;
            }
        }
    }

    return false;
}

const testing_arena = std.testing.allocator;

fn granted_for(
    arena: std.mem.Allocator,
    access: *const Access,
    operation_name: []const u8,
    type_id: ?[]const u8,
) !Grant {
    return grant(arena, "greeter", access, .{
        .operation_name = operation_name,
        .type_id = type_id,
    });
}

test "own namespace and harmless calls need nothing; never is never" {
    var arena_state = std.heap.ArenaAllocator.init(testing_arena);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const access: Access = .{
        .own_types = &.{"greeting"},
    };

    try std.testing.expect((try granted_for(arena, &access, "greeter.greet", null)).allows());
    try std.testing.expect((try granted_for(arena, &access, "heartbeat.check", null)).allows());
    try std.testing.expect(!(try granted_for(arena, &access, "user.list", null)).allows());

    const everything: Access = .{
        .held = &.{ .{
            .key = "users.read",
        }, .{
            .key = "users.write",
        } },
        .own_types = &.{},
    };

    try std.testing.expect(!(try granted_for(arena, &everything, "user.password_link", null))
        .allows());
    try std.testing.expect((try granted_for(arena, &everything, "user.list", null)).allows());
}

test "records.read starts at what a visitor sees; each flag opens more" {
    var arena_state = std.heap.ArenaAllocator.init(testing_arena);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var held: permission.Held = .{
        .key = "records.read",
    };
    const access: Access = .{
        .held = (&held)[0..1],
        .own_types = &.{"greeting"},
    };

    const live = try granted_for(arena, &access, "record.list", "post");

    try std.testing.expect(live.allows_type("post"));
    try std.testing.expect(live.public_only_on("post"));
    try std.testing.expect(live.live_only_on("post", true));
    try std.testing.expect(!live.public_only_on("greeting"));
    try std.testing.expect(!live.live_only_on("greeting", false));
    try std.testing.expect(!(try granted_for(arena, &access, "snapshot.get", "post")).allows());
    try std.testing.expect(!(try granted_for(arena, &access, "record.save", "post")).allows());

    held.drafts = true;

    const drafts = try granted_for(arena, &access, "record.get", "post");

    try std.testing.expect(!drafts.live_only_on("post", true));
    try std.testing.expect(drafts.public_only_on("post"));
    try std.testing.expect((try granted_for(arena, &access, "snapshot.get", "post")).allows());

    held.private = true;
    try std.testing.expect(!(try granted_for(arena, &access, "record.list", null))
        .public_only_on("notes"));

    held.private = false;
    held.records = &.{"notes"};

    const named = try granted_for(arena, &access, "record.list", null);

    try std.testing.expect(named.allows_type("notes"));
    try std.testing.expect(!named.allows_type("post"));
    try std.testing.expect(!named.public_only_on("notes"));
}

test "records.write reads what it writes; .publish alone puts things live; destroy apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing_arena);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var held = [_]permission.Held{ .{
        .key = "records.read",
    }, .{
        .key = "records.write",
        .records = &.{"notes"},
    } };
    var access: Access = .{
        .held = &held,
        .own_types = &.{},
    };

    const read = try granted_for(arena, &access, "record.get", null);

    try std.testing.expect(read.allows_type("post"));
    try std.testing.expect(!read.live_only_on("notes", false));
    try std.testing.expect(!read.public_only_on("notes"));
    try std.testing.expect(read.live_only_on("post", true));
    try std.testing.expect((try granted_for(arena, &access, "record.save", "notes")).allows());
    try std.testing.expect(!(try granted_for(arena, &access, "record.save", "post")).allows());
    try std.testing.expect(!(try granted_for(arena, &access, "record.publish", "notes"))
        .allows());
    try std.testing.expect(!(try granted_for(arena, &access, "record.purge", "notes")).allows());

    held[1].publish = true;
    try std.testing.expect((try granted_for(arena, &access, "record.publish", "notes"))
        .allows());

    access.held = held[1..];
    try std.testing.expect(!(try granted_for(arena, &access, "record.list", "post")).allows());
    try std.testing.expect((try granted_for(arena, &access, "record.list", "notes")).allows());

    const destroy = [_]permission.Held{.{
        .key = "records.destroy",
    }};

    access = .{
        .held = &destroy,
        .own_types = &.{},
    };
    try std.testing.expect((try granted_for(arena, &access, "record.purge", "post")).allows());
    try std.testing.expect(!(try granted_for(arena, &access, "record.save", "post")).allows());
}

test "media.read keeps private files out of reach without .private" {
    var arena_state = std.heap.ArenaAllocator.init(testing_arena);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var held = [_]permission.Held{.{
        .key = "media.read",
    }};
    const access: Access = .{
        .held = &held,
        .own_types = &.{},
    };

    try std.testing.expect((try granted_for(arena, &access, "media.get", null))
        .record_filter.flags.public_types_only);
    try std.testing.expect(!(try granted_for(arena, &access, "media.upload", null)).allows());

    held[0].private = true;
    try std.testing.expect(!(try granted_for(arena, &access, "media.get", null))
        .record_filter.flags.public_types_only);
}

test "a switched-off key reaches nothing; its own types still are" {
    var arena_state = std.heap.ArenaAllocator.init(testing_arena);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const access: Access = .{
        .own_types = &.{"greeting"},
    };

    try std.testing.expect(!(try granted_for(arena, &access, "record.save", "post")).allows());
    try std.testing.expect((try granted_for(arena, &access, "record.save", "greeting")).allows());
    try std.testing.expect(access.held_of("records.write") == null);
}

test "an exact plugin call needs both its grant and a declared parent" {
    var arena_state = std.heap.ArenaAllocator.init(testing_arena);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var access: Access = .{
        .held = &.{.{
            .key = "call:provider.adjust",
        }},
        .own_types = &.{},
    };
    const request: Request = .{
        .operation_name = "provider.adjust",
    };
    try std.testing.expect(!(try grant(arena, "child", &access, request)).allows());
    access.depends_on = &.{"provider@^0.3"};
    try std.testing.expect((try grant(arena, "child", &access, request)).allows());
    try std.testing.expect(!(try grant(arena, "child", &access, .{
        .operation_name = "provider.purge",
    })).allows());

    access.held = &.{};
    try std.testing.expect(!(try grant(arena, "child", &access, request)).allows());
}
