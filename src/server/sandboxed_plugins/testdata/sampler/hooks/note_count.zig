const publr = @import("publr");
const std = @import("std");

const User = publr.operations.user;

/// Shows how many notes each person kept, beside them in People
pub fn run(ctx: *publr.Ctx, _: *User.List.In, out: *const User.List.Out) publr.Error!void {
    std.debug.assert(out.users.len <= 200);

    if (out.users.len == 0) {
        return;
    }

    // One read for the whole page, counted per person.
    const notes = try ctx.call(publr.operations.record.List, .{
        .type = "sampler.sample_note",
        .limit = 200,
    });

    for (out.users) |user| {
        var count: u32 = 0;

        for (notes.records) |note| {
            if (std.mem.eql(u8, note.created_by orelse "", user.id)) {
                count += 1;
            }
        }

        try out.extend(user, "sampler.notes", count);
    }
}
