const publr = @import("publr");
const std = @import("std");
const Baskets = @import("../records/baskets.zig");

const Sized = publr.Computed(Baskets.Basket, Baskets.Size);

/// Adds a bonus to every basket's size as it is worked out, for the tests
pub fn run(ctx: *publr.Ctx, value: *Sized) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);
    std.debug.assert(value.id.len > 0);

    value.value.bonus = value.value.letters + 3;
}
