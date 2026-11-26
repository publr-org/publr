//! Amounts written as the site writes them: its currencies' symbols, formats and separators
//! (`money.currencies`), for code that shows money outside a template, such as a plugin's
//! admin page: `ctx.call(publr.operations.money.Text, .{ .amount = price })`. Templates have
//! `Publr.request.money` for the same.
const operation = @import("../operation.zig");

/// `publr.Money`: by currency, in each currency's minor units.
const Amounts = @import("../money.zig").Money;

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
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{
        .amount = "By ISO 4217 code, in minor units: `{ \"GBP\": 1745, \"EUR\": 2000 }`",
        .plain = "As typed into a field: `1234.56`, no symbol or grouping",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .text = "The amount as the site writes it; empty for no amount",
    };
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
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{
        .amounts = "Each by ISO 4217 code, in minor units: `{ \"GBP\": 1745 }`; at most 200",
        .plain = "As typed into a field: `1234.56`, no symbol or grouping",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .texts = "Each amount as the site writes it, in order; empty for no amount",
    };

    /// The most amounts one call writes.
    pub const amounts_max: u32 = 200;
};

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
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .currency = "An ISO 4217 code; empty when the site lists none",
        .example = "1234.56 written as the site writes it",
    };
};

pub const Read = struct {
    pub const name = "money.read";
    pub const description = "Read an amount as people type it, in the main currency";
    pub const details =
        \\An amount as typed in the admin (`3.95`, `3,95`, `4`) in the site's main currency,
        \\answered by currency in minor units: `{ "GBP": 395 }`. Refused when it is not a
        \\number, has more decimals than the currency, or the site lists no currency.
    ;
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{
        .text = "The amount as typed: `3.95`, `3,95`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .amount = "By the main currency's code, in minor units",
    };
};
