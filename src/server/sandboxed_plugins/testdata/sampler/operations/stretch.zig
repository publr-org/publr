//! Work in steps, each in memory of its own.
//!
//! Every step takes `kib` KiB in a scope and gives it back when it ends, so the call holds one
//! step's memory however many steps there are; what a step carries out is copied out of it.
//! Changes nothing.
//!
//! Example:
//!   in: { "steps": 3, "kib": 64 }
//!   out: { "steps": 3, "last": "step 3 of 3" }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {
    /// How many steps to take, up to 1,000
    steps: u32,
    /// How much each step takes, in KiB, up to 1,024
    kib: u32,
};

pub const Out = struct {
    /// The steps taken
    /// Why: a count, not money
    steps: u32,
    /// What the last step said, carried out of its memory
    last: []const u8,
};

fn check(in: In, problems: *publr.Problems(In)) void {
    if (in.steps == 0 or in.steps > 1000 or in.kib == 0 or in.kib > 1024) {
        problems.add(.steps, "Take 1 to 1,000 steps of 1 to 1,024 KiB each.");
    }
}

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.steps > 0);
    std.debug.assert(in.kib > 0);

    var last: []const u8 = "";
    var taken: u32 = 0;

    while (taken < in.steps) : (taken += 1) {
        var step = ctx.scope();
        defer step.end();

        const room = try ctx.alloc(u8, in.kib << 10);

        room[0] = 1;
        room[room.len - 1] = 1;

        const said = try ctx.print("step {d} of {d}", .{ taken + 1, in.steps });

        // The memory the call had before the scope: `said` goes with the step.
        step.leave();
        last = try step.keep(said);
    }

    return .{
        .steps = taken,
        .last = last,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "stretch",
    .kind = .read,
    .validate = check,
    .run = run,
});
