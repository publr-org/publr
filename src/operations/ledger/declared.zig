//! What plugins declare of their ledgers (`publr.ledger.define`), compiled in or installed:
//! account names, reasons, units and their words.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model/ledger.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// Plugin `plugin`'s ledger; null when it declares none (or is gone).
pub fn of(ctx: *const Ctx, plugin: []const u8) ?model.Declaration {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    return registry.ledger_of(ctx, plugin);
}

/// The decimal places of a unit's smallest step; refused for text that names no currency
/// and no unit a plugin declares.
pub fn scale_of(ctx: *Ctx, unit_text: []const u8) Error!u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const unit = model.unit_of(unit_text) orelse return refused_unit(ctx);

    if (model.currency_scale(unit.base)) |scale| {
        return scale;
    }

    const parts = model.declared_parts(unit.base) orelse return refused_unit(ctx);
    const ledger = of(ctx, parts[0]) orelse return refused_unit(ctx);
    const found = ledger.unit(parts[1]) orelse return refused_unit(ctx);

    std.debug.assert(found.scale <= 18);

    return found.scale;
}

fn refused_unit(ctx: *Ctx) error{Invalid} {
    std.debug.assert(ctx.now_ms >= 0);

    return ctx.refuse(&.{.{
        .field = "unit",
        .message = "A unit is an ISO 4217 code or a unit a plugin declares " ++
            "(<plugin>.<unit>), maybe per record (/<id>)",
    }});
}

/// Refused unless `reason` is one `plugin` declares.
pub fn check_reason(ctx: *Ctx, plugin: []const u8, reason: []const u8) Error!void {
    std.debug.assert(plugin.len > 0);

    const ledger = of(ctx, plugin) orelse return error.Invalid;

    if (ledger.reason(reason) == null) {
        return ctx.refuse(&.{.{
            .field = "reason",
            .message = "Not one of the plugin's declared reasons",
        }});
    }
}

/// A reason's words, or the reason itself when its plugin is gone.
pub fn reason_label(ctx: *const Ctx, plugin: []const u8, reason: []const u8) []const u8 {
    std.debug.assert(reason.len > 0);

    const ledger = of(ctx, plugin) orelse return reason;
    const found = ledger.reason(reason) orelse return reason;

    return found.label;
}

/// An account name's words, or the name itself when its plugin is gone.
pub fn account_label(ctx: *const Ctx, plugin: []const u8, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const ledger = of(ctx, plugin) orelse return name;
    const found = ledger.account(name) orelse return name;

    return found.label;
}
