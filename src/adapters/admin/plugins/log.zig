//! A plugin's Log tab: what its code logged (`plugin.log`), newest first, a page at a time
//! (`?before=<id>`), beside its own page, built in or installed.

const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const activity_page = @import("../activity.zig");
const plugin_log = @import("../../../operations/plugin/log.zig");
const plugin_operations = @import("../../../operations/plugin.zig");

const views = admin.views;
const back = "/admin/settings/plugins";
const page_size: u32 = 50;

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = registry.SDK.dispatch(&session.ctx, plugin_operations.Get, .{
        .name = name,
    }) catch |err| return admin.fail(&session, err, back);
    const listed = registry.SDK.dispatch(&session.ctx, plugin_log.Log, .{
        .name = name,
        .before = activity_page.before_of(request.query()),
        .limit = page_size,
    }) catch |err| return admin.fail(&session, err, back);
    const lines = try session.arena.alloc(views.PluginLog.LinesItem, listed.lines.len);

    for (listed.lines, lines) |item, *line| {
        const when = try activity_page.when_of(session.arena, item.at);

        line.* = .{
            .date = when.date,
            .time = when.time,
            .level = item.level,
            .line = item.line,
            .call = item.call,
        };
    }

    const own = try std.fmt.allocPrint(session.arena, "{s}/{s}", .{ back, name });
    const log_href = try std.fmt.allocPrint(session.arena, "{s}/log", .{own});
    const oldest = if (listed.lines.len == page_size) listed.lines[page_size - 1].id else 0;

    try admin.screen(&session, .ok, views.PluginLog, .{
        .name = name,
        .summary = detail.summary,
        .overview_href = own,
        .plugins_href = if (detail.mode == .native) back ++ "/built-in" else back,
        .log_href = log_href,
        .webhooks_href = if (@import("webhooks.zig").has_webhooks(name))
            try std.fmt.allocPrint(session.arena, "{s}/webhooks", .{own})
        else
            "",
        .lines = lines,
        .older_href = try activity_page.older(session.arena, log_href, oldest),
    }, .{});
}

test "a plugin's Log tab: its lines newest first, and an unknown plugin not found" {
    const sdk = @import("../../../sdk.zig");
    const store = @import("../../../store.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{
        .inner = undefined,
    };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const unknown = try flow.call("GET", back ++ "/nobody-here/log", "");

    try std.testing.expect(unknown.status != .ok);

    // A built-in plugin's page needs one compiled in; installed ones are in `scenarios.zig`.
    if (registry.native_plugins.all.len == 0) {
        return error.SkipZigTest;
    }

    const name = registry.native_plugins.all[0].manifest.name;
    const said = [_][]const u8{ "Receipt queued", "Printer offline" };

    for (said, 0..) |line, index| {
        try store.plugin_log.append(&harness.fixture.connection, .{
            .id = 0,
            .at = 1_790_000_000_000 + @as(i64, @intCast(index)),
            .plugin = name,
            .level = if (index == 0) "info" else "err",
            .line = line,
            .call = "job:" ++ name ++ ".sync",
            .activity = 0,
            .@"error" = 0,
        });
    }

    const page = try flow.call("GET", back ++ "/" ++ name ++ "/log", "");
    const newest = std.mem.indexOf(u8, page.body, "Printer offline") orelse return error.Missing;
    const oldest = std.mem.indexOf(u8, page.body, "Receipt queued") orelse return error.Missing;

    try std.testing.expectEqual(.ok, page.status);
    try std.testing.expect(newest < oldest);

    const built_in = try flow.call("GET", back ++ "/built-in", "");

    try std.testing.expect(std.mem.indexOf(u8, built_in.body, "/" ++ name ++ "\"") != null);

    const own = try flow.call("GET", back ++ "/" ++ name, "");

    try std.testing.expectEqual(.ok, own.status);
    try std.testing.expect(std.mem.indexOf(u8, own.body, "Built in") != null);
    try std.testing.expect(std.mem.indexOf(u8, own.body, "/" ++ name ++ "/remove") == null);
}
