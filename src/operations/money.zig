//! Amounts written as the site writes them: its currencies' symbols, formats and separators
//! (`money.currencies`), for code that shows money outside a template, such as a plugin's
//! admin page. Templates have `Publr.request.money` for the same.
const std = @import("std");
const sdk = @import("../sdk.zig");
const site_currencies = @import("../sdk/site_currencies.zig");
const model_money = @import("../model/money.zig");
const currency = @import("../model/currency.zig");

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
    pub const name = "money.text";
    /// Changes nothing, and every page may show prices: a plugin's code acting for a
    /// visitor nobody knows (a cart) writes them too.
    pub const open = true;
    pub const description = "Write an amount as the site writes it";
    pub const details =
        \\An amount by currency, in each currency's minor units (`{ "GBP": 1745 }` is
        \\£17.45), written in the site's main currency with its entry: `£1,234.56`,
        \\`1 234,56 zł`, as pages write money. Without the main currency the amount's first
        \\one is written, with the site's entry or its code. Changes nothing;
        \\anyone may call it, visitors included.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        amount: Amounts,
        plain: bool = false,
    };
    pub const Out = struct {
        text: []const u8,
    };
    pub const example: In = .{
        .amount = .{
            .amounts = &.{.{
                .currency = "GBP",
                .minor = 123456,
            }},
        },
    };
    pub const example_out: Out = .{
        .text = "GBP1,234.56",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .amount = "By ISO 4217 code, in minor units: `{ \"GBP\": 1745, \"EUR\": 2000 }`",
        .plain = "As typed into a field: `1234.56`, no symbol or grouping",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .text = "The amount as the site writes it; empty for no amount",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(model_money.format_len_max > 0);

        return .{
            .text = try written(ctx, try site_currencies.of(ctx), in.amount, in.plain),
        };
    }

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
};

/// Many amounts at once, as `money.text` writes each: a page of an order's lines and charges
/// in one call.
pub const Texts = struct {
    pub const name = "money.texts";
    pub const open = true;
    pub const description = "Write many amounts as the site writes them";
    pub const details =
        \\Each amount written as `money.text` writes it, in the same order: up to 200 a
        \\call. Changes nothing; anyone may call it, visitors included.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        amounts: []const Amounts,
        plain: bool = false,
    };
    pub const Out = struct {
        texts: []const []const u8,
    };
    pub const example: In = .{
        .amounts = &.{.{
            .amounts = &.{.{
                .currency = "GBP",
                .minor = 123456,
            }},
        }},
    };
    pub const example_out: Out = .{
        .texts = &.{"GBP1,234.56"},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .amounts = "Each by ISO 4217 code, in minor units: `{ \"GBP\": 1745 }`; at most 200",
        .plain = "As typed into a field: `1234.56`, no symbol or grouping",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .texts = "Each amount as the site writes it, in order; empty for no amount",
    };

    /// The most amounts one call writes.
    pub const amounts_max: u32 = 200;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(model_money.format_len_max > 0);

        if (in.amounts.len > amounts_max) {
            return error.Invalid;
        }

        const texts = ctx.arena.alloc([]const u8, in.amounts.len) catch return error.OutOfMemory;
        // The site's currencies are asked for once, however many amounts are written.
        const listed = try site_currencies.of(ctx);

        for (in.amounts, texts) |amount, *text| {
            text.* = try Text.written(ctx, listed, amount, in.plain);
        }

        std.debug.assert(texts.len == in.amounts.len);

        return .{
            .texts = texts,
        };
    }
};

const Amounts = @import("../sdk/money.zig").Money;

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
    pub const name = "money.main";
    /// Changes nothing; prices are shown to every visitor in it.
    pub const open = true;
    pub const description = "The store's main currency";
    pub const details =
        \\The site's main currency, the first it lists: prices are entered in it and orders
        \\keep it; other currencies are conversions from it. Empty when the site lists none.
        \\Changes nothing; anyone may call it, visitors included.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        currency: []const u8,
        /// 1234.56 in it, as the site writes it
        example: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .currency = "",
        .example = "",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .currency = "An ISO 4217 code; empty when the site lists none",
        .example = "1234.56 written as the site writes it",
    };

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

        const written = model_money.format(&buffer, 1234 * amount, listed[0]);

        return .{
            .currency = listed[0].code,
            .example = try ctx.arena.dupe(u8, written),
        };
    }
};

pub const Read = struct {
    pub const name = "money.read";
    pub const description = "Read an amount as people type it, in the main currency";
    pub const details =
        \\An amount as typed in the admin (`3.95`, `3,95`, `4`) in the site's main currency,
        \\answered by currency in minor units: `{ "GBP": 395 }`. Refused when it is not a
        \\number, has more decimals than the currency, or the site lists no currency.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        text: []const u8,
    };
    pub const Out = struct {
        amount: Amounts,
    };
    pub const example: In = .{
        .text = "3.95",
    };
    pub const example_out: Out = .{
        .amount = .{
            .amounts = &.{.{
                .currency = "GBP",
                .minor = 395,
            }},
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .text = "The amount as typed: `3.95`, `3,95`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .amount = "By the main currency's code, in minor units",
    };

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
