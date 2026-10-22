//! What one top-level call did, gathered while it runs: the calls it set off inside, the
//! events they raised, and where it failed. The core's activity and error logs are written
//! from it (`Log`, a seam the registry fills); the SDK only gathers, it stores nothing.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");

pub const calls_max: u32 = 1024;
pub const events_max: u32 = 4096;
/// The lines one call or one queued run keeps: past it, one more says how many were left out.
pub const lines_max: u32 = 100;
pub const line_bytes_max: u32 = 1024;

pub const Level = enum { info, warn, err };

/// A line a plugin logged: `ctx.log`.
pub const Line = struct {
    plugin: []const u8,
    level: Level,
    text: []const u8,
};

/// An event emitted during the call, by name, with its payload.
pub const Emitted = struct {
    name: []const u8,
    subject: []const u8,
};

/// A unit a write changed, as an `after` hook on it said (`plugin:shelf`): `at`, how many
/// events the trail held when that write started, keeps it in order among them.
pub const Changed = struct {
    at: u32,
    unit: []const u8,
};

/// A finished top-level call, as the log receives it.
pub const Entry = struct {
    operation: []const u8,
    /// The input as JSON, before any masking: the log masks it.
    input: []const u8,
    /// The input fields the operation declares secret.
    secret: []const []const u8,
    calls: []const []const u8,
    events: []const Emitted,
    units: []const Changed = &.{},
    /// Set for a refused or failed call.
    error_name: []const u8 = "",
    message: []const u8 = "",
    /// The inner operation the failure came from, when it came from one.
    failed_in: []const u8 = "",
    /// What plugins logged during the call.
    lines: []const Line = &.{},
};

/// Where finished calls go: `activity` inside a write's transaction just before it commits,
/// `failure` after a refused or rolled-back call, outside any transaction.
/// `lines`: what a call that left no entry logged (a read that answered) or what a queued
/// run logged (`call` is `job:<plugin>.<name>`), after it ends. Each answers the Error log
/// entry it wrote, if any, for `publr.errors.Failed`.
pub const Log = struct {
    activity: *const fn (*Ctx, *const Entry) operation.Error!?Logged,
    failure: *const fn (*Ctx, *const Entry) ?Logged,
    lines: *const fn (*Ctx, call: []const u8, lines: []const Line) ?Logged,
};

/// An Error log entry as `publr.errors.Failed` carries it.
pub const Logged = @import("error_events.zig").Failed.Payload;

/// What plugins logged during one top-level call (`root`, its operation id) or one queued
/// run (`root` 0), on `Ctx.lines` while it runs.
pub const Lines = struct {
    root: u64,
    /// The call's or run's arena: a line logged in an inner call is copied here.
    arena: std.mem.Allocator,
    items: std.ArrayList(Line) = .empty,
    left_out: u32 = 0,
    /// Set once the lines went with the call's activity or error entry.
    stored: bool = false,

    pub fn add(lines: *Lines, line: Line) void {
        std.debug.assert(line.plugin.len > 0);
        std.debug.assert(lines.items.items.len <= lines_max);

        if (lines.items.items.len == lines_max) {
            lines.left_out += 1;
            return;
        }

        const copy: Line = .{
            .plugin = lines.arena.dupe(u8, line.plugin) catch return,
            .level = line.level,
            .text = lines.arena.dupe(u8, cut(line.text)) catch return,
        };

        lines.items.append(lines.arena, copy) catch return;
    }

    /// The lines as stored: one more at the end when some were left out.
    pub fn kept(lines: *const Lines) []const Line {
        std.debug.assert(lines.items.items.len <= lines_max);
        std.debug.assert(lines.left_out == 0 or lines.items.items.len == lines_max);

        if (lines.left_out == 0) {
            return lines.items.items;
        }

        const last = lines.items.items[lines.items.items.len - 1];
        const said = std.fmt.allocPrint(lines.arena, "{d} more lines left out", .{
            lines.left_out,
        }) catch return lines.items.items;
        const all = lines.arena.alloc(Line, lines.items.items.len + 1) catch
            return lines.items.items;

        @memcpy(all[0..lines.items.items.len], lines.items.items);
        all[lines.items.items.len] = .{
            .plugin = last.plugin,
            .level = .warn,
            .text = said,
        };

        return all;
    }

    /// `text` up to `line_bytes_max`, never inside a character.
    fn cut(text: []const u8) []const u8 {
        if (text.len <= line_bytes_max) {
            return text;
        }

        var end: usize = line_bytes_max;

        while (end > 0 and text[end] & 0xC0 == 0x80) {
            end -= 1;
        }

        std.debug.assert(end <= line_bytes_max);

        return text[0..end];
    }
};

