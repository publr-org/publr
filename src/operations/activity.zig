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
    .label = "Activity log",
    .area = .system,
    .summary = "What was done: every completed write, kept forever",
    .details =
    \\One entry per top-level write: who, when, through which app, the operation, its
    \\input with secrets masked, the operations it set off inside and what it changed
    \\(`record:<id>`, `plugin:<name>`). Entries are never changed or removed. Refused and
    \\failed calls are in `errors`.
    ,
};

/// The log seam the registry hands the SDK.
pub const log: sdk.trail.Log = .{
    .activity = &write_activity,
    .failure = &write_failure,
    .lines = &write_lines,
};

/// A line a plugin logged during the entry's call (`ctx.log`).
pub const Line = struct {
    plugin: []const u8,
    /// `info`, `warn` or `err`.
    level: []const u8,
    line: []const u8,
};

pub const Item = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    input: []const u8,
    units: []const []const u8,
    calls: []const []const u8,
    /// What plugins logged during the call, in order.
    lines: []const Line = &.{},
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
    pub const Out = struct {
        entries: []const Item,
    };
    pub const rules: sdk.operation.Rules(In) = .{
        .limit = .{
            .min = 1,
            .max = store.activity.list_max,
        },
    };
    pub const example: In = .{
        .operation = "plugin.enable",
    };
    pub const example_out: Out = .{
        .entries = &.{.{
            .id = 42,
            .at = 1_790_000_000_000,
            .actor = "u_admin",
            .app = "",
            .operation = "plugin.enable",
            .input = "{\"names\":[\"greeter\"]}",
            .units = &.{"plugin:greeter"},
            .calls = &.{},
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .actor = "Who: a user id, `system`, `anonymous`, `plugin:<name>` or " ++
            "`job:<plugin>.<name>`",
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
        const logged = try lines_of(ctx, .activity, rows);

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
                .lines = try lines_for(ctx, logged, .activity, row.id),
            };
        }

        return .{
            .entries = items,
        };
    }
};

pub const operations = [_]type{List};

fn write_activity(ctx: *Ctx, entry: *const Entry) Error!?sdk.trail.Logged {
    std.debug.assert(entry.operation.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    try store.activity.append(ctx.db, .{
        .id = 0,
        .at = ctx.now_ms,
        .actor = try actor_of(ctx),
        .app = ctx.app,
        .operation = entry.operation,
        .input = try masked_input(ctx, entry),
        .units = try json_of(ctx, try units_of(ctx, entry.events, entry.units)),
        .calls = try json_of(ctx, entry.calls),
    });

    const id = ctx.db.last_insert_rowid();

    const logged = try logged_error(ctx, entry.operation, entry.lines);
    const error_id = if (logged) |found| found.entry else 0;

    try append_lines(ctx, entry.operation, entry.lines, id, error_id);

    return logged;
}

/// What a read that answered, or a queued run, logged: after it ends, outside any
/// transaction, so a failure to write is reported, never raised.
fn write_lines(ctx: *Ctx, call: []const u8, lines: []const sdk.trail.Line) ?sdk.trail.Logged {
    std.debug.assert(call.len > 0);
    std.debug.assert(lines.len > 0);

    const logged = logged_error(ctx, call, lines) catch |err| {
        std.log.warn("plugin log: {s} not written: {s}", .{ call, @errorName(err) });
        return null;
    };
    const error_id = if (logged) |found| found.entry else 0;

    append_lines(ctx, call, lines, 0, error_id) catch |err| {
        std.log.warn("plugin log: {s} not written: {s}", .{ call, @errorName(err) });
    };

    return logged;
}

/// A call that answered but logged an `.err` line is in the Error log too: error `Logged`,
/// its first such line the message. Answers the entry; null when nothing logged an error.
fn logged_error(
    ctx: *Ctx,
    call: []const u8,
    lines: []const sdk.trail.Line,
) Error!?sdk.trail.Logged {
    std.debug.assert(call.len > 0);
    std.debug.assert(lines.len <= sdk.trail.lines_max + 1);

    const first = for (lines) |line| {
        if (line.level == .err) {
            break line;
        }
    } else {
        return null;
    };

    try store.errors.append(ctx.db, .{
        .id = 0,
        .at = ctx.now_ms,
        .actor = std.fmt.allocPrint(ctx.arena, "plugin:{s}", .{first.plugin}) catch
            return error.OutOfMemory,
        .app = ctx.app,
        .operation = call,
        .input = "",
        .calls = "[]",
        .@"error" = "Logged",
        .message = first.text,
        .failed_in = "",
    });

    return .{
        .what = call,
        .plugin = first.plugin,
        .error_name = "Logged",
        .message = first.text,
        .caller = caller_kind(ctx),
        .at = ctx.now_ms,
        .entry = ctx.db.last_insert_rowid(),
    };
}

/// The kind of caller `publr.errors.Failed` names: `job` for queued work.
fn caller_kind(ctx: *const Ctx) []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.job.len > 0) {
        return "job";
    }

    return @tagName(ctx.caller);
}

