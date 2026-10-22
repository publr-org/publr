const publr = @import("publr");
const std = @import("std");

/// Doubles every number sampler applies, for the tests
pub fn run(ctx: *publr.Ctx, value: *u32) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);
    std.debug.assert(value.* <= 1 << 30);

    value.* *= 2;
    ctx.log(.info, "modify sampler.*: doubled the value to {d}", .{value.*});
}
