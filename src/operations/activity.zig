//! The activity log: one entry per top-level write that completed, written in its
//! transaction from the call's trail (`sdk/trail.zig`), its secrets masked
//! (`model/secret.zig`), what it changed named as units. Read only: `activity.list`.

const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Entry = sdk.trail.Entry;

pub const namespace: sdk.operation.Namespace = .{
    .name = "activity",
    .summary = "What was done: every completed write, kept forever",
    .details =
    \\One entry per top-level write: who, when, through which app, the operation, its
    \\input with secrets masked, the operations it set off inside and what it changed
    \\(`record:<id>`, `plugin:<name>`). Entries are never changed or removed. Refused and
    \\failed calls are in `errors`.
    ,
};

/// The log seam the registry hands the SDK.
pub const log: sdk.trail.Log = .{ .activity = &write_activity, .failure = &write_failure };

pub const Item = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    input: []const u8,
    units: []const []const u8,
    calls: []const []const u8,
};

pub const List = struct {
    pub const name = "activity.list";
    pub const description = "What was done, newest first";
    pub const details =
        \\Administrators only. Filters: who (a user id, `system`, `anonymous`, or
        \\`plugin:<name>`), the operation, a unit it changed, a time range in milliseconds.
        \\Page back with `before`, the id of the oldest entry shown.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        actor: ?[]const u8 = null,
        operation: ?[]const u8 = null,
        unit: ?[]const u8 = null,
        since: ?i64 = null,
        until: ?i64 = null,
        before: ?i64 = null,
        limit: u32 = 50,
    };
    pub const Out = struct { entries: []const Item };
    pub const rules: sdk.operation.Rules(In) = .{
        .limit = .{ .min = 1, .max = store.activity.list_max },
    };
    pub const example: In = .{ .operation = "plugin.enable" };
    pub const example_out: Out = .{ .entries = &.{.{
        .id = 42,
        .at = 1_790_000_000_000,
        .actor = "u_admin",
        .app = "",
        .operation = "plugin.enable",
        .input = "{\"names\":[\"greeter\"],\"content_access\":\"public\",\"types\":[]}",
        .units = &.{"plugin:greeter"},
        .calls = &.{},
    }} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .actor = "Who: a user id, `system`, `anonymous` or `plugin:<name>`",
        .operation = "One operation, `plugin.disable`",
        .unit = "A unit the entry changed, `record:<id>` or `plugin:<name>`",
        .since = "From this time, milliseconds",
        .until = "Before this time, milliseconds",
        .before = "Only entries older than this id: the next page",
        .limit = "Page size",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .entries = "Newest first: id, time, who, app, operation, masked input, units, calls",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.limit <= store.activity.list_max);

        const rows = try store.activity.list(ctx.db, ctx.arena, .{
            .actor = in.actor,
            .operation = in.operation,
            .unit = in.unit,
            .since = in.since,
            .until = in.until,
            .before = in.before,
        }, in.limit);
        const items = ctx.arena.alloc(Item, rows.len) catch return error.OutOfMemory;

        for (rows, items) |row, *item| {
            item.* = .{
                .id = row.id,
                .at = row.at,
                .actor = row.actor,
                .app = row.app,
                .operation = row.operation,
                .input = row.input,
                .units = try names_of(ctx, row.units),
                .calls = try names_of(ctx, row.calls),
            };
        }

        return .{ .entries = items };
    }
};

pub const operations = [_]type{List};

