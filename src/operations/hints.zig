//! Hints for the fields just added to a type: every operation's `hint` (core's and
//! compiled-in plugins' from the registry, installed plugins' from their manifests) whose
//! names hold the new field's. Each API owns its own hint, so nothing here names one. A hint
//! only warns: the answer carries it and the change is made as asked.
const std = @import("std");
const sdk = @import("../sdk.zig");
const hint = @import("../publr/hint.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// The hints one answer carries at most.
pub const hinted_max: u32 = 16;

/// The hints for each field in `added`, in its order; a field may get more than one.
pub fn for_fields(ctx: *Ctx, added: []const []const u8) Error![]const hint.Hinted {
    std.debug.assert(added.len <= 1 << 16);
    @setEvalBranchQuota(registry.SDK.operations.len * 1024);

    var found: std.ArrayList(hint.Hinted) = .empty;

    for (added) |field| {
        inline for (registry.SDK.operations) |Operation| {
            if (comptime hint.hint_of(Operation)) |its| {
                if (hint.names(its, field)) {
                    try add(ctx, &found, field, its.says, Operation.name);
                }
            }
        }

        const installed = ctx.sandboxed_plugins orelse continue;

        for (installed.manifests()) |manifest| {
            for (manifest.operations) |operation| {
                const its: hint.Hint = .{
                    .fields = operation.hint_fields,
                    .says = operation.hint_says,
                };

                if (its.fields.len > 0 and hint.names(its, field)) {
                    try add(ctx, &found, field, its.says, operation.name);
                }
            }
        }
    }

    return found.items;
}

fn add(
    ctx: *Ctx,
    found: *std.ArrayList(hint.Hinted),
    field: []const u8,
    says: []const u8,
    operation: []const u8,
) Error!void {
    std.debug.assert(field.len > 0);
    std.debug.assert(operation.len > 0);

    if (found.items.len == hinted_max) {
        return;
    }

    const dot = std.mem.lastIndexOfScalar(u8, operation, '.') orelse operation.len;
    const see = if (dot == operation.len)
        operation
    else
        try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ operation[0..dot], operation[dot + 1 ..] });

    try found.append(ctx.arena, .{
        .field = field,
        .says = says,
        .see = see,
    });
}

/// The names of `fields` that `before` does not hold: what a change adds.
pub fn added_names(
    arena: std.mem.Allocator,
    fields: anytype,
    before: anytype,
) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;

    for (fields) |field| {
        const held = for (before) |old| {
            if (std.mem.eql(u8, old.name, field.name)) break true;
        } else false;

        if (!held) {
            try names.append(arena, field.name);
        }
    }

    return names.items;
}
