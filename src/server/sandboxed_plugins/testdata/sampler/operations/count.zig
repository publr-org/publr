//! How many notes the sampler keeps.
//!
//! Shown beside the sampler's page in the top bar, for whoever may read the notes.
//!
//! Example:
//!   in: {}
//!   out: { "count": 1 }
const publr = @import("publr");
const std = @import("std");

const Notes = @import("../records/notes.zig");

pub const In = struct {};

pub const Out = struct {
    /// How many notes there are
    count: i64,
};

fn run(ctx: *publr.Ctx, _: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    const all = try Notes.typed.find(ctx, .{}, .{
        .limit = 200,
    });

    std.debug.assert(all.len <= 200);

    return .{
        .count = @intCast(all.len),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "count",
    .kind = .read,
    .run = run,
});