fn write_activity(ctx: *Ctx, entry: *const Entry) Error!void {
    std.debug.assert(entry.operation.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    try store.activity.append(ctx.db, .{
        .id = 0,
        .at = ctx.now_ms,
        .actor = try actor_of(ctx),
        .app = ctx.app,
        .operation = entry.operation,
        .input = try masked_input(ctx, entry),
        .units = try json_of(ctx, try units_of(ctx, entry.notices)),
        .calls = try json_of(ctx, entry.calls),
    });
}

/// After the rollback, outside any transaction: a failure to write is reported, never
/// raised, since the call has already failed.
fn write_failure(ctx: *Ctx, entry: *const Entry) void {
    std.debug.assert(entry.operation.len > 0);
    std.debug.assert(entry.error_name.len > 0);

    append_failure(ctx, entry) catch |err| {
        std.log.warn("error log: {s} not written: {s}", .{ entry.operation, @errorName(err) });
    };
}

fn append_failure(ctx: *Ctx, entry: *const Entry) Error!void {
    std.debug.assert(entry.operation.len > 0);

    try store.errors.append(ctx.db, .{
        .id = 0,
        .at = ctx.now_ms,
        .actor = try actor_of(ctx),
        .app = ctx.app,
        .operation = entry.operation,
        .input = try masked_input(ctx, entry),
        .calls = try json_of(ctx, entry.calls),
        .@"error" = entry.error_name,
        .message = entry.message,
        .failed_in = entry.failed_in,
    });
}

fn masked_input(ctx: *Ctx, entry: *const Entry) Error![]const u8 {
    std.debug.assert(entry.secret.len <= 64);

    return model.secret.masked(ctx.arena, entry.input, entry.secret);
}

/// Who called: a user's id, `system`, `anonymous`, `plugin:<name>`, `token:<id>`.
pub fn actor_of(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const text = switch (ctx.caller) {
        .anonymous => if (ctx.visitor.len > 0)
            std.fmt.allocPrint(ctx.arena, "visitor:{s}", .{ctx.visitor})
        else
            return "anonymous",
        .system => return "system",
        .user => |user| return user.id,
        .token => |token| std.fmt.allocPrint(ctx.arena, "token:{s}", .{token.id}),
        .machine => |machine| std.fmt.allocPrint(ctx.arena, "machine:{s}", .{machine.id}),
        .plugin => |plugin| std.fmt.allocPrint(ctx.arena, "plugin:{s}", .{plugin.name}),
    };

    return text catch error.OutOfMemory;
}

/// The notices that name something changed, as units, each once: `record.saved <id>` is
/// `record:<id>`. A plugin's own notices name nothing the log tracks.
fn units_of(ctx: *Ctx, notices: []const sdk.trail.Notice) Error![]const []const u8 {
    std.debug.assert(notices.len <= sdk.trail.notices_max);

    var units: std.ArrayList([]const u8) = .empty;

    for (notices) |notice| {
        const prefix = unit_prefix(notice.name) orelse continue;

        if (notice.subject.len == 0) {
            continue;
        }

        const unit = std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ prefix, notice.subject }) catch {
            return error.OutOfMemory;
        };

        if (!listed(units.items, unit)) {
            units.append(ctx.arena, unit) catch return error.OutOfMemory;
        }
    }

    return units.items;
}

