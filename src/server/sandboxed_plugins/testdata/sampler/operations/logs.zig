//! The lines the notes' events left.
//!
//! Example:
//!   in: {}
//!   out: { "lines": ["noted HELLO"] }
const publr = @import("publr");
const std = @import("std");

const Logs = @import("../records/logs.zig");

pub const In = struct {};

pub const Out = struct {
    /// Each line, in order
    lines: []const []const u8,
};

/// Every line of the log, sorted: the page draws them too.
pub fn lines_of(ctx: *publr.Ctx) publr.Error![]const []const u8 {
    std.debug.assert(ctx.now().ms >= 0);

    const all = try Logs.typed.find(ctx, .{}, .{
        .limit = 200,
    });
    const lines = try ctx.alloc([]const u8, @intCast(all.len));

    std.debug.assert(all.len <= 200);

    for (all, lines) |item, *line| {
        line.* = item.value.line;
    }

    std.mem.sort([]const u8, lines, {}, before);

    return lines;
}

fn before(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn run(ctx: *publr.Ctx, _: In) publr.Error!Out {
    const lines = try lines_of(ctx);

    std.debug.assert(lines.len <= 200);

    return .{
        .lines = lines,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "logs",
    .kind = .read,
    .run = run,
});
