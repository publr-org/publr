//! Every outside request a plugin sends, a line under the call or run that sent it (a job's,
//! an event's: the plugin's Log tab): method, host, path, status, time. The path as the
//! plugin wrote it, secrets put back as `{secret:NAME}`; never the query, headers or bodies.
const std = @import("std");
const sdk = @import("../sdk.zig");
const outside = @import("../model/outside.zig");
const guards = @import("http_guard.zig");
const timed = @import("http_timed.zig");

const Ctx = sdk.Ctx;
const Level = sdk.trail.Level;

/// A request refused before it left.
pub fn refused(
    ctx: *Ctx,
    plugin: []const u8,
    method: []const u8,
    uri: std.Uri,
    refusal: outside.Refusal,
) void {
    refused_because(ctx, plugin, method, uri, refusal.text());
}

/// A request refused before it left, in words: "Supplier API key isn't set".
pub fn refused_because(
    ctx: *Ctx,
    plugin: []const u8,
    method: []const u8,
    uri: std.Uri,
    reason: []const u8,
) void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(method.len > 0 and reason.len > 0);

    const text = std.fmt.allocPrint(ctx.arena, "{s} {s}{s} refused: {s}", .{
        method,
        guards.host_text(uri),
        guards.path_text(uri),
        reason,
    }) catch return;

    add(ctx, plugin, .warn, text);
}

/// Each hop a request took: what it answered, or why it was refused or failed; the time on
/// the last.
pub fn hops(
    ctx: *Ctx,
    plugin: []const u8,
    method: []const u8,
    filling: anytype,
    trace: *const timed.Trace,
    elapsed: std.Io.Duration,
) sdk.Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(trace.count <= trace.hops.len);

    const ms: i64 = @intCast(@divTrunc(@max(0, elapsed.nanoseconds), std.time.ns_per_ms));

    for (trace.hops[0..trace.count], 0..) |hop, index| {
        const last = index + 1 == trace.count;
        const path = try filling.scrub(ctx, hop.path);
        const outcome = if (hop.refusal) |refusal|
            try std.fmt.allocPrint(ctx.arena, "refused: {s}", .{refusal.text()})
        else if (hop.status == 0)
            "did not go through"
        else
            try std.fmt.allocPrint(ctx.arena, "{d}", .{hop.status});
        const timing = if (last)
            try std.fmt.allocPrint(ctx.arena, " ({d} ms)", .{ms})
        else
            "";
        const text = try std.fmt.allocPrint(ctx.arena, "{s} {s}{s} {s}{s}", .{
            method,
            hop.host,
            path,
            outcome,
            timing,
        });
        const level: Level = if (hop.refusal != null or hop.status == 0) .warn else .info;

        add(ctx, plugin, level, text);
    }
}

/// A request given up on after `limit_ms`: no answer came in time.
pub fn gave_up(
    ctx: *Ctx,
    plugin: []const u8,
    method: []const u8,
    filling: anytype,
    limit_ms: u32,
) sdk.Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(limit_ms > 0);

    const uri = std.Uri.parse(filling.url) catch return;
    const path = try filling.scrub(ctx, guards.path_text(uri));
    const text = try std.fmt.allocPrint(ctx.arena, "{s} {s}{s} gave up after {d} ms", .{
        method,
        guards.host_text(uri),
        path,
        limit_ms,
    });

    add(ctx, plugin, .warn, text);
}

/// A request's line as written, at info.
pub fn line(ctx: *Ctx, plugin: []const u8, text: []const u8) void {
    add(ctx, plugin, .info, text);
}

/// A line under the call or run, or the server's output outside one.
fn add(ctx: *Ctx, plugin: []const u8, level: Level, text: []const u8) void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(text.len > 0);

    if (ctx.lines) |lines| {
        lines.add(.{
            .plugin = plugin,
            .level = level,
            .text = text,
        });

        return;
    }

    std.log.info("plugin {s}: {s}", .{ plugin, text });
}

test "a hop is logged with its host, path and status, a refusal as a warning, no query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx: Ctx = undefined;

    ctx.arena = arena;

    var lines: sdk.trail.Lines = .{
        .root = 0,
        .arena = arena,
    };

    ctx.lines = &lines;

    const Plain = struct {
        fn scrub(_: @This(), _: *Ctx, text: []const u8) sdk.Error![]const u8 {
            return text;
        }
    };
    var trace: timed.Trace = .{
        .arena = arena,
    };

    trace.hops[0] = .{
        .host = "api.supplier.com",
        .path = "/prices",
        .status = 302,
    };
    trace.hops[1] = .{
        .host = "elsewhere.example.org",
        .path = "/x",
        .status = 0,
        .refusal = .not_listed,
    };
    trace.count = 2;

    try hops(&ctx, "courier", "GET", Plain{}, &trace, .fromMilliseconds(12));
    try std.testing.expectEqual(@as(usize, 2), lines.items.items.len);
    const kept = lines.items.items;

    try std.testing.expectEqualStrings("GET api.supplier.com/prices 302", kept[0].text);
    try std.testing.expect(lines.items.items[1].level == .warn);
    try std.testing.expect(std.mem.endsWith(u8, lines.items.items[1].text, "(12 ms)"));

    const with_query = try std.Uri.parse("https://evil.example.org/steal?key=s3cret");

    refused(&ctx, "courier", "POST", with_query, .not_listed);
    try std.testing.expect(std.mem.indexOf(u8, lines.items.items[2].text, "s3cret") == null);
    const said = lines.items.items[2].text;

    try std.testing.expect(std.mem.startsWith(u8, said, "POST evil.example.org/steal"));
}
