//! What a modifier's plugin calls when the data its answer follows changed:
//! `ctx.call(publr.mod_changed, .{ .name = "money.currencies" })` (core's `mod.changed`), and
//! what was built with the values applied under `name` is built again.

pub const Changed = @import("operations/mod.zig").Changed;
