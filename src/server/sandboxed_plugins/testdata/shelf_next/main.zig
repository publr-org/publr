//! Items on a shelf, 0.2.0: items have numbered codes instead of SKUs, and it no longer counts.
//!
//! The next version of `shelf`, uploaded as its update: `shelf.item` has no `sku` (a number,
//! `code`, instead), `shelf count` is gone, `shelf.restocked` carries the number, and a
//! bin's `count` is text ("about 20").
//! `labels`, which needs `sku`, can't run with it; `stocktake` keeps working with what still
//! fits.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "shelf",
    .version = "0.2.0",
};

/// Item
///
/// One thing on the shelf.
pub const Item = struct {
    /// Title
    title: []const u8,
    /// Code
    code: u32 = 0,
    /// Note
    note: []const u8 = "",
};

pub const Items = publr.record.define(Item, .{
    .name = "shelf.item",
    .title_field = .title,
});

/// How many of an item one bin holds, in words now.
pub const Bin = struct {
    item: []const u8,
    count: []const u8,
};

pub const Bins = publr.record.define(Bin, .{
    .name = "shelf.bin",
    .internal = true,
});

pub const Restocked = publr.event.define(.{
    .name = "restocked",
    .payload = struct {
        /// The SKU back in stock
        sku: u32,
    },
});

pub const RestockIn = struct {
    /// The SKU back in stock
    sku: u32,
};

pub const RestockOut = struct {
    /// Whether the event went out
    told: bool,
};

/// Says an item is back in stock: emits `shelf.restocked`.
///
/// Example:
///   in: { "sku": 1 }
///   out: { "told": true }
pub const Restock = publr.operation.define(RestockIn, RestockOut, .{
    .name = "restock",
    .kind = .write,
    .run = restock,
});

fn restock(ctx: *publr.Ctx, in: RestockIn) publr.Error!RestockOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.sku == 0) {
        return error.Invalid;
    }

    ctx.emit(Restocked, .{
        .sku = in.sku,
    });

    return .{
        .told = true,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{ Items, Bins },
    .operations = &.{Restock},
    .events = &.{Restocked},
});
