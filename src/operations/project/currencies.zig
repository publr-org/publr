//! The currencies the site prices in: the first is the default, what a page shows and a
//! list sorts by. Money fields hold amounts in these only. Until it is set, any ISO 4217
//! currency is taken.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const deps = @import("../../lib/deps.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const currencies_max: u32 = 32;
/// The key a page that formats money depends on: raised when the currencies change.
pub const dependency_key = "setting:currencies";
const key = "currencies";
const Entry = model.money.Entry;

const example_entries: []const Entry = &.{
    .{ .code = "GBP", .symbol = "£" },
    .{
        .code = "EUR",
        .symbol = "€",
        .format = "{amount} {symbol}",
        .decimal = ",",
        .thousands = " ",
    },
};

pub const Currencies = struct {
    pub const name = "project.currencies";
    pub const description = "The currencies the site prices in, the default first";
    pub const details =
        \\Anyone may read them. Empty until set: then a money field takes any ISO 4217
        \\currency.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct { currencies: []const Entry };
    pub const example: In = .{};
    pub const example_out: Out = .{ .currencies = example_entries };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .currencies = "each with its symbol and how amounts are written, the default first",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        return .{ .currencies = try of(ctx) };
    }
};

pub const SetCurrencies = struct {
    pub const name = "project.set_currencies";
    pub const description = "Say which currencies the site prices in and how it writes them";
    pub const details =
        \\Administrators only. Each an ISO 4217 code, once, the default first; none at all
        \\takes any code again. A symbol
        \\(the code when left out) and a format holding {amount}, and optionally {symbol}
        \\and {code}: "{symbol}{amount}" writes £9.25, "{amount} {code}" writes 9.25 GBP.
        \\The decimal separator is "." (the default) or ","; the thousands one ",", ".", "'",
        \\" " or "" (none), never the decimal one. The decimals are the
        \\currency's own. Amounts already stored in a currency left out stay as they are,
        \\and a save that keeps one is refused. Pages that write amounts are rebuilt.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { currencies: []const Entry };
    pub const Out = struct { currencies: []const Entry };
    pub const rules: sdk.operation.Rules(In) = .{
        .currencies = .{ .items_max = currencies_max },
    };
    pub const example: In = .{ .currencies = example_entries };
    pub const example_out: Out = .{ .currencies = example_entries };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .currencies = "each { code, symbol, format, decimal, thousands }, the default first",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(granted.allows());

        for (in.currencies, 0..) |entry, index| {
            if (model.money.entry_problem(entry)) |problem| {
                const message = std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{
                    entry.code,
                    problem,
                }) catch return error.OutOfMemory;

                return ctx.fail(.{ .name = "InvalidInput", .status = 400, .message = message });
            }

            for (in.currencies[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.code, entry.code)) {
                    return ctx.fail(.{
                        .name = "InvalidInput",
                        .status = 400,
                        .message = "a currency is listed once",
                    });
                }
            }
        }

        const stored = std.json.Stringify.valueAlloc(ctx.arena, in.currencies, .{}) catch {
            return error.OutOfMemory;
        };
        var index: deps.Index = .{ .db = ctx.db, .options = .{ .quiet_ms = deps.quiet_ms } };

        try store.settings.set(ctx.db, key, stored, ctx.now_ms);
        index.invalidate(&.{dependency_key}, ctx.now_ms) catch {
            ctx.dependency_failure = true;
        };

        return .{ .currencies = in.currencies };
    }
};

/// The site's currencies, the default first; empty when any is taken.
pub fn of(ctx: *Ctx) Error![]const Entry {
    std.debug.assert(ctx.now_ms >= 0);

    const stored = try store.settings.get(ctx.db, ctx.arena, key) orelse return &.{};
    const parsed = std.json.parseFromSliceLeaky([]const Entry, ctx.arena, stored, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};

    std.debug.assert(parsed.len <= currencies_max);

    return parsed;
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
/// amounts in the site's currencies only (`project set_currencies`); any when they are not
/// set. The document is walked with a worklist, one entry per object it holds.
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

    const Level = struct { fields: []const model.field.Def, object: std.json.ObjectMap };
    var pending: std.ArrayList(Level) = .empty;

    pending.append(ctx.arena, .{ .fields = fields, .object = document.object }) catch {
        return error.OutOfMemory;
    };

    while (pending.pop()) |level| {
        for (level.fields) |field| {
            const value = level.object.get(field.name) orelse continue;

            if (model.field.is_money(field.kind) and value == .object) {
                try refuse_codes(listed, value.object);
            } else if (model.field.is_group(field.kind) and value == .object) {
                const inner: Level = .{ .fields = field.fields, .object = value.object };

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
            pending.append(ctx.arena, .{ .fields = fields, .object = item.object }) catch {
                return error.OutOfMemory;
            };
        }
    }
}

const registry = @import("../../server/registry.zig");
const records = @import("../record.zig");
const content_types = @import("../content_type.zig");

test "money: amounts per currency, only the site's, found and sorted by one" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const definition =
        \\{"handle":"product","name":"Product","fields":[
        \\ {"name":"title","label":"Title","kind":"string","required":true},
        \\ {"name":"price","label":"Price","kind":"money"}]}
    ;
    _ = try registry.SDK.dispatch(&system, content_types.Create, .{ .definition = definition });

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

    const got = try registry.SDK.dispatch(&system, records.Get, .{ .id = cheap.id });
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

    _ = try registry.SDK.dispatch(&system, SetCurrencies, .{ .currencies = example_entries });

    const listed = try registry.SDK.dispatch(&system, Currencies, .{});
    try std.testing.expectEqualStrings("GBP", listed.currencies[0].code);
    try std.testing.expectEqualStrings("{amount} {symbol}", listed.currencies[1].format);

    const elsewhere = registry.SDK.dispatch(&system, records.Create, .{
        .type = "product",
        .document = "{\"title\":\"Yen\",\"price\":{\"JPY\":100}}",
    });
    try std.testing.expectError(error.Invalid, elsewhere);

    const nested_definition =
        \\{"handle":"menu","name":"Menu","fields":[
        \\ {"name":"title","label":"Title","kind":"string","required":true},
        \\ {"name":"dishes","label":"Dishes","kind":"repeater","fields":[
        \\  {"name":"name","label":"Name","kind":"string"},
        \\  {"name":"cost","label":"Cost","kind":"group","fields":[
        \\   {"name":"price","label":"Price","kind":"money"}]}]}]}
    ;
    _ = try registry.SDK.dispatch(&system, content_types.Create, .{
        .definition = nested_definition,
    });
    _ = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "menu",
        .document = "{\"title\":\"Lunch\",\"dishes\":[{\"name\":\"Soup\"," ++
            "\"cost\":{\"price\":{\"GBP\":450}}}]}",
    });
    const nested_yen = registry.SDK.dispatch(&system, records.Create, .{
        .type = "menu",
        .document = "{\"title\":\"Dinner\",\"dishes\":[{\"name\":\"Soup\"," ++
            "\"cost\":{\"price\":{\"JPY\":450}}}]}",
    });
    try std.testing.expectError(error.Invalid, nested_yen);

    const unknown = registry.SDK.dispatch(&system, SetCurrencies, .{
        .currencies = &.{.{ .code = "ZZZ" }},
    });
    try std.testing.expectError(error.Failed, unknown);

    const no_amount = registry.SDK.dispatch(&system, SetCurrencies, .{
        .currencies = &.{.{ .code = "GBP", .format = "{symbol}" }},
    });
    try std.testing.expectError(error.Failed, no_amount);
}
