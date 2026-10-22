//! Prints labels for the shelf's items, by SKU.
//!
//! Needs `shelf` (`depends_on`) and reads its items' `sku` as text: with a shelf whose SKUs
//! are numbers it can't be enabled, and its page says why.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "labels",
    .version = "0.1.0",
};

/// A shelf item as labels reads it: only its SKU.
pub const ShelfItem = publr.remote.record("shelf.item", struct {
    sku: []const u8,
});

pub const FindIn = struct {
    /// The SKU to print a label for
    sku: []const u8,
};

pub const FindOut = struct {
    /// Whether an item has that SKU
    found: bool,
};

/// Finds the item a label is for.
///
/// Example:
///   in: { "sku": "A-1" }
///   out: { "found": true }
pub const Find = publr.operation.define(FindIn, FindOut, .{
    .name = "find",
    .kind = .read,
    .run = find,
});

fn find(ctx: *publr.Ctx, in: FindIn) publr.Error!FindOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.sku.len == 0 or in.sku.len > 64) {
        return error.Invalid;
    }

    const found = try ShelfItem.find_one(ctx, .sku, in.sku);

    return .{
        .found = found != null,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .depends_on = .{"shelf"},
    .remotes = &.{ShelfItem},
    .operations = &.{Find},
    .permissions = &.{.{
        .key = "records.read",
        .records = &.{"shelf.item"},
        .reason = "Reads the SKU of each item it prints a label for",
    }},
});
