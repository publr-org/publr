const publr = @import("publr");
const std = @import("std");

const Reviews = @import("../records/reviews.zig");

pub const In = struct {
    /// The note to write
    note: []const u8,
};

fn run(ctx: *publr.QueueCtx, in: In) publr.Error!void {
    std.debug.assert(in.note.len <= 4096);
    std.debug.assert(ctx.now().ms >= 0);

    _ = try Reviews.record.create(ctx, .{
        .text = in.note,
    });
    ctx.log(.info, "job write_note: wrote the draft review {s}", .{in.note});
}

/// Writes a note the sampler was asked to keep for later, as a review.
pub const job = publr.job.define(In, .{
    .name = "write_note",
    .run = run,
});
