//! A provider field (`publr.ProviderRef`) names a provider registered into its contract. A
//! value the record held already passes as it is: a provider removed later stays named.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const contract = @import("../../sdk/contract.zig");
const document = @import("document.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Def = store.definitions.Def;
const Value = std.json.Value;

/// Refuses each top-level provider field of `given` naming no provider of its contract,
/// unless `before` (the record as stored, null for a new one) held the same name.
pub fn refuse_unknown(ctx: *Ctx, def: Def, given: Value, before: ?Value) Error!void {
    std.debug.assert(given == .object);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    var problems: model.field.Problems = .{
        .reader = ctx,
    };

    for (def.fields) |field| {
        if (!std.mem.eql(u8, field.kind, "provider")) {
            continue;
        }

        const value = given.object.get(field.name) orelse continue;

        if (value != .string or value.string.len == 0 or kept(before, field.name, value.string)) {
            continue;
        }

        if (!try registered(ctx, field.options.provider.contract, value.string)) {
            problems.add(field.name, "no provider of this name is installed");
        }
    }

    if (!problems.is_empty()) {
        return ctx.refuse(try document.refusal_of(ctx, &problems));
    }
}

/// Whether the record already held `name` in the field.
fn kept(before: ?Value, field: []const u8, name: []const u8) bool {
    std.debug.assert(field.len > 0);
    std.debug.assert(name.len > 0);

    const stored = before orelse return false;

    if (stored != .object) {
        return false;
    }

    const held = stored.object.get(field) orelse return false;

    return held == .string and std.mem.eql(u8, held.string, name);
}

/// Whether a provider of `name` is registered into `contract`, on or off.
pub fn registered(ctx: *Ctx, contract_name: []const u8, name: []const u8) Error!bool {
    std.debug.assert(contract_name.len > 0);
    std.debug.assert(name.len > 0);

    for (try contract.listed(ctx, contract_name)) |one| {
        if (std.mem.eql(u8, one.provider.name, name)) {
            return true;
        }
    }

    return false;
}

/// The provider's label, or its name when it gave none; null when none of that name is
/// registered into the contract (removed since).
pub fn label_of(ctx: *Ctx, contract_name: []const u8, name: []const u8) Error!?[]const u8 {
    std.debug.assert(contract_name.len > 0);
    std.debug.assert(name.len > 0);

    for (try contract.listed(ctx, contract_name)) |one| {
        if (std.mem.eql(u8, one.provider.name, name)) {
            const label = one.provider.label;

            return if (label.len > 0) label else name;
        }
    }

    return null;
}
