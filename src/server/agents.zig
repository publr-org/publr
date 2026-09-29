//! `publr agents`: the guide for an agent building on Publr (`docs/agents.md`, built into
//! the binary so it always describes this Publr), then what only this machine and this
//! build know: where the SDK's source is, and every permission a plugin may ask for.
const std = @import("std");
const toolchain = @import("toolchain.zig");
const permission = @import("../model/permission.zig");

const guide = @embedFile("agents_guide");

pub fn run(init: std.process.Init, out: *std.Io.Writer) !u8 {
    std.debug.assert(guide.len > 0);
    std.debug.assert(permission.core.len > 0);

    try out.writeAll(guide);
    try out.writeAll("\n## On this machine\n\n");

    if (toolchain.unpack(init)) |tools| {
        try out.print("The SDK's source: `{s}/src`.\n", .{tools.sdk});
    } else |err| {
        try out.print("The SDK's source is not available here ({t}).\n", .{err});
    }

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
