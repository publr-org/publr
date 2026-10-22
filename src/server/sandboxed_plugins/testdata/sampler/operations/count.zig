//! How many notes the sampler keeps.
//!
//! Shown beside the sampler's page in the top bar, for whoever may read the notes.
//!
//! Example:
//!   in: {}
//!   out: { "count": 1 }
const publr = @import("publr");
const std = @import("std");

/// The notes counted: `count(*[_type == "sampler.sample_note"])`.
const notes = publr.query.prepare(@embedFile("../queries/notes.groq"), .{});

pub const In = struct {};

pub const Out = struct {
    /// How many notes there are
    count: i64,
};

fn run(ctx: *publr.Ctx, _: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    const all = try notes.execute(ctx, i64, .{});

    std.debug.assert(all >= 0);

    return .{
        .count = all,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "count",
    .kind = .read,
    .run = run,
});
