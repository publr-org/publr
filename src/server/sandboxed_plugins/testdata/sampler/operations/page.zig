//! Draws the sampler's page: the log, drawn by its own view.
//!
//! The same view either way the sampler runs: compiled in it draws in the process, installed
//! the host draws each design-system component it reaches.
//!
//! Example:
//!   in: {}
//!   out: { "html": "<!doctype html>" }
const publr = @import("publr");
const std = @import("std");

const Logs = @import("logs.zig");

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

    std.debug.assert(lines.len <= 200);

    return .{
        .html = try publr.views.render(ctx, in.base, publr.views.all.SamplerLog, .{
            .lines = lines,
        }),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "page",
    .kind = .read,
    .run = run,
});
