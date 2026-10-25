//! The site's variants, from the plugin that declares the dimension: what the admin offers a
//! switch between and the site serves pages for. None without such a plugin. Read as the
//! system: the list says how the site is built, not what a caller may see.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const dimension_module = @import("../sdk/plugin/variants.zig");
const model_variant = @import("../model/dimension.zig");

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

/// `name`'s key in the declared dimension's `code`: `title@language=pl`; `name` alone for the
/// main value, or on a site that declares none.
pub fn key_in(
    ctx: *const Ctx,
    name: []const u8,
    code: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(code.len <= model_variant.code_len_max);

    const dimension = setting(ctx) orelse return name;

    return model_variant.key_of(ctx.arena, name, &.{.{
        .dimension = dimension.name,
        .code = code,
    }});
}

/// The declared dimension's code `key` is in (`title@language=pl` gives `pl`); empty for a
/// main value, another dimension's, or a site that declares none.
pub fn code_in(ctx: *const Ctx, key: []const u8) []const u8 {
    std.debug.assert(key.len > 0);

    const dimension = setting(ctx) orelse return "";
    const combination = model_variant.parse(model_variant.split(key).combination) orelse {
        return "";
    };

    std.debug.assert(combination.len <= model_variant.dimensions_max);

    return combination.code_of(dimension.name);
}

/// What the admin shows of the dimension: the field setting, the picker, the type setting
/// for untranslated records.
pub const Setting = struct {
    /// The dimension's name: `language`.
    name: []const u8,
    priority: i32,
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
            .name = dimension.name,
            .priority = dimension.priority,
            .label = dimension.label,
            .help = dimension.help,
            .picker = dimension.picker,
            .untranslated = dimension.untranslated,
        };
    }

    const declared = installed(ctx) orelse return null;

    return .{
        .name = declared.name,
        .priority = declared.priority,
        .label = declared.label,
        .help = declared.help,
        .picker = declared.picker,
        .untranslated = declared.untranslated,
    };
}
