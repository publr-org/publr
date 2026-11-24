//! An internal record's field rules, run on every write in its transaction as content's
//! are: bounds and shapes, a provider field naming a provider of its contract, and a unique
//! value held by no other record of the collection in the same scope.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const document = @import("../document/document.zig");
const provider_values = @import("../document/provider_values.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Value = std.json.Value;
const Collection = model.internal_record.Collection;
const records = store.internal_records;

/// Refuses `written` (the record as it will be stored) with every problem of its fields;
/// a conflict when a unique value is another record's. `before` is the record as stored,
/// null for a new one: a provider it named already passes, removed since or not.
pub fn check(
    ctx: *Ctx,
    collection: Collection,
    scope: records.Scope,
    written: Value,
    before: ?Value,
    own_id: ?[]const u8,
) Error!void {
    std.debug.assert(written == .object);
    std.debug.assert(collection.rules.len <= model.field.fields_max);

    if (collection.rules.len == 0) {
        return;
    }

    var problems: model.field.Problems = .{
        .reader = ctx,
    };

    model.validate.validate_fields(
        registry.kinds(ctx),
        collection.rules,
        written.object,
        ctx.now_ms,
        &problems,
    );
    try providers(ctx, collection.rules, written, before, &problems);

    if (!problems.is_empty()) {
        return ctx.refuse(try document.refusal_of(ctx, &problems));
    }

    try refuse_taken(ctx, collection, scope, written, own_id);
}

fn providers(
    ctx: *Ctx,
    rules: []const model.field.Def,
    written: Value,
    before: ?Value,
    problems: *model.field.Problems,
) Error!void {
    std.debug.assert(written == .object);
    std.debug.assert(rules.len <= model.field.fields_max);

    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.kind, "provider")) {
            continue;
        }

        const value = written.object.get(rule.name) orelse continue;

        if (value != .string or value.string.len == 0 or held(before, rule.name, value.string)) {
            continue;
        }

        const contract = rule.options.provider.contract;

        if (!try provider_values.registered(ctx, contract, value.string)) {
            problems.add(rule.name, "no provider of this name is installed");
        }
    }
}

fn held(before: ?Value, name: []const u8, value: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(value.len > 0);

    const stored = before orelse return false;
    const was = stored.object.get(name) orelse return false;

    return was == .string and std.mem.eql(u8, was.string, value);
}

/// Each unique value looked up by its index; any record but this one holding it refuses.
fn refuse_taken(
    ctx: *Ctx,
    collection: Collection,
    scope: records.Scope,
    written: Value,
    own_id: ?[]const u8,
) Error!void {
    std.debug.assert(written == .object);
    std.debug.assert(scope.kind.len > 0);

    for (collection.rules) |rule| {
        if (!rule.validation.unique) {
            continue;
        }

        const value = written.object.get(rule.name) orelse continue;
        const text = try model.internal_record.indexed_text(ctx.arena, value) orelse continue;

        if (text.len == 0) {
            continue;
        }

        const match: records.Match = .{
            .field = rule.name,
            .value = text,
        };

        for (try records.list(ctx.db, ctx.arena, scope, match, 2, 0)) |row| {
            const own = own_id != null and std.mem.eql(u8, row.id, own_id.?);

            if (!own) {
                return error.Conflict;
            }
        }
    }
}
