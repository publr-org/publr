const std = @import("std");
const sdk = @import("../sdk.zig");
const site_currencies = @import("../sdk/site_currencies.zig");
const model_money = @import("../model/money.zig");
const currency = @import("../model/currency.zig");
const public = @import("../publr/operations/money.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "money",
    .label = "Money",
    .area = .background,
    .summary = "Amounts written as the site writes them",
    .details =
    \\Reads that write amounts in minor units with the site's currencies: their symbols,
    \\formats and separators. Plugins call them to show money on their own pages.
    ,
};

pub const Text = struct {
    pub const shape = public.Text;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(model_money.format_len_max > 0);

        return .{
            .text = try written(ctx, try site_currencies.of(ctx), in.amount, in.plain),
        };
    }
};

/// `amounts` as the site's currencies `listed` write it; empty for no amount.
fn written(
    ctx: *Ctx,
    listed: []const model_money.Entry,
    amounts: Amounts,
    plain: bool,
) Error![]const u8 {
    std.debug.assert(listed.len <= site_currencies.currencies_max);

    const shown = chosen(amounts, listed) orelse return "";
    var buffer: [128]u8 = undefined;
    const digits: u8 = if (currency.find(shown.entry.code)) |found| found.digits else 2;
    const text = if (plain)
        model_money.format_minor(&buffer, shown.amount, digits)
    else
        model_money.format(&buffer, shown.amount, shown.entry);

    std.debug.assert(text.len > 0);

    return ctx.arena.dupe(u8, text);
}

pub const Texts = struct {
    pub const shape = public.Texts;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;
    pub const amounts_max = shape.amounts_max;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(model_money.format_len_max > 0);

        if (in.amounts.len > amounts_max) {
            return error.Invalid;
        }

        const texts = ctx.arena.alloc([]const u8, in.amounts.len) catch return error.OutOfMemory;
        // The site's currencies are asked for once, however many amounts are written.
        const listed = try site_currencies.of(ctx);

        for (in.amounts, texts) |amount, *text| {
            text.* = try written(ctx, listed, amount, in.plain);
        }

        std.debug.assert(texts.len == in.amounts.len);

        return .{
            .texts = texts,
        };
    }
};

const Amounts = @import("../publr/money.zig").Money;

const Shown = struct {
    amount: i64,
    entry: model_money.Entry,
};

/// The site's main currency when the amount has it, else the amount's first; null for an
/// amount with none, or in a currency that is not one.
fn chosen(amounts: Amounts, listed: []const model_money.Entry) ?Shown {
    std.debug.assert(listed.len <= site_currencies.currencies_max);

    if (listed.len > 0) {
        if (amounts.get(listed[0].code)) |amount| {
            return .{
                .amount = amount,
                .entry = listed[0],
            };
        }
    }

    if (amounts.amounts.len == 0) {
        return null;
    }

    const first = amounts.amounts[0];
    const code = first.currency;

    if (currency.find(code) == null) {
        return null;
    }

    return .{
        .amount = first.minor,
        .entry = site_currencies.entry_of(listed, code) orelse .{
            .code = code,
        },
    };
}

pub const Main = struct {
    pub const shape = public.Main;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        const listed = try site_currencies.of(ctx);

        std.debug.assert(listed.len <= site_currencies.currencies_max);

        if (listed.len == 0) {
            return .{
                .currency = "",
                .example = "",
            };
        }

        var buffer: [128]u8 = undefined;
        const digits: u8 = if (currency.find(listed[0].code)) |found| found.digits else 2;
        const amount = std.math.powi(i64, 10, digits) catch 1;

        const example_text = model_money.format(&buffer, 1234 * amount, listed[0]);

        return .{
            .currency = listed[0].code,
            .example = try ctx.arena.dupe(u8, example_text),
        };
    }
};

pub const Read = struct {
    pub const shape = public.Read;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(in.text.len <= 1 << 20);

        const listed = try site_currencies.of(ctx);
        const main = if (listed.len > 0) listed[0].code else return error.Invalid;
        const digits: u8 = if (currency.find(main)) |found| found.digits else 2;
        var dotted: [32]u8 = undefined;

        if (in.text.len > dotted.len) {
            return error.Invalid;
        }

        for (in.text, 0..) |byte, index| {
            dotted[index] = if (byte == ',') '.' else byte;
        }

        const amount = model_money.parse_decimal(dotted[0..in.text.len], digits) orelse {
            return error.Invalid;
        };
        return .{
            .amount = try Amounts.of(ctx.arena, main, amount),
        };
    }
};

pub const operations = [_]type{ Text, Texts, Main, Read };

test "money.text writes the amount's currency with its code when the site lists none" {
    const TestSDK = sdk.SDK(.{
        .operations = &operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const out = try TestSDK.dispatch(&ctx, Text, .{
        .amount = .{
            .amounts = &.{.{
                .currency = "GBP",
                .minor = 123456,
            }},
        },
    });
    const none = try TestSDK.dispatch(&ctx, Text, .{
        .amount = .{},
    });

    try std.testing.expectEqualStrings("GBP1,234.56", out.text);
    try std.testing.expectEqualStrings("", none.text);
}

test "money.text and money.main answer a visitor nobody knows" {
    const TestSDK = sdk.SDK(.{
        .operations = &operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.anonymous);
    const out = try TestSDK.dispatch(&ctx, Text, .{
        .amount = .{
            .amounts = &.{.{
                .currency = "GBP",
                .minor = 995,
            }},
        },
    });
    const main = try TestSDK.dispatch(&ctx, Main, .{});

    try std.testing.expectEqualStrings("GBP9.95", out.text);
    try std.testing.expectEqualStrings("", main.currency);
    // Reading what someone typed stays with signed-in callers.
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&ctx, Read, .{
        .text = "9.95",
    }));
}

test "a plugin names the money operations by their public shapes" {
    const registry = @import("../server/registry.zig");

    inline for (operations) |Operation| {
        try std.testing.expect(registry.SDK.bound(Operation.shape) == Operation);
        try std.testing.expect(registry.SDK.bound(Operation) == Operation);
    }
}
