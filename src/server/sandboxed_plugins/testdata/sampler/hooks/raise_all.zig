const publr = @import("publr");
const std = @import("std");

/// Raises every size sampler applies together by one, in one call, for the tests
pub fn run(ctx: *publr.Ctx, sizes: []u32) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);
    std.debug.assert(sizes.len <= 200);

    for (sizes) |*size| {
        size.* += 1;
    }
}
