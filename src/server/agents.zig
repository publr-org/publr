//! `publr agents`: the guide for an agent building on Publr (`docs/agents.md`, built into
//! the binary so it always describes this Publr), then what only this machine and this
//! build know: where the SDK's source is, and every permission a plugin may ask for.
const std = @import("std");
const permission = @import("../model/permission.zig");
const operator = @import("operator.zig");

pub const guide = @embedFile("agents_guide");

pub fn run(init: std.process.Init, out: *std.Io.Writer, db_path: []const u8) !u8 {
    std.debug.assert(guide.len > 0);
    std.debug.assert(permission.core.len > 0);

    try out.writeAll(guide);
    try out.writeAll("\n## On this machine\n\n");

    // What `serve` left beside the database, while it answers.
    if (try operator.find(init.io, init.arena.allocator(), db_path)) |session| {
        const url = if (session.url.len > 0) session.url else "http://127.0.0.1";

        try out.print("This project's server runs at {s} (port {d}); every command run " ++
            "from this folder goes to it.\n\n", .{ url, session.port });
    } else {
        try out.writeAll("No server runs for this project: start it with `publr serve`, " ++
            "and it prints its address.\n\n");
    }

    try out.writeAll("The SDK's source: `publr plugin sdk --out <folder>` writes it out.\n");

    try out.writeAll("\n## Permissions\n\n| Key | Tier | What the administrator reads |" ++
        " Operations |\n|---|---|---|---|\n");

    for (permission.core) |item| {
        try out.print("| `{s}` | {t} | {s} | ", .{ item.key, item.tier, item.sentence });

        for (item.operations, 0..) |operation, index| {
            try out.print("{s}`{s}`", .{ if (index == 0) "" else ", ", operation });
        }

        try out.writeAll(" |\n");
    }

    return 0;
}
