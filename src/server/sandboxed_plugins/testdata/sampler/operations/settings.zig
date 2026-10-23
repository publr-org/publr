//! Draws Settings › Sampler: the log and the port `serve` got.
//!
//! Compiled in only: the port is the sampler's process state, which an installed plugin has
//! not.
//!
//! Example:
//!   in: {}
//!   out: { "html": "<!doctype html>" }
const publr = @import("publr");
const std = @import("std");

const Logs = @import("logs.zig");
const Sampler = @import("../main.zig");

pub const In = struct {
    /// The address's query string
    query: []const u8 = "",
    /// The path the project is served under
    base: []const u8 = "",
};

pub const Out = struct {
    /// The page's markup
    html: []const u8,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.query.len <= 4096);

    const lines = try Logs.lines_of(ctx);
    const port = publr.plugin_states.of(ctx.inner, Sampler).port;

    std.debug.assert(lines.len <= 200);

    return .{
        .html = try publr.views.render(ctx, in.base, publr.views.all.SamplerSettings, .{
            .lines = lines,
            .port = try std.fmt.allocPrint(ctx.arena(), "{d}", .{port}),
        }),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "settings",
    .kind = .read,
    .run = run,
});
