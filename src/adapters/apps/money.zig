//! `Publr.build.money(price)` and `money(price, "EUR")`: an amount written the way the site
//! says its currency is written (`project set_currencies`). A page that writes one depends
//! on the currencies, and is rebuilt when they change.

const std = @import("std");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const currencies = @import("../../operations/project/currencies.zig");
const Context = @import("context.zig").Context;

/// The currency an amount is read in: the one named if the site lists it, else the
/// default; null when the site lists none, or not that one.
pub fn code(ctx: *const Context, wanted: ?[]const u8) !?[]const u8 {
    std.debug.assert(wanted == null or wanted.?.len > 0);

    const listed = try listed_of(ctx);
    const entry = currencies.entry_of(listed, wanted) orelse return null;

    std.debug.assert(entry.code.len > 0);

    return entry.code;
}

/// `amount` in `currency`'s minor units as the site writes it: `£9.25`.
pub fn write(ctx: *const Context, amount: i64, currency: []const u8) ![]const u8 {
    std.debug.assert(currency.len > 0);

    const listed = try listed_of(ctx);
    const entry = currencies.entry_of(listed, currency) orelse return error.UnknownCurrency;
    var buffer: [96]u8 = undefined;

    return ctx.arena.dupe(u8, model.money.format(&buffer, amount, entry));
}

fn listed_of(ctx: *const Context) ![]const model.money.Entry {
    std.debug.assert(ctx.app.built_at >= 0);

    if (ctx.deps) |deps| {
        deps.record_key(currencies.dependency_key);
    }

    var sdk_ctx = ctx.sdk_context();
    const listed = try registry.SDK.dispatch(&sdk_ctx, currencies.Currencies, .{});

    return listed.currencies;
}
