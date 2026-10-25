//! The site's dimensions, from the plugins that declare them (compiled in or installed),
//! highest priority first: what the admin offers a picker for and the site reads pages in.
//! None without such a plugin. One of them may have pages of its own under its values'
//! addresses (`addresses`, a language): `setting` and the lists below are that one's, else
//! the highest priority one's. Read as the system: a list says how the site is built, not
//! what a caller may see.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const dimension_module = @import("../sdk/plugin/dimensions.zig");
const model_dimension = @import("../model/dimension.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const Value = dimension_module.Value;
pub const values_max = dimension_module.values_max;

/// A dimension as the core uses it: its words, and its list by full name.
pub const Setting = model_dimension.Declared;

/// The compiled-in plugins' dimensions, as data.
const compiled = blk: {
    var out: []const Setting = &.{};

    for (registry.dimensions) |dimension| {
        out = out ++ &[_]Setting{.{
            .name = dimension.name,
            .param = dimension.param,
            .priority = dimension.priority,
            .addresses = dimension.addresses,
            .label = dimension.label,
            .help = dimension.help,
            .picker = dimension.picker,
            .list = dimension.list.name,
            .untranslated = dimension.untranslated,
            .required = dimension.required,
            .required_label = dimension.required_label,
        }};
    }

    break :blk out;
};

/// Every dimension the site has, highest priority first (declared order among equals): the
/// compiled-in plugins', then the installed ones' whose names are not taken, at most 64.
pub fn all(ctx: *const Ctx) []const Setting {
    std.debug.assert(compiled.len <= model_dimension.dimensions_max);

    var found: [model_dimension.dimensions_max]Setting = undefined;
    var len: u32 = 0;

    for (compiled) |dimension| {
        found[len] = dimension;
        len += 1;
    }

    if (ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            for (manifest.dimensions) |dimension| {
                if (len == model_dimension.dimensions_max or named(found[0..len], dimension.name)) {
                    continue;
                }

                found[len] = dimension;
                len += 1;
            }
        }
    }

    sort(found[0..len]);

    const out = ctx.arena.dupe(Setting, found[0..len]) catch return &.{};

    return out;
}

fn named(dimensions: []const Setting, name: []const u8) bool {
    std.debug.assert(dimensions.len <= model_dimension.dimensions_max);

    for (dimensions) |dimension| {
        if (std.mem.eql(u8, dimension.name, name)) {
            return true;
        }
    }

    return false;
}

/// Highest priority first; stable, so equals keep the order they were declared in.
fn sort(dimensions: []Setting) void {
    std.debug.assert(dimensions.len <= model_dimension.dimensions_max);

    if (dimensions.len < 2) {
        return;
    }

    for (1..dimensions.len) |index| {
        var at = index;
        const moving = dimensions[index];

        while (at > 0 and dimensions[at - 1].priority < moving.priority) {
            dimensions[at] = dimensions[at - 1];
            at -= 1;
        }

        dimensions[at] = moving;
    }
}

/// The dimension named `name`, if the site has it.
pub fn find(ctx: *const Ctx, name: []const u8) ?Setting {
    std.debug.assert(name.len > 0);

    for (all(ctx)) |dimension| {
        if (std.mem.eql(u8, dimension.name, name)) {
            return dimension;
        }
    }

    return null;
}

/// The dimension with pages of its own, else the highest priority one: the one the site's
/// addresses, the editor's language switch and the type's untranslated setting follow.
pub fn setting(ctx: *const Ctx) ?Setting {
    std.debug.assert(values_max > 1);

    const every = all(ctx);

    for (every) |dimension| {
        if (dimension.addresses) {
            return dimension;
        }
    }

    return if (every.len > 0) every[0] else null;
}

