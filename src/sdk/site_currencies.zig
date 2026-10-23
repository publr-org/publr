//! The currencies the site prices in, the default first: what a plugin answers through the
//! mod `money.currencies` (`publr.modify("money.currencies", …)`, the value
//! `{ "currencies": [...] }`). Money fields hold amounts in these only, pages write amounts
//! the way they say, and with none (nobody modifies it) any ISO 4217 currency is taken.

const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const mods = @import("mods.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Entry = model.money.Entry;

pub const currencies_max: u32 = 32;
pub const mod_name = "money.currencies";
/// The key a page that formats money depends on: raised by `mod.changed` when the plugin
/// answering the mod says its currencies changed.
pub const dependency_key = "mod:" ++ mod_name;

/// The value the mod passes: empty until a plugin fills it.
pub const Applied = struct {
    currencies: []const Entry = &.{},
};

/// The site's currencies, the default first; empty when any is taken. An entry that is not
/// well formed, or a list past `currencies_max`, is left out: core writes amounts with them.
pub fn of(ctx: *Ctx) Error![]const Entry {
    std.debug.assert(ctx.now_ms >= 0);

    if (!registry.SDK.modified(ctx, mod_name)) {
        return &.{};
    }

    var items = [_]std.json.Value{.{
        .object = .empty,
    }};
    try items[0].object.put(ctx.arena, "currencies", .{
        .array = .init(ctx.arena),
    });
    var batch: mods.Batch = .{
        .items = &items,
    };

    try registry.SDK.modify(ctx, mod_name, &batch);

    const applied = std.json.parseFromValueLeaky(Applied, ctx.arena, batch.items[0], .{
        .ignore_unknown_fields = true,
    }) catch return &.{};
    var kept: std.ArrayList(Entry) = .empty;

    for (applied.currencies) |entry| {
        if (kept.items.len == currencies_max) {
            break;
        }

        const well_formed = model.money.entry_problem(entry) == null;

        if (well_formed and entry_of(kept.items, entry.code) == null) {
            kept.append(ctx.arena, entry) catch return error.OutOfMemory;
        }
    }

    return kept.items;
}

/// The default currency, or one the site lists by its code; null when there is none.
pub fn entry_of(listed: []const Entry, code: ?[]const u8) ?Entry {
    std.debug.assert(listed.len <= currencies_max);

    const wanted = code orelse {
        return if (listed.len > 0) listed[0] else null;
    };

    for (listed) |entry| {
        if (std.mem.eql(u8, entry.code, wanted)) {
            return entry;
        }
    }

    return null;
}

/// Whether the site takes amounts in `code`.
pub fn takes(listed: []const Entry, code: []const u8) bool {
    std.debug.assert(listed.len <= currencies_max);
    std.debug.assert(code.len > 0);

    return listed.len == 0 or entry_of(listed, code) != null;
}

/// Every money field, at the top or in a group or a repeater's items at any depth, holds
/// amounts in the site's currencies only (`money.currencies`); any when none are named. The
/// document is walked with a worklist, one entry per object it holds.
pub fn refuse_others(
    ctx: *Ctx,
    fields: []const model.field.Def,
    document: std.json.Value,
) Error!void {
    std.debug.assert(fields.len <= model.field.fields_max);

    const listed = try of(ctx);

    if (listed.len == 0 or document != .object) {
        return;
    }

    const Level = struct {
        fields: []const model.field.Def,
        object: std.json.ObjectMap,
    };
    var pending: std.ArrayList(Level) = .empty;

    pending.append(ctx.arena, .{
        .fields = fields,
        .object = document.object,
    }) catch {
        return error.OutOfMemory;
    };

    while (pending.pop()) |level| {
        for (level.fields) |field| {
            const value = level.object.get(field.name) orelse continue;

            if (model.field.is_money(field.kind) and value == .object) {
                try refuse_codes(listed, value.object);
            } else if (model.field.is_group(field.kind) and value == .object) {
                const inner: Level = .{
                    .fields = field.fields,
                    .object = value.object,
                };

                pending.append(ctx.arena, inner) catch return error.OutOfMemory;
            } else if (model.field.is_repeater(field.kind) and value == .array) {
                try push_items(ctx, &pending, field.fields, value.array.items);
            }
        }
    }
}

fn refuse_codes(listed: []const Entry, amounts: std.json.ObjectMap) Error!void {
    std.debug.assert(listed.len <= currencies_max);

    for (amounts.keys()) |code| {
        if (!takes(listed, code)) {
            return error.Invalid;
        }
    }
}

fn push_items(
    ctx: *Ctx,
    pending: anytype,
    fields: []const model.field.Def,
    items: []const std.json.Value,
) Error!void {
    std.debug.assert(items.len <= model.document.items_max);

    for (items) |item| {
        if (item == .object) {
            pending.append(ctx.arena, .{
                .fields = fields,
                .object = item.object,
            }) catch {
                return error.OutOfMemory;
            };
        }
    }
}

const records = @import("../operations/record.zig");
const content_types = @import("../operations/content_type.zig");

test "money: amounts per currency, any ISO 4217 one while no plugin names the site's" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const definition =
        \\{"handle":"product","name":"Product","fields":[
        \\ {"name":"title","label":"Title","kind":"string","validation":{"required":true}},
        \\ {"name":"price","label":"Price","kind":"money"}]}
    ;
    _ = try registry.SDK.dispatch(&system, content_types.Create, .{
        .definition = definition,
    });

    const cheap = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "product",
        .document = "{\"title\":\"Cheap\",\"price\":{\"GBP\":850,\"JPY\":1500}}",
        .status = "published",
    });
    _ = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "product",
        .document = "{\"title\":\"Dear\",\"price\":{\"GBP\":2400}}",
        .status = "published",
    });

    const got = try registry.SDK.dispatch(&system, records.Get, .{
        .id = cheap.id,
    });
    try std.testing.expect(std.mem.indexOf(u8, got.document, "\"JPY\":1500") != null);

    const found = try registry.SDK.dispatch(&system, records.List, .{
        .type = "product",
        .filter_field = "price.GBP",
        .filter_value = "850",
    });
    try std.testing.expectEqual(@as(usize, 1), found.records.len);

    const not_iso = registry.SDK.dispatch(&system, records.Create, .{
        .type = "product",
        .document = "{\"title\":\"Odd\",\"price\":{\"ABC\":1}}",
    });
    try std.testing.expectError(error.Invalid, not_iso);

    try std.testing.expectEqual(0, (try of(&system)).len);
}
