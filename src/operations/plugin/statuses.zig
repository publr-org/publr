//! The statuses an installed plugin adds to other plugins' flows, when they go: revoked,
//! denied, the plugin disabled, removed or swapped for a version without them. Their
//! records leave first, in the same write, by the plugin's own way out of each.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const record_operations = @import("../record.zig");
const status_operations = @import("../status.zig");
const registry = @import("../../server/registry.zig");
const state = @import("state.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// Moves the records out of every status `name` adds now that `after` no longer grants:
/// all of them when `after` is null (the plugin stops or goes). Refused as a conflict when
/// a record may not leave, so the status never goes with records left in it.
pub fn leave(ctx: *Ctx, name: []const u8, after: ?*const state.Decoded) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    for (status_operations.added_statuses(ctx)) |added| {
        if (!std.mem.eql(u8, added.plugin, name) or try stays(ctx, added, after)) {
            continue;
        }

        try move_out(ctx, added);
    }
}

fn stays(ctx: *Ctx, added: model.flow.Added, after_or_null: ?*const state.Decoded) Error!bool {
    std.debug.assert(added.status.id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const after = after_or_null orelse return false;

    if (!after.row.enabled) {
        return false;
    }

    const key = try model.sandboxed_plugin.status_key(ctx.arena, added);
    const declared = for (after.manifest.statuses) |kept| {
        if (std.mem.eql(u8, kept.status.id, added.status.id)) {
            break true;
        }
    } else false;

    return declared and model.permission.contains(after.granted, key);
}

fn move_out(ctx: *Ctx, added: model.flow.Added) Error!void {
    std.debug.assert(added.to.len > 0);
    std.debug.assert(added.status.id.len > 0);

    const way = model.flow.way_out(added) orelse return error.Invalid;

    if (try record_operations.domain.definition.find(ctx, added.to) == null) {
        return;
    }

    const filter = std.fmt.allocPrint(ctx.arena, "status:is:{s}", .{added.status.id}) catch {
        return error.OutOfMemory;
    };
    const moved = try registry.SDK.call(ctx, record_operations.TransitionMany, .{
        .transition = way.name,
        .matching = true,
        .type = added.to,
        .filters = &.{filter},
    });

    if (moved.not_moved > 0) {
        return error.Conflict;
    }
}
