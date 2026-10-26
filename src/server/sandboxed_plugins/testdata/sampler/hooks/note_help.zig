const publr = @import("publr");
const std = @import("std");

const Notes = @import("../records/notes.zig");

/// Says under a sample note how much of it is written, as it is typed
pub fn run(ctx: *publr.Ctx, item: *publr.FieldHelp(Notes.SampleNote)) publr.Error!void {
    std.debug.assert(item.field.len > 0);
    std.debug.assert(item.record.note.len <= 1 << 16);

    item.help = try ctx.print("{d} characters so far.", .{item.record.note.len});
}
