//! The two logs, read only, reached from the ⋯ menu beside System settings' tabs:
//! Activity log and Error log, newest first, a page at a time (`?before=<id>`).

const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const time = @import("../../lib/time.zig");
const activity = @import("../../operations/activity.zig");
const errors = @import("../../operations/errors.zig");
const settings_nav = @import("settings_nav.zig");

const views = admin.views;
const Entry = views.Activity.EntriesItem;
const page_size: u32 = 50;
const activity_path = "/admin/settings/system/activity";
const errors_path = "/admin/settings/system/errors";

pub fn show_activity(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const before = before_of(request.query());
    const listed = registry.SDK.dispatch(&session.ctx, activity.List, .{
        .before = before,
        .limit = page_size,
    }) catch |err| return admin.fail(&session, err, "/admin/settings");
    const entries = try session.arena.alloc(Entry, listed.entries.len);

    for (listed.entries, entries) |item, *entry| {
        entry.* = .{
            .date = (try when_of(session.arena, item.at)).date,
            .time = (try when_of(session.arena, item.at)).time,
            .who = item.actor,
            .operation = item.operation,
            .what = try changed_text(session.arena, item.units, item.calls),
            .input = item.input,
            .json = try json_of(session.arena, item),
        };
    }

    const oldest = if (listed.entries.len == page_size) listed.entries[page_size - 1].id else 0;

    try render(&session, "activity", entries, try older(session.arena, activity_path, oldest));
}

pub fn show_errors(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, errors.List, .{
        .before = before_of(request.query()),
        .limit = page_size,
    }) catch |err| return admin.fail(&session, err, "/admin/settings");
    const entries = try session.arena.alloc(Entry, listed.entries.len);

    for (listed.entries, entries) |item, *entry| {
        const from = if (item.failed_in.len > 0)
            try std.fmt.allocPrint(session.arena, " (in {s})", .{item.failed_in})
        else
            "";
        const said = if (item.message.len > 0)
            try std.fmt.allocPrint(session.arena, ": {s}", .{item.message})
        else
            "";

        entry.* = .{
            .date = (try when_of(session.arena, item.at)).date,
            .time = (try when_of(session.arena, item.at)).time,
            .who = item.actor,
            .operation = item.operation,
            .what = try std.fmt.allocPrint(session.arena, "{s}{s}{s}", .{
                item.@"error",
                from,
                said,
            }),
            .input = item.input,
            .json = try json_of(session.arena, item),
        };
    }

    const oldest = if (listed.entries.len == page_size) listed.entries[page_size - 1].id else 0;

    try render(&session, "errors", entries, try older(session.arena, errors_path, oldest));
}

fn render(
    session: *admin.Session,
    tab: []const u8,
    entries: []const Entry,
    older_href: []const u8,
) admin.Error!void {
    std.debug.assert(tab.len > 0);
    std.debug.assert(session.signed_in());

    const shell = admin.shell_of(session);

    try admin.render.page(session.response, session.arena, .ok, views.Activity, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(session, "system"),
        .tab = tab,
        .entries = entries,
        .older_href = older_href,
    });
}

/// `record:7f…, plugin:cart; set off record.save`.
fn changed_text(
    arena: std.mem.Allocator,
    units: []const []const u8,
    calls: []const []const u8,
) admin.Error![]const u8 {
    std.debug.assert(units.len <= 4096);

    const changed = try std.mem.join(arena, ", ", units);

    if (calls.len == 0) {
        return changed;
    }

    const set_off = try std.mem.join(arena, ", ", calls);
    const gap = if (changed.len > 0) "; " else "";

    return std.fmt.allocPrint(arena, "{s}{s}set off {s}", .{ changed, gap, set_off });
}

/// The whole entry as indented JSON, its input shown as the object it is.
fn json_of(arena: std.mem.Allocator, item: anytype) admin.Error![]const u8 {
    std.debug.assert(item.operation.len > 0);

    var shown: std.json.ObjectMap = .empty;
    const fields = @typeInfo(@TypeOf(item)).@"struct".fields;

    inline for (fields) |field| {
        const value = @field(item, field.name);
        const as_json: std.json.Value = if (comptime std.mem.eql(u8, field.name, "input"))
            std.json.parseFromSliceLeaky(std.json.Value, arena, value, .{}) catch .{
                .string = value,
            }
        else
            try value_of(arena, value);

        try shown.put(arena, field.name, as_json);
    }

    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = shown }, .{
        .whitespace = .indent_2,
    });
}

fn value_of(arena: std.mem.Allocator, value: anytype) admin.Error!std.json.Value {
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});

    std.debug.assert(text.len > 0);

    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch .null;
}

const When = struct { date: []const u8, time: []const u8 };

/// The day and the time of day, UTC, from one stored moment.
fn when_of(arena: std.mem.Allocator, at: i64) admin.Error!When {
    std.debug.assert(at >= 0);

    const text = time.datetime_text(arena, at) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .date = "", .time = "" },
    };
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return .{ .date = text, .time = "" };

    return .{ .date = text[0..space], .time = text[space + 1 ..] };
}

/// `before=<id>` from the query, the page asked for.
fn before_of(query: []const u8) ?i64 {
    std.debug.assert(query.len <= 1 << 16);

    const prefix = "before=";

    if (!std.mem.startsWith(u8, query, prefix)) {
        return null;
    }

    return std.fmt.parseInt(i64, query[prefix.len..], 10) catch null;
}

fn older(arena: std.mem.Allocator, path: []const u8, oldest: i64) admin.Error![]const u8 {
    std.debug.assert(path.len > 0);

    if (oldest == 0) {
        return "";
    }

    return std.fmt.allocPrint(arena, "{s}?before={d}", .{ path, oldest });
}

test "activity pages: what was done and what was refused, read only" {
    const sdk = @import("../../sdk.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const users = @import("../../operations/user.zig");
    _ = try registry.SDK.dispatch(&system, users.Create, .{
        .email = "bob@example.com",
        .display_name = "Bob",
        .password = "hunter2hunter2",
    });
    const refused = registry.SDK.dispatch(&system, users.Create, .{
        .email = "not an email",
        .display_name = "Nobody",
    });
    try std.testing.expect(std.meta.isError(refused));

    const done = try flow.call("GET", activity_path, "");
    try std.testing.expectEqual(.ok, done.status);
    try std.testing.expect(std.mem.indexOf(u8, done.body, "bob@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, done.body, "hunter2") == null);

    const failed = try flow.call("GET", errors_path, "");
    try std.testing.expectEqual(.ok, failed.status);
    try std.testing.expect(std.mem.indexOf(u8, failed.body, "not an email") != null);
}