fn append_lines(
    ctx: *Ctx,
    call: []const u8,
    lines: []const sdk.trail.Line,
    activity_id: i64,
    error_id: i64,
) Error!void {
    std.debug.assert(call.len > 0);
    std.debug.assert(activity_id >= 0 and error_id >= 0);

    for (lines) |line| {
        try store.plugin_log.append(ctx.db, .{
            .id = 0,
            .at = ctx.now_ms,
            .plugin = line.plugin,
            .level = @tagName(line.level),
            .line = line.text,
            .call = call,
            .activity = activity_id,
            .@"error" = error_id,
        });
    }
}

/// The lines that went with a page of either log, in one read.
pub fn lines_of(
    ctx: *Ctx,
    comptime entries: store.plugin_log.Entries,
    rows: anytype,
) Error![]const store.plugin_log.Row {
    std.debug.assert(rows.len <= store.activity.list_max);

    if (rows.len == 0) {
        return &.{};
    }

    // Rows come newest first.
    const oldest = rows[rows.len - 1].id;

    return store.plugin_log.of_entries(ctx.db, ctx.arena, entries, oldest, rows[0].id);
}

/// The lines of one entry, out of a page's.
pub fn lines_for(
    ctx: *Ctx,
    logged: []const store.plugin_log.Row,
    entries: store.plugin_log.Entries,
    id: i64,
) Error![]const Line {
    std.debug.assert(id > 0);

    var lines: std.ArrayList(Line) = .empty;

    for (logged) |row| {
        const of = switch (entries) {
            .activity => row.activity,
            .@"error" => row.@"error",
        };

        if (of == id) {
            lines.append(ctx.arena, .{
                .plugin = row.plugin,
                .level = row.level,
                .line = row.line,
            }) catch return error.OutOfMemory;
        }
    }

    return lines.items;
}

/// After the rollback, outside any transaction: a failure to write is reported, never
/// raised, since the call has already failed.
fn write_failure(ctx: *Ctx, entry: *const Entry) ?sdk.trail.Logged {
    std.debug.assert(entry.operation.len > 0);
    std.debug.assert(entry.error_name.len > 0);

    return append_failure(ctx, entry) catch |err| {
        std.log.warn("error log: {s} not written: {s}", .{ entry.operation, @errorName(err) });
        return null;
    };
}

fn append_failure(ctx: *Ctx, entry: *const Entry) Error!sdk.trail.Logged {
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

    const id = ctx.db.last_insert_rowid();

    try append_lines(ctx, entry.operation, entry.lines, 0, id);

    return .{
        .what = if (entry.failed_in.len > 0) entry.failed_in else entry.operation,
        .plugin = ctx.plugin,
        .error_name = entry.error_name,
        .message = entry.message,
        .caller = caller_kind(ctx),
        .at = ctx.now_ms,
        .entry = id,
    };
}

fn masked_input(ctx: *Ctx, entry: *const Entry) Error![]const u8 {
    std.debug.assert(entry.secret.len <= 64);

    return model.secret.masked(ctx.arena, entry.input, entry.secret);
}

/// Who called: a user's id, `system`, `anonymous`, `plugin:<name>`, `token:<id>`.
pub fn actor_of(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    // A job's run is the author of its changes, whoever it runs as.
    if (ctx.job.len > 0) {
        return std.fmt.allocPrint(ctx.arena, "job:{s}", .{ctx.job}) catch error.OutOfMemory;
    }

    const text = switch (ctx.caller) {
        .anonymous => if (ctx.visitor.len > 0)
            std.fmt.allocPrint(ctx.arena, "visitor:{s}", .{ctx.visitor})
        else
            return "anonymous",
        .system => return "system",
        .user => |user| return user.id,
        .token => |token| std.fmt.allocPrint(ctx.arena, "token:{s}", .{token.id}),
        .plugin => |plugin| std.fmt.allocPrint(ctx.arena, "plugin:{s}", .{plugin.name}),
    };

    return text catch error.OutOfMemory;
}

