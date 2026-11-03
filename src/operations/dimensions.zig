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
pub const Member = dimension_module.Member;
pub const Shown = dimension_module.Shown;
pub const values_max = dimension_module.values_max;

/// A dimension as the core uses it: its words, and its list by full name.
pub const Setting = model_dimension.Declared;

/// The compiled-in plugins' dimensions, as data.
const compiled = blk: {
    var out: []const Setting = &.{};

    for (registry.dimensions) |dimension| {
        out = out ++ &[_]Setting{dimension.setting};
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
                found[len].plugin = manifest.name;
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

/// The dimension named `name`, if the site has it; a family's member (`variation-hero`) as
/// its family under the member's name, whether the owner lists it its values say.
pub fn find(ctx: *const Ctx, name: []const u8) ?Setting {
    std.debug.assert(name.len > 0);

    const family = model_dimension.family_of(name);

    for (all(ctx)) |dimension| {
        if (std.mem.eql(u8, dimension.name, name) and !dimension.each) {
            return dimension;
        }

        if (dimension.each and family.len < name.len and std.mem.eql(u8, dimension.name, family)) {
            var member = dimension;

            member.name = name;
            member.param = name;

            return member;
        }
    }

    return null;
}

/// Every dimension values are kept under, highest priority first: each family's members in
/// its place, as its owner lists them now.
pub fn expanded(ctx: *Ctx) []const Setting {
    std.debug.assert(ctx.now_ms >= 0);

    var out: std.ArrayList(Setting) = .empty;

    for (all(ctx)) |dimension| {
        if (!dimension.each) {
            out.append(ctx.arena, dimension) catch return &.{};

            continue;
        }

        const members = members_of(ctx, dimension) catch continue;

        for (members) |member| {
            const name = model_dimension.member_name(ctx.arena, dimension.name, member.name) catch {
                return &.{};
            } orelse continue;
            var one = dimension;

            one.name = name;
            one.param = name;
            one.read = .{
                .name = name,
                .label = member.label,
            };
            out.append(ctx.arena, one) catch return &.{};
        }
    }

    std.debug.assert(out.items.len <= model_dimension.dimensions_max * values_max);

    return out.items;
}

/// A dimension as one record has it: the fields it shows on there, null for every field
/// holding it.
pub const OnRecord = struct {
    setting: Setting,
    fields: ?[]const []const u8 = null,
};

/// The dimensions values of the record `id` of type `type_name` are kept under (`expanded`),
/// a member its family's `.shown` names no field of left out; `id` empty for a record not
/// made yet.
pub fn of_record(
    ctx: *Ctx,
    type_name: []const u8,
    id: []const u8,
) error{OutOfMemory}![]const OnRecord {
    std.debug.assert(ctx.now_ms >= 0);

    var out: std.ArrayList(OnRecord) = .empty;
    var asked_family: []const u8 = "";
    var shown: ?[]const Shown = null;

    for (expanded(ctx)) |dimension| {
        if (!dimension.each) {
            try out.append(ctx.arena, .{
                .setting = dimension,
            });

            continue;
        }

        const family = model_dimension.family_of(dimension.name);

        if (!std.mem.eql(u8, family, asked_family)) {
            asked_family = family;
            shown = if (type_name.len == 0)
                &.{}
            else
                shown_of(ctx, dimension, type_name, id) catch &.{};
        }

        const answered = shown orelse {
            try out.append(ctx.arena, .{
                .setting = dimension,
            });

            continue;
        };
        const member = dimension.name[family.len + 1 ..];
        var fields: std.ArrayList([]const u8) = .empty;

        for (answered) |one| {
            if (std.mem.eql(u8, one.member, member)) {
                try fields.append(ctx.arena, one.field);
            }
        }

        if (fields.items.len > 0) {
            try out.append(ctx.arena, .{
                .setting = dimension,
                .fields = fields.items,
            });
        }
    }

    return out.items;
}

/// Whether `on` shows on the field `name`.
pub fn shows_on(on: OnRecord, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const fields = on.fields orelse return true;

    return model_dimension.lists(fields, name);
}

/// A family's members as its owner lists them, each with its values.
pub fn members_of(ctx: *Ctx, family: Setting) Error![]const Member {
    std.debug.assert(family.each);
    std.debug.assert(family.list.len > 0);

    const Answer = struct {
        dimensions: []const Member = &.{},
    };
    const answer = try system_read(ctx, Answer, family.list, "{}");

    if (answer.dimensions.len > model_dimension.dimensions_max) {
        return error.Invalid;
    }

    return answer.dimensions;
}

/// Which fields of the record `id` of type `type_name` each member of `family` shows on, by
/// its owner's `.shown`; null when it has none (every field holding the family).
pub fn shown_of(
    ctx: *Ctx,
    family: Setting,
    type_name: []const u8,
    id: []const u8,
) Error!?[]const Shown {
    std.debug.assert(family.each);
    std.debug.assert(type_name.len > 0);

    if (family.shown.len == 0) {
        return null;
    }

    if (id.len == 0) {
        return &.{};
    }

    const Answer = struct {
        shown: []const Shown = &.{},
    };
    const input = std.json.Stringify.valueAlloc(ctx.arena, .{
        .type = type_name,
        .id = id,
    }, .{}) catch return error.OutOfMemory;
    const answer = try system_read(ctx, Answer, family.shown, input);

    return answer.shown;
}

/// `fields` with what each dimension holds a field that says nothing of it by
/// (`Declared.default`) laid over, at the top level: each not saying no (`not_in`) holds it.
pub fn with_defaults(
    ctx: *const Ctx,
    fields: []const @import("../model/field.zig").Def,
) Error![]const @import("../model/field.zig").Def {
    std.debug.assert(fields.len <= @import("../model/field.zig").fields_max);

    const field_model = @import("../model/field.zig");
    const site = all(ctx);
    var out: ?[]field_model.Def = null;

    for (site) |dimension| {
        if (dimension.default == .one) {
            continue;
        }

        const changed = out orelse try ctx.arena.dupe(field_model.Def, fields);

        out = changed;

        for (changed) |*def| {
            const said = model_dimension.varies_by(def.dimensions, dimension.name) or
                model_dimension.lists(def.not_in, dimension.name);
            const skipped = field_model.is_layout(def.kind) or field_model.is_container(def.kind);

            if (said or skipped or def.dimensions.len == model_dimension.key_pairs_max) {
                continue;
            }

            def.dimensions = try appended(ctx.arena, def.dimensions, dimension.name);

            switch (dimension.default) {
                .required => def.required_in = try appended(
                    ctx.arena,
                    def.required_in,
                    dimension.name,
                ),
                .empty => def.empty_in = try appended(ctx.arena, def.empty_in, dimension.name),
                .one, .fallback => {},
            }
        }
    }

    return out orelse fields;
}

fn appended(
    arena: std.mem.Allocator,
    names: []const []const u8,
    name: []const u8,
) Error![]const []const u8 {
    std.debug.assert(name.len > 0);

    return std.mem.concat(arena, []const u8, &.{ names, &.{name} }) catch error.OutOfMemory;
}

/// What the owner's read `operation` answers `input`, called as the system.
fn system_read(
    ctx: *Ctx,
    comptime Answer: type,
    operation: []const u8,
    input: []const u8,
) Error!Answer {
    std.debug.assert(operation.len > 0);
    std.debug.assert(input.len > 0);

    // On the request's own context: a copy would set aside a scratch of its own on every
    // call.
    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    const json = try registry.SDK.call_json(ctx, operation, input);

    return std.json.parseFromSliceLeaky(Answer, ctx.arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.Invalid;
}

/// The dimension a read names `name`: by its own name, else by its read option's.
pub fn read_by(ctx: *const Ctx, name: []const u8) ?Setting {
    std.debug.assert(name.len > 0);

    const every = all(ctx);

    for (every) |dimension| {
        if (std.mem.eql(u8, dimension.name, name)) {
            return dimension;
        }
    }

    for (every) |dimension| {
        if (std.mem.eql(u8, dimension.read.name, name)) {
            return dimension;
        }
    }

    return null;
}

/// The dimension with pages of its own, else the highest priority one: the one the site's
/// addresses, the editor's language switch and what a record holds back follow.
pub fn setting(ctx: *const Ctx) ?Setting {
    std.debug.assert(values_max > 1);

    const every = all(ctx);

    for (every) |dimension| {
        if (dimension.addresses) {
            return dimension;
        }
    }

    for (every) |dimension| {
        if (!dimension.each) {
            return dimension;
        }
    }

    return null;
}

/// `dimension`'s values, the main one first.
/// A family's member (`variation-hero`) its member's; a family itself has none.
pub fn values_of(ctx: *Ctx, dimension: Setting) Error![]const Value {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(dimension.list.len > 0);

    if (dimension.each) {
        return member_values(ctx, dimension);
    }

    const Answer = struct {
        values: []const Value = &.{},
    };
    const answer = try system_read(ctx, Answer, dimension.list, "{}");

    if (answer.values.len > values_max) {
        return error.Invalid;
    }

    return answer.values;
}

fn member_values(ctx: *Ctx, dimension: Setting) Error![]const Value {
    std.debug.assert(dimension.each);

    const family = model_dimension.family_of(dimension.name);

    if (family.len == dimension.name.len) {
        return &.{};
    }

    const own = dimension.name[family.len + 1 ..];

    for (try members_of(ctx, dimension)) |member| {
        if (std.mem.eql(u8, member.name, own)) {
            return if (member.values.len > values_max) error.Invalid else member.values;
        }
    }

    return &.{};
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
                const own = std.mem.eql(u8, pair.dimension, dimension.name) and !dimension.each;
                const family = model_dimension.family_of(pair.dimension);
                const member = dimension.each and family.len < pair.dimension.len and
                    std.mem.eql(u8, family, dimension.name);

                if (own or member) {
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

/// Whether a field must hold a value of its own at `value` before its record goes live: when
/// it holds the dimension `.required`. The main value is the field's own `required`, never
/// this.
pub fn required(
    dimension: Setting,
    value: Value,
    field: @import("../model/field.zig").Def,
) bool {
    std.debug.assert(dimension.name.len > 0);
    std.debug.assert(field.name.len > 0);

    if (value.main) {
        return false;
    }

    return model_dimension.holds_of(field, dimension.name) == .required;
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
    field: @import("../model/field.zig").Def,
) Error![]const Required {
    std.debug.assert(field.name.len > 0);
    std.debug.assert(field.dimensions.len <= model_dimension.dimensions_max + 1);

    var out: std.ArrayList(Required) = .empty;

    if (field.dimensions.len == 0) {
        return out.items;
    }

    for (expanded(ctx)) |dimension| {
        if (!model_dimension.varies_by(field.dimensions, dimension.name)) {
            continue;
        }

        for (try values_of(ctx, dimension)) |value| {
            if (required(dimension, value, field)) {
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

test "required: only a field holding the dimension `.required`, never at the main value" {
    const language: Setting = .{
        .name = "language",
        .list = "languages.list",
        .field = .{
            .name = "translatable",
            .label = "Translate",
            .choices = &.{},
        },
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

    try std.testing.expect(!required(language, polish, body));

    var strict_body = body;

    strict_body.required_in = &.{"language"};
    try std.testing.expect(required(language, polish, strict_body));

    var english = polish;

    english.main = true;
    try std.testing.expect(!required(language, english, strict_body));

    var shared = strict_body;

    shared.dimensions = &.{};
    try std.testing.expect(!required(language, polish, shared));
}
