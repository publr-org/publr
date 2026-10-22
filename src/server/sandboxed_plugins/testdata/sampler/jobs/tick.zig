const publr = @import("publr");
const std = @import("std");

fn run(ctx: *publr.QueueCtx) publr.Error!void {
    const now = ctx.now();

    std.debug.assert(now.ms > 0);
    std.debug.assert(now.add_days(1).ms > now.ms);
}

/// Every day at three: nothing to do, there to be listed and run.
pub const job = publr.job.define_recurring(.{
    .name = "tick",
    .run = run,
    .every = .day,
    .at = .{
        .hour = 3,
    },
});