/// What the call changed, as units, each once, in order: what the writes' `after` hooks and
/// the records' moves said (`changed`), each where its write started, and core's typed
/// events that name something in their payload's first field (`auth.user_created
/// {"user":"u_1"}` is `user:u_1`). A plugin's own events name nothing.
fn units_of(
    ctx: *Ctx,
    events: []const sdk.trail.Emitted,
    changed: []const sdk.trail.Changed,
) Error![]const []const u8 {
    std.debug.assert(events.len <= sdk.trail.events_max);
    std.debug.assert(changed.len <= sdk.trail.events_max);

    var units: Units = .{};
    const placed = ctx.arena.dupe(sdk.trail.Changed, changed) catch return error.OutOfMemory;
    var next: u32 = 0;

    std.sort.insertion(sdk.trail.Changed, placed, {}, earlier);

    for (events, 0..) |emitted, position| {
        while (next < placed.len and placed[next].at <= position) : (next += 1) {
            try units.add(ctx, placed[next].unit);
        }

        const prefix = unit_prefix(emitted.name) orelse continue;
        const key = unit_key(ctx, emitted.subject) orelse continue;
        const unit = std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ prefix, key }) catch {
            return error.OutOfMemory;
        };

        try units.add(ctx, unit);
    }

    for (placed[next..]) |rest| {
        try units.add(ctx, rest.unit);
    }

    return units.list.items;
}

fn earlier(_: void, one: sdk.trail.Changed, other: sdk.trail.Changed) bool {
    return one.at < other.at;
}

const Units = struct {
    list: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(units: *Units, ctx: *Ctx, unit: []const u8) Error!void {
        std.debug.assert(unit.len > 0);
        std.debug.assert(units.list.items.len == units.seen.count());

        if (!units.seen.contains(unit)) {
            units.list.append(ctx.arena, unit) catch return error.OutOfMemory;
            units.seen.put(ctx.arena, unit, {}) catch return error.OutOfMemory;
        }
    }
};

/// The units the call's writes changed, kept on its trail where each write started; a move
/// over many records, each record its transition event names.
pub const middleware = changed_units.hooks(std.enums.values(changed_units.Kind), keep_unit) ++
    [_]type{changed_units.Moves(&.{ .record, .term }, keep_unit)};

const changed_units = sdk.changed_units;

fn keep_unit(ctx: *Ctx, operation: []const u8, unit: changed_units.Unit) void {
    std.debug.assert(operation.len > 0);
    std.debug.assert(unit.key.len > 0);

    const open = ctx.trail orelse return;
    const text = unit.text(ctx.arena) catch return;

    open.changed(ctx.trail_start, text);
}

/// What a typed event's payload names: its first field.
fn unit_key(ctx: *Ctx, subject: []const u8) ?[]const u8 {
    std.debug.assert(subject.len <= std.math.maxInt(u32));

    if (subject.len == 0 or subject[0] != '{') {
        return null;
    }

    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, subject, .{}) catch
        return null;

    if (value != .object or value.object.count() == 0) {
        return null;
    }

    const first = value.object.values()[0];

    return if (first == .string and first.string.len > 0) first.string else null;
}

/// The unit kind an event names, by its namespace; null for one that changes nothing kept.
fn unit_prefix(emitted: []const u8) ?[]const u8 {
    std.debug.assert(emitted.len > 0);

    const kept = [_][2][]const u8{
        .{ "internal.", "internal" },
        .{ "auth.user_", "user" },
    };

    for (kept) |pair| {
        if (std.mem.startsWith(u8, emitted, pair[0])) {
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
    std.debug.assert(names.len <= sdk.trail.events_max);

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
            "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\"," ++
            "\"validation\":{\"required\":true}}]}",
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
    _ = try registry.SDK.dispatch(&system, snapshots.Restore, .{
        .id = created.id,
        .seq = 1,
    });

    const restored = try registry.SDK.dispatch(&system, List, .{
        .operation = "snapshot.restore",
    });
    const unit = try std.fmt.allocPrint(system.arena, "record:{s}", .{created.id});

    try std.testing.expectEqual(@as(usize, 1), restored.entries.len);
    try std.testing.expectEqualStrings("system", restored.entries[0].actor);
    try std.testing.expectEqualStrings("record.save", restored.entries[0].calls[0]);
    try std.testing.expect(listed(restored.entries[0].units, unit));

    const saves = try registry.SDK.dispatch(&system, List, .{
        .operation = "record.save",
    });
    try std.testing.expectEqual(@as(usize, 1), saves.entries.len);

    _ = try registry.SDK.dispatch(&system, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password = "correct horse battery",
    });
    const made = try registry.SDK.dispatch(&system, List, .{
        .operation = "user.create",
    });
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

    const creates = try registry.SDK.dispatch(&system, List, .{
        .operation = "record.create",
    });
    try std.testing.expectEqual(@as(usize, 1), creates.entries.len);

    const failed = try registry.SDK.dispatch(&system, errors.List, .{});
    try std.testing.expectEqual(@as(usize, 2), failed.entries.len);
    try std.testing.expectEqualStrings("Denied", failed.entries[0].@"error");
    try std.testing.expectEqualStrings("activity.list", failed.entries[0].operation);
    try std.testing.expectEqualStrings("record.create", failed.entries[1].operation);
}

test {
    _ = @import("activity/tracker_tests.zig");
    _ = @import("activity/units_tests.zig");
}