/// The unit kind a notice names, by its namespace; null for one that changes nothing kept.
fn unit_prefix(notice: []const u8) ?[]const u8 {
    std.debug.assert(notice.len > 0);

    const kept = [_][2][]const u8{
        .{ "record.", "record" },
        .{ "term.", "term" },
        .{ "content_type.", "content_type" },
        .{ "taxonomy.", "taxonomy" },
        .{ "custom_fields.", "field_group" },
        .{ "plugin.", "plugin" },
        .{ "view.", "view" },
        .{ "internal.", "internal" },
        .{ "snapshot.", "record" },
        .{ "auth.user_", "user" },
        .{ "auth.password_set", "user" },
        .{ "auth.identity_linked", "user" },
        .{ "auth.identity_unlinked", "user" },
    };

    for (kept) |pair| {
        if (std.mem.startsWith(u8, notice, pair[0])) {
            return pair[1];
        }
    }

    return null;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

pub fn json_of(ctx: *Ctx, names: []const []const u8) Error![]const u8 {
    std.debug.assert(names.len <= sdk.trail.notices_max);

    return std.json.Stringify.valueAlloc(ctx.arena, names, .{}) catch error.OutOfMemory;
}

pub fn names_of(ctx: *Ctx, text: []const u8) Error![]const []const u8 {
    std.debug.assert(text.len > 0);

    return std.json.parseFromSliceLeaky([]const []const u8, ctx.arena, text, .{}) catch &.{};
}

test "secrets: every operation with a field the net catches declares it" {
    const registry = @import("../server/registry.zig");
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(std.testing.allocator);

    inline for (registry.SDK.operations) |Operation| {
        const declared = comptime sdk.trail.secret_of(Operation);

        inline for (@typeInfo(Operation.In).@"struct".fields) |field| {
            const text = field.type == []const u8 or field.type == ?[]const u8;

            if (text and model.secret.caught(field.name) and !listed(declared, field.name)) {
                try missing.append(std.testing.allocator, Operation.name ++ "." ++ field.name);
            }
        }
    }

    for (missing.items) |name| {
        std.debug.print("undeclared secret: {s}\n", .{name});
    }

    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
}

test "logs: a write and what it set off, secrets masked, failures apart, never changed" {
    const registry = @import("../server/registry.zig");
    const records = @import("record.zig");
    const snapshots = @import("snapshot.zig");
    const content_types = @import("content_type.zig");
    const users = @import("user.zig");
    const errors = @import("errors.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    _ = try registry.SDK.dispatch(&system, content_types.Create, .{
        .definition = "{\"handle\":\"note\",\"name\":\"Note\",\"fields\":[" ++
            "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\",\"required\":true}]}",
    });
    const created = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "note",
        .document = "{\"title\":\"One\"}",
        .status = "published",
    });
    _ = try registry.SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\"}",
        .status = "published",
    });
    _ = try registry.SDK.dispatch(&system, snapshots.Restore, .{ .id = created.id, .seq = 1 });

    const restored = try registry.SDK.dispatch(&system, List, .{ .operation = "snapshot.restore" });
    const unit = try std.fmt.allocPrint(system.arena, "record:{s}", .{created.id});

    try std.testing.expectEqual(@as(usize, 1), restored.entries.len);
    try std.testing.expectEqualStrings("system", restored.entries[0].actor);
    try std.testing.expectEqualStrings("record.save", restored.entries[0].calls[0]);
    try std.testing.expect(listed(restored.entries[0].units, unit));

    const saves = try registry.SDK.dispatch(&system, List, .{ .operation = "record.save" });
    try std.testing.expectEqual(@as(usize, 1), saves.entries.len);

    _ = try registry.SDK.dispatch(&system, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password = "correct horse battery",
    });
    const made = try registry.SDK.dispatch(&system, List, .{ .operation = "user.create" });
    try std.testing.expect(std.mem.indexOf(u8, made.entries[0].input, "horse") == null);
    try std.testing.expect(std.mem.indexOf(u8, made.entries[0].input, model.secret.mark) != null);

    const broken = registry.SDK.dispatch(&system, records.Create, .{
        .type = "note",
        .document = "{\"title\":7}",
    });
    try std.testing.expectError(error.Invalid, broken);

    var anonymous = harness.ctx(.anonymous);
    const denied = registry.SDK.dispatch(&anonymous, List, .{});
    try std.testing.expectError(error.Denied, denied);

    const creates = try registry.SDK.dispatch(&system, List, .{ .operation = "record.create" });
    try std.testing.expectEqual(@as(usize, 1), creates.entries.len);

    const failed = try registry.SDK.dispatch(&system, errors.List, .{});
    try std.testing.expectEqual(@as(usize, 2), failed.entries.len);
    try std.testing.expectEqualStrings("Denied", failed.entries[0].@"error");
    try std.testing.expectEqualStrings("activity.list", failed.entries[0].operation);
    try std.testing.expectEqualStrings("record.create", failed.entries[1].operation);
}
