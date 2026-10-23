const publr = @import("publr");
const std = @import("std");

const Notes = @import("../records/notes.zig");

fn run(ctx: *publr.QueueCtx, note: Notes.record.Held) publr.Error!void {
    std.debug.assert(note.id.len > 0);
    std.debug.assert(ctx.now().ms >= 0);

    ctx.log(.info, "job remind: {s} is due", .{note.value.note});
}

/// Half an hour before a note's reminder time: queued by every write to the note, run with
/// the note as it is then.
pub const job = publr.job.define(Notes.record, .{
    .name = "remind",
    .run = run,
    .due = .{
        .field = .remind_at,
        .before = .{
            .minutes = 30,
        },
    },
});
