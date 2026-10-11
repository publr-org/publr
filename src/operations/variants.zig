//! The site's variants, from the plugin that declares the dimension: what the admin offers a
//! switch between and the site serves pages for. None without such a plugin. Read as the
//! system: the list says how the site is built, not what a caller may see.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const dimension_module = @import("../sdk/plugin/variants.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const Variant = dimension_module.Variant;
pub const variants_max = dimension_module.variants_max;

/// Every variant, the main one first; empty when no plugin declares the dimension.
pub fn listed(ctx: *Ctx) Error![]const Variant {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(variants_max > 1);

    const dimension = registry.variants orelse return &.{};
    // As the system, on the request's own context: a copy would set aside a scratch of its
    // own on every call.
    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    const answered = try registry.SDK.dispatch(ctx, dimension.list, .{});

    if (answered.variants.len > variants_max) {
        return error.Invalid;
    }

    return answered.variants;
}

/// The variants other than the main one: the codes fields hold values under. Empty while the
/// site has one variant, so nothing about variants shows.
pub fn others(ctx: *Ctx) Error![]const Variant {
    std.debug.assert(ctx.now_ms >= 0);

    const all = try listed(ctx);
    var rest: std.ArrayList(Variant) = .empty;

    for (all) |variant| {
        if (!variant.main) {
            rest.append(ctx.arena, variant) catch return error.OutOfMemory;
        }
    }

    std.debug.assert(rest.items.len <= all.len);

    return rest.items;
}

/// The main variant, if the site has variants at all.
pub fn main(ctx: *Ctx) Error!?Variant {
    std.debug.assert(ctx.now_ms >= 0);

    for (try listed(ctx)) |variant| {
        if (variant.main) {
            return variant;
        }
    }

    return null;
}

/// The dimension's field setting, when a plugin declares one.
pub fn setting() ?dimension_module.Dimension {
    std.debug.assert(variants_max > 1);

    return registry.variants;
}
