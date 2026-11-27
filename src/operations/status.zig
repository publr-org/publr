const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/status.zig");
const registry = @import("../server/registry.zig");
const status = @import("../model/status.zig");
const model_flow = @import("../model/flow.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(status.core_transitions.len > 0);

        return .{
            .statuses = try known(ctx),
            .transitions = &status.core_transitions,
        };
    }
};

/// The statuses plugins add to other plugins' flows: the compiled-in ones' and, with the
/// installed plugins at hand, each granted one of theirs.
pub fn added_statuses(ctx: *const Ctx) []const model_flow.Added {
    std.debug.assert(ctx.now_ms >= 0);

    const sandboxed = ctx.sandboxed_plugins orelse return registry.registered_statuses;
    const merged = sandboxed.statuses() orelse registry.registered_statuses;

    std.debug.assert(merged.len >= registry.registered_statuses.len);

    return merged;
}

/// How many records wait as drafts, on every type.
pub fn drafts_waiting(ctx: *Ctx) Error!u32 {
    std.debug.assert(ctx.now_ms >= 0);

    return store.records.count_in_status(ctx.db, "draft") catch error.Failed;
}

/// Every status the site knows: core's, then each type's own. A type's own ids are named
/// under it, so an id is enough to find one.
pub fn known(ctx: *Ctx) Error![]const status.Status {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(status.core_statuses.len > 0);

    const stored = try store.content_types.own_statuses(ctx.db, ctx.arena);
    // The statuses a site added to a type's flow (`flow add_status`) are a type's own too.
    const own = std.mem.concat(ctx.arena, status.Status, &.{
        stored,
        try @import("flow.zig").site_statuses(ctx),
    }) catch return error.OutOfMemory;
    const added = added_statuses(ctx);
    const core_len = status.core_statuses.len;
    const all = ctx.arena.alloc(status.Status, core_len + own.len + added.len) catch {
        return error.OutOfMemory;
    };

    @memcpy(all[0..core_len], &status.core_statuses);
    @memcpy(all[core_len .. core_len + own.len], own);

    for (added, all[core_len + own.len ..]) |entry, *slot| {
        slot.* = entry.status;
    }

    status.resolve_aliases(all);

    return all;
}

/// The status called `id`, core's or a type's; null for one the site does not know.
pub fn find(ctx: *Ctx, id: []const u8) Error!?status.Status {
    std.debug.assert(id.len > 0);

    return find_in(try known(ctx), id);
}

pub fn find_in(statuses: []const status.Status, id: []const u8) ?status.Status {
    std.debug.assert(id.len > 0);
    std.debug.assert(statuses.len >= status.core_statuses.len);

    for (statuses) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) {
            return candidate;
        }
    }

    return null;
}

/// Whether records in `id` are visitors' to see.
pub fn is_live(ctx: *Ctx, id: []const u8) Error!bool {
    std.debug.assert(id.len > 0);

    const found = try find(ctx, id) orelse return false;

    return found.live;
}

pub const operations = [_]type{List};
