//! Queues a note to be written later, by a job.
//!
//! Example:
//!   in: { "note": "Remember" }
//!   out: { "queued": true }
const publr = @import("publr");
const std = @import("std");

const WriteNote = @import("../jobs/write_note.zig");

pub const In = struct {
    /// What the note says
    note: []const u8,
};

pub const Out = struct {
    /// Whether the job was queued
    queued: bool,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.note.len <= 4096);
    std.debug.assert(ctx.now().ms >= 0);

    try ctx.enqueue(WriteNote.job, .{
        .note = in.note,
    });

    return .{
        .queued = true,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "later",
    .kind = .write,
    .run = run,
});
