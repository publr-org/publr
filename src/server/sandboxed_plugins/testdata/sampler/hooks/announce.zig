const publr = @import("publr");
const std = @import("std");

const Note = @import("../operations/note.zig");
const Noted = @import("../events/noted.zig");

/// Tells other plugins a note was kept
pub fn run(ctx: *publr.Ctx, in: *Note.In, out: *const Note.Out) publr.Error!void {
    std.debug.assert(out.total > 0);
    std.debug.assert(in.note.len > 0);

    ctx.emit(Noted.event, .{
        .note = in.note,
    });
    ctx.log(.info, "after sampler.note: emitted sampler.noted, {d} notes kept", .{out.total});
}
