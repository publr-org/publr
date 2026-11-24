//! shelf's own hook on its own operation, listed from this file (`kept.hooks`).
const std = @import("std");
const publr = @import("publr");
const shelf = @import("main.zig");

pub const hooks = .{
    publr.after(shelf.Restock, keep_kept),
};

/// Refuses the SKU `KEPT` once restocked: a hook of the plugin's own, on its own operation.
fn keep_kept(ctx: *publr.Ctx, in: *shelf.RestockIn, out: *const shelf.RestockOut) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);
    std.debug.assert(out.told);

    if (std.mem.eql(u8, in.sku, "KEPT")) {
        return ctx.refuse(&.{.{
            .field = "sku",
            .message = "Kept back: never restocked",
        }});
    }
}