/// `dimension`'s values, the main one first.
pub fn values_of(ctx: *Ctx, dimension: Setting) Error![]const Value {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(dimension.list.len > 0);

    // As the system, on the request's own context: a copy would set aside a scratch of its
    // own on every call.
    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    const Answer = struct {
        values: []const Value = &.{},
    };
    const json = try registry.SDK.call_json(ctx, dimension.list, "{}");
    const answer = std.json.parseFromSliceLeaky(Answer, ctx.arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.Invalid;

    if (answer.values.len > values_max) {
        return error.Invalid;
    }

    return answer.values;
}

/// The values of `setting`'s dimension, the main one first; empty without one.
pub fn listed(ctx: *Ctx) Error![]const Value {
    std.debug.assert(ctx.now_ms >= 0);

    const dimension = setting(ctx) orelse return &.{};

    return values_of(ctx, dimension);
}

/// Its values other than the main one: the codes fields hold values under. Empty while it
/// has one value, so nothing about it shows.
pub fn others(ctx: *Ctx) Error![]const Value {
    std.debug.assert(ctx.now_ms >= 0);

    const every = try listed(ctx);
    var rest: std.ArrayList(Value) = .empty;

    for (every) |value| {
        if (!value.main) {
            rest.append(ctx.arena, value) catch return error.OutOfMemory;
        }
    }

    std.debug.assert(rest.items.len <= every.len);

    return rest.items;
}

/// Its main value, if the site has the dimension at all.
pub fn main(ctx: *Ctx) Error!?Value {
    std.debug.assert(ctx.now_ms >= 0);

    for (try listed(ctx)) |value| {
        if (value.main) {
            return value;
        }
    }

    return null;
}

/// A page's combination: `setting`'s dimension at `code` (the address's language), then
/// `chosen` (what request hooks chose), in the site's priority order.
pub fn page_pairs(
    ctx: *const Ctx,
    code: []const u8,
    chosen: []const model_dimension.Pair,
) []const model_dimension.Pair {
    std.debug.assert(chosen.len <= model_dimension.dimensions_max);

    const addressed = if (code.len > 0) asked_in(ctx, code).pairs else &.{};
    var out: std.ArrayList(model_dimension.Pair) = .empty;

    for (all(ctx)) |dimension| {
        for ([_][]const model_dimension.Pair{ addressed, chosen }) |given| {
            for (given) |pair| {
                if (std.mem.eql(u8, pair.dimension, dimension.name)) {
                    out.append(ctx.arena, pair) catch return &.{};
                }
            }
        }
    }

    std.debug.assert(out.items.len <= model_dimension.dimensions_max * 2);

    return out.items;
}

/// A read in `setting`'s dimension at `code` (the language of a page): nothing asked on a
/// site with no dimension.
pub fn asked_in(ctx: *const Ctx, code: []const u8) sdk.Dimensions {
    std.debug.assert(code.len <= model_dimension.code_len_max);

    const dimension = setting(ctx) orelse return .{};
    const one = ctx.arena.alloc(model_dimension.Pair, 1) catch return .{};

    std.debug.assert(dimension.name.len > 0);
    one[0] = .{
        .dimension = dimension.name,
        .code = code,
    };

    return .{
        .pairs = one,
    };
}

/// `name`'s key in `setting`'s dimension at `code`: `title@language=pl`; `name` alone for
/// the main value, or on a site with none.
pub fn key_in(
    ctx: *const Ctx,
    name: []const u8,
    code: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(code.len <= model_dimension.code_len_max);

    const dimension = setting(ctx) orelse return name;

    return model_dimension.key_of(ctx.arena, name, &.{.{
        .dimension = dimension.name,
        .code = code,
    }});
}

/// `setting`'s dimension's code `key` is in (`title@language=pl` gives `pl`); empty for a
/// main value, another dimension's, or a site with none.
pub fn code_in(ctx: *const Ctx, key: []const u8) []const u8 {
    std.debug.assert(key.len > 0);

    const dimension = setting(ctx) orelse return "";
    const combination = model_dimension.parse(model_dimension.split(key).combination) orelse {
        return "";
    };

    std.debug.assert(combination.len <= model_dimension.dimensions_max);

    return combination.code_of(dimension.name);
}

/// Whether a field must hold a value of its own at `value` before its record goes live:
/// what the field says, else the type, else the value, else its dimension. The main value is
/// the field's own `required`, never this.
pub fn required(
    dimension: Setting,
    value: Value,
    type_def: @import("../model/content_type.zig").Def,
    field: @import("../model/field.zig").Def,
) bool {
    std.debug.assert(dimension.name.len > 0);
    std.debug.assert(field.name.len > 0);

    const lists = model_dimension.lists;

    if (value.main or !model_dimension.varies_by(field.dimensions, dimension.name)) {
        return false;
    }

    if (lists(field.optional_in, dimension.name)) {
        return false;
    }

    if (lists(field.required_in, dimension.name)) {
        return true;
    }

    if (lists(type_def.optional_in, dimension.name)) {
        return false;
    }

    if (lists(type_def.required_in, dimension.name)) {
        return true;
    }

    return value.required orelse dimension.required;
}

/// One value a field must hold: `language` at `pl`, called `Polski`.
pub const Required = struct {
    dimension: []const u8,
    code: []const u8,
    label: []const u8,
};

/// Each value a field must hold before its record goes live, in the site's dimension order.
pub fn required_of(
    ctx: *Ctx,
    type_def: @import("../model/content_type.zig").Def,
    field: @import("../model/field.zig").Def,
) Error![]const Required {
    std.debug.assert(field.name.len > 0);
    std.debug.assert(field.dimensions.len <= model_dimension.dimensions_max + 1);

    var out: std.ArrayList(Required) = .empty;

    if (field.dimensions.len == 0) {
        return out.items;
    }

    for (all(ctx)) |dimension| {
        if (!model_dimension.varies_by(field.dimensions, dimension.name)) {
            continue;
        }

        for (try values_of(ctx, dimension)) |value| {
            if (required(dimension, value, type_def, field)) {
                try out.append(ctx.arena, .{
                    .dimension = dimension.name,
                    .code = value.code,
                    .label = value.label,
                });
            }
        }
    }

    return out.items;
}

test "required: the field over the type over the value over the dimension" {
    const language: Setting = .{
        .name = "language",
        .label = "Translate",
        .help = "A value in each language.",
        .list = "languages.list",
    };
    const polish: Value = .{
        .code = "pl",
        .label = "Polski",
    };
    const body: @import("../model/field.zig").Def = .{
        .name = "body",
        .label = "Body",
        .kind = "text",
        .dimensions = &.{"language"},
    };
    const promo: @import("../model/content_type.zig").Def = .{
        .handle = "promo",
        .name = "Promo",
        .fields = &.{body},
    };

    try std.testing.expect(!required(language, polish, promo, body));

    var all_required = language;

    all_required.required = true;
    try std.testing.expect(required(all_required, polish, promo, body));

    var not_polish = polish;

    not_polish.required = false;
    try std.testing.expect(!required(all_required, not_polish, promo, body));

    var lenient = promo;

    lenient.optional_in = &.{"language"};

    var strict_body = body;

    strict_body.required_in = &.{"language"};
    try std.testing.expect(!required(all_required, polish, lenient, body));
    try std.testing.expect(required(language, polish, lenient, strict_body));

    var english = polish;

    english.main = true;
    try std.testing.expect(!required(all_required, english, promo, strict_body));
}
