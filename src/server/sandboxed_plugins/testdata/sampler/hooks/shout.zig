const publr = @import("publr");
const std = @import("std");

const Note = @import("../operations/note.zig");

/// Keeps every note in capitals
pub fn run(ctx: *publr.Ctx, in: *Note.In) publr.Error!void {
    std.debug.assert(in.note.len <= 280);

    const upper = try ctx.alloc(u8, @intCast(in.note.len));

    in.note = std.ascii.upperString(upper, in.note);
    ctx.log(.info, "before sampler.note: the note is now {s}", .{in.note});
}
