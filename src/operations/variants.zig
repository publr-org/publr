//! The site's variants, from the plugin that declares the dimension: what the admin offers a
//! switch between and the site serves pages for. None without such a plugin. Read as the
//! system: the list says how the site is built, not what a caller may see.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const dimension_module = @import("../sdk/plugin/variants.zig");
const model_variant = @import("../model/variant.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const Variant = dimension_module.Variant;
pub const variants_max = dimension_module.variants_max;

/// Every variant, the main one first; empty when no plugin declares the dimension. A
/// compiled-in plugin's list is called directly; an installed one's by its name.
pub fn listed(ctx: *Ctx) Error![]const Variant {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(variants_max > 1);

    // As the system, on the request's own context: a copy would set aside a scratch of its
    // own on every call.
    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    const answered = if (registry.variants) |dimension|
        (try registry.SDK.dispatch(ctx, dimension.list, .{})).variants
    else if (installed(ctx)) |declared|
        try installed_list(ctx, declared.list)
    else
        return &.{};

    if (answered.len > variants_max) {
        return error.Invalid;
    }

    return answered;
}

/// The dimension an installed plugin declares, when one does.
fn installed(ctx: *const Ctx) ?model_variant.Declared {
    std.debug.assert(variants_max > 1);

    const sandboxed = ctx.sandboxed_plugins orelse return null;

    for (sandboxed.manifests()) |manifest| {
        if (manifest.variants) |declared| {
            return declared;
        }
    }

    return null;
}

fn installed_list(ctx: *Ctx, operation: []const u8) Error![]const Variant {
    std.debug.assert(operation.len > 0);

    const Answer = struct {
        variants: []const Variant = &.{},
    };
    const json = try registry.SDK.call_json(ctx, operation, "{}");
    const answer = std.json.parseFromSliceLeaky(Answer, ctx.arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.Invalid;

    return answer.variants;
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

/// What the admin shows of the dimension: the field setting, the picker, the type setting
/// for untranslated records.
pub const Setting = struct {
    label: []const u8,
    help: []const u8,
    picker: []const u8,
    untranslated: model_variant.Untranslated,
};

/// The dimension's settings, when a plugin, compiled in or installed, declares one.
pub fn setting(ctx: *const Ctx) ?Setting {
    std.debug.assert(variants_max > 1);

    if (registry.variants) |dimension| {
        return .{
            .label = dimension.label,
            .help = dimension.help,
            .picker = dimension.picker,
            .untranslated = dimension.untranslated,
        };
    }

    const declared = installed(ctx) orelse return null;

    return .{
        .label = declared.label,
        .help = declared.help,
        .picker = declared.picker,
        .untranslated = declared.untranslated,
    };
}