pub const Trail = struct {
    /// The top-level call's operation id.
    root: u64,
    /// The top-level call's arena: an inner call may run on a scratch given back before the
    /// trail is read, so what it adds is copied here.
    arena: std.mem.Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    events: std.ArrayList(Emitted) = .empty,
    units: std.ArrayList(Changed) = .empty,
    failed_in: []const u8 = "",
    message: []const u8 = "",
    /// What plugins log during the call, set when the trail opens; a queued run's own
    /// lines stand instead when the call runs inside one.
    lines: ?Lines = null,

    /// An inner call finished: kept by name, and the first failure with its message.
    pub fn called(trail: *Trail, ctx: *Ctx, name: []const u8, failed: bool) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(trail.root != 0);

        const kept = trail.arena.dupe(u8, name) catch return;

        if (trail.calls.items.len < calls_max) {
            trail.calls.append(trail.arena, kept) catch return;
        }

        if (failed and trail.failed_in.len == 0) {
            const message = if (ctx.failure) |failure| failure.message else "";

            trail.failed_in = kept;
            trail.message = trail.arena.dupe(u8, message) catch "";
        }
    }

    pub fn emitted(trail: *Trail, event: Emitted) void {
        std.debug.assert(event.name.len > 0);
        std.debug.assert(trail.root != 0);

        if (trail.events.items.len < events_max) {
            const kept: Emitted = .{
                .name = trail.arena.dupe(u8, event.name) catch return,
                .subject = trail.arena.dupe(u8, event.subject) catch return,
            };

            trail.events.append(trail.arena, kept) catch return;
        }
    }

    /// Where the next event goes: what a write starting now passes to `changed`.
    pub fn mark(trail: *const Trail) u32 {
        std.debug.assert(trail.root != 0);
        std.debug.assert(trail.events.items.len <= events_max);

        return @intCast(trail.events.items.len);
    }

    pub fn changed(trail: *Trail, at: u32, unit: []const u8) void {
        std.debug.assert(unit.len > 0);
        std.debug.assert(at <= trail.events.items.len);

        if (trail.units.items.len < events_max) {
            const kept: Changed = .{
                .at = at,
                .unit = trail.arena.dupe(u8, unit) catch return,
            };

            trail.units.append(trail.arena, kept) catch return;
        }
    }

    pub fn entry(
        trail: *const Trail,
        name: []const u8,
        input: []const u8,
        secret: []const []const u8,
    ) Entry {
        std.debug.assert(name.len > 0);
        std.debug.assert(trail.root != 0);

        return .{
            .operation = name,
            .input = input,
            .secret = secret,
            .calls = trail.calls.items,
            .events = trail.events.items,
            .units = trail.units.items,
            .failed_in = trail.failed_in,
            .message = trail.message,
        };
    }
};

/// The input fields an operation declares secret: `pub const secret = .{"password"}`.
pub fn secret_of(comptime Operation: type) []const []const u8 {
    comptime {
        if (!@hasDecl(Operation, "secret")) {
            return &.{};
        }

        var names: [Operation.secret.len][]const u8 = undefined;

        for (Operation.secret, 0..) |field, index| {
            std.debug.assert(@hasField(Operation.In, field));
            names[index] = field;
        }

        const kept = names;

        return &kept;
    }
}

test "lines: bounded per call, the rest counted, long ones cut at a character" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var lines: Lines = .{
        .root = 1,
        .arena = arena_state.allocator(),
    };
    const long = "ł" ** line_bytes_max;

    lines.add(.{
        .plugin = "shop",
        .level = .info,
        .text = long,
    });

    try std.testing.expectEqual(@as(usize, line_bytes_max), lines.items.items[0].text.len);

    for (0..lines_max + 2) |_| {
        lines.add(.{
            .plugin = "shop",
            .level = .info,
            .text = "Receipt queued",
        });
    }

    const kept = lines.kept();

    try std.testing.expectEqual(@as(usize, lines_max + 1), kept.len);
    try std.testing.expectEqualStrings("3 more lines left out", kept[lines_max].text);
}
