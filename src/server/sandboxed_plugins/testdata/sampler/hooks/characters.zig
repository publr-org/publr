const publr = @import("publr");
const std = @import("std");

const Record = publr.operations.record;

/// Shows how long each of greeter's salutations is, beside it in its list
pub fn run(_: *publr.Ctx, _: *Record.List.In, out: *const Record.List.Out) publr.Error!void {
    std.debug.assert(out.records.len <= 1000);

    // Worked out from the page itself: no read at all.
    for (out.records) |record| {
        if (!std.mem.eql(u8, record.type, "greeter.salutation")) {
            continue;
        }

        const length = std.unicode.utf8CountCodepoints(record.title) catch record.title.len;

        try out.extend(record, "sampler.characters", length);
    }
}
