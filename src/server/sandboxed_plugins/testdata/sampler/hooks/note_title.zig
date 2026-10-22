const publr = @import("publr");
const std = @import("std");

const Notes = @import("../records/notes.zig");

/// Shows each sample note with its length
pub fn run(ctx: *publr.Ctx, item: *publr.Title(Notes.SampleNote)) publr.Error!void {
    std.debug.assert(item.id.len > 0);
    std.debug.assert(item.record.note.len <= 1 << 16);

    item.title = try ctx.print("Note: {s} ({d} characters)", .{
        item.title,
        item.record.note.len,
    });
}
