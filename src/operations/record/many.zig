//! Many records moved at once: the ones named, or every one a list's conditions keep.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../record.zig");
const crud_module = @import("../document/crud.zig");
const many_module = @import("../document/many.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Transition = record_operations.Transition;
const Refusals = @import("../../sdk/bulk.zig").Refusals;
const part_max = many_module.part_max;

pub const TransitionMany = struct {
    pub const name = "record.transition_many";
    pub const description = "Move many records by one transition: the ones named, or " ++
        "every record a list's filters keep";
    pub const details =
        \\Either name the records (`ids`) or set `matching` with the conditions `record
        \\list` takes (`type`, `types`, `filters`, `search`): every record they keep moves,
        \\in one call, whatever their number. The transition is named, as `record
        \\transition` takes it, and leads to one status in every type it reaches; records
        \\already there are left out. Each is checked as `record transition` checks it, and
        \\one that may not move is reported in `failed` (the first 100 by name, all in
        \\`not_moved`) while the rest go on. Pending edits of records going live are applied,
        \\as `record publish` does.
        \\Hooks on `record transition` run for each record; event hooks hear each record's
        \\events as if it had moved on its own. `restore` and `destroy` run `record
        \\transition` on each record in the trash, one at a time, so each goes back to the
        \\status it had, as on its own; the others are not moved.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        transition: []const u8,
        ids: []const []const u8 = &.{},
        matching: bool = false,
        type: ?[]const u8 = null,
        types: []const []const u8 = &.{},
        filters: []const []const u8 = &.{},
        search: ?[]const u8 = null,
    };
    pub const Failed = many_module.Failed;
    pub const Out = struct {
        moved: u32,
        not_moved: u32,
        failed: []const Failed,
    };
    pub const example: In = .{
        .transition = "archive",
        .matching = true,
        .type = "post",
        .filters = &.{"updated:before:2025-01-01"},
    };
    pub const example_out: Out = .{
        .moved = 1768,
        .not_moved = 0,
        .failed = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .transition = "The transition's name, `archive`",
        .ids = "The records to move, by id",
        .matching = "Move every record the conditions keep instead of named ones",
        .type = "With `matching`: one content type, by handle or id",
        .types = "With `matching`: several content types; neither: every regular type",
        .filters = "With `matching`: clauses as `record list` takes them",
        .search = "With `matching`: full-text query over searchable fields",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .moved = "How many records moved",
        .not_moved = "How many could not move",
        .failed = "The first 100 that could not move, and why",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const named = in.ids.len > 0;

        if (in.transition.len == 0 or named == in.matching) {
            return error.Invalid;
        }

        const one_by_one = std.mem.eql(u8, in.transition, "destroy") or
            std.mem.eql(u8, in.transition, "restore");
        const to = if (one_by_one) model.flow.trashed else try target_of(ctx, in);

        const input: crud_module.ListInput = .{
            .definition = if (named) null else in.type,
            .definitions = if (named) &.{} else in.types,
            .filters = if (named) &.{} else in.filters,
            .search = if (named) null else in.search,
            .ids = in.ids,
            .exclude_statuses = if (one_by_one) &.{} else &.{to},
            .limit = store.records.list_max,
        };
        const domain = record_operations.domain;
        const query = try domain.crud.matching_query(ctx, granted, input) orelse return .{
            .moved = 0,
            .not_moved = 0,
            .failed = &.{},
        };

        if (one_by_one) {
            return each_in_trash(ctx, query, in.transition);
        }

        const hooks: ?many_module.Hooks = if (registry.SDK.bulk.hooked(ctx, Transition)) .{
            .before = &before,
            .after = &after,
        } else null;
        const outcome = try domain.many.move(ctx, granted, query, in.transition, to, hooks);

        return .{
            .moved = outcome.moved,
            .not_moved = outcome.not_moved,
            .failed = outcome.failed,
        };
    }

    /// Each record the query keeps restored or destroyed on its own, its hooks and all; one
    /// not in the trash, or whose destroy waits for a person, is not moved.
    fn each_in_trash(
        ctx: *Ctx,
        query: store.documents.Query,
        transition_name: []const u8,
    ) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(transition_name.len > 0);

        const destroying = std.mem.eql(u8, transition_name, "destroy");

        // Read whole before any is moved: a hook's own bulk move gathers again.
        _ = try store.records.gather(ctx.db, ctx.arena, query);

        var rows: std.ArrayList(store.records.Match) = .empty;
        var position: i64 = 0;

        while (true) {
            const part = try store.records.gathered(ctx.db, ctx.arena, position, part_max);

            rows.appendSlice(ctx.arena, part) catch return error.OutOfMemory;

            if (part.len < part_max) {
                break;
            }

            position = part[part.len - 1].position;
        }

        try store.records.release(ctx.db);

        var failed: std.ArrayList(Failed) = .empty;
        var out: Out = .{
            .moved = 0,
            .not_moved = 0,
            .failed = &.{},
        };

        for (rows.items) |row| {
            const moved = registry.SDK.dispatch(ctx, Transition, .{
                .id = row.id,
                .transition = transition_name,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    ctx.failure = null;
                    break :blk null;
                },
            };

            const status = if (moved) |out_of| out_of.status else model.flow.trashed;
            const gone = if (destroying)
                std.mem.eql(u8, status, "destroyed")
            else
                !std.mem.eql(u8, status, model.flow.trashed);

            if (gone) {
                out.moved += 1;
                continue;
            }

            out.not_moved += 1;

            if (failed.items.len == many_module.failed_kept_max) {
                continue;
            }

            failed.append(ctx.arena, .{
                .id = row.id,
                .title = row.title orelse "",
                .why = if (moved == null) "Not in the trash" else "Waits for a person",
            }) catch return error.OutOfMemory;
        }

        out.failed = failed.items;

        return out;
    }

    /// Where the transition leads in the types it reaches: one status, or the call is
    /// invalid (no type has it, or two lead it apart).
    fn target_of(ctx: *Ctx, in: In) Error![]const u8 {
        std.debug.assert(in.transition.len > 0);
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (std.mem.eql(u8, in.transition, "trash")) {
            return model.flow.trashed;
        }

        var found: ?[]const u8 = null;
        const handles = try handles_of(ctx, in);

        for (handles) |handle| {
            const type_row = try record_operations.domain.definition.find(ctx, handle) orelse {
                continue;
            };
            const flow = type_row.def.flow;
            const to = target_in(flow, in.transition) orelse continue;

            if (found != null and !std.mem.eql(u8, found.?, to)) {
                return error.Invalid;
            }

            found = to;
        }

        return found orelse error.Invalid;
    }

    fn target_in(flow: model.flow.Flow, transition_name: []const u8) ?[]const u8 {
        std.debug.assert(transition_name.len > 0);

        for (flow.listed()) |listed| {
            if (std.mem.eql(u8, listed.name, transition_name)) {
                return listed.to;
            }
        }

        return null;
    }

    /// The types the call reaches: named, the named records', or every regular type's.
    fn handles_of(ctx: *Ctx, in: In) Error![]const []const u8 {
        std.debug.assert(in.ids.len > 0 or in.matching);

        if (in.type) |handle| {
            return ctx.arena.dupe([]const u8, &.{handle}) catch error.OutOfMemory;
        }

        if (in.types.len > 0) {
            return in.types;
        }

        var handles: std.ArrayList([]const u8) = .empty;

        if (in.ids.len > 0) {
            for (in.ids) |id| {
                const row = try store.records.get(ctx.db, ctx.arena, id) orelse continue;

                handles.append(ctx.arena, row.type_id) catch return error.OutOfMemory;
            }

            return handles.items;
        }

        const every: store.content_types.BriefKey = .{};
        const limit = store.content_types.list_max;
        const briefs = try store.content_types.briefs_after(ctx.db, ctx.arena, every, limit);

        for (briefs) |brief| {
            handles.append(ctx.arena, brief.handle) catch return error.OutOfMemory;
        }

        return handles.items;
    }

    /// The hooks on `record transition`, over a part of the records about to move.
    fn before(
        ctx: *Ctx,
        ids: []const []const u8,
        transition_name: []const u8,
        to: []const u8,
        refused: Refusals,
    ) Error!void {
        std.debug.assert(ids.len == refused.len);
        std.debug.assert(to.len > 0);

        const inputs = try inputs_of(ctx, ids, transition_name);

        try registry.SDK.bulk.before_each(ctx, Transition, inputs, refused);
    }

    /// The hooks on `record transition`, over a part moved, each with what it became.
    fn after(
        ctx: *Ctx,
        ids: []const []const u8,
        transition_name: []const u8,
        to: []const u8,
        refused: Refusals,
    ) Error!void {
        std.debug.assert(ids.len == refused.len);
        std.debug.assert(to.len > 0);

        const inputs = try inputs_of(ctx, ids, transition_name);
        const outputs = ctx.arena.alloc(Transition.Out, ids.len) catch return error.OutOfMemory;

        for (ids, refused, outputs) |id, reason, *output| {
            const found = if (reason == null)
                try store.records.get(ctx.db, ctx.arena, id)
            else
                null;

            output.* = if (found) |record| .{
                .status = record.status,
                .changed = record.changed,
                .version = record.version,
            } else .{
                .status = to,
                .changed = false,
                .version = 0,
            };
        }

        try registry.SDK.bulk.after_each(ctx, Transition, inputs, outputs, refused);
    }

    fn inputs_of(
        ctx: *Ctx,
        ids: []const []const u8,
        transition_name: []const u8,
    ) Error![]Transition.In {
        std.debug.assert(ids.len > 0);
        std.debug.assert(transition_name.len > 0);

        const inputs = ctx.arena.alloc(Transition.In, ids.len) catch return error.OutOfMemory;

        for (ids, inputs) |id, *input| {
            input.* = .{
                .id = id,
                .transition = transition_name,
            };
        }

        return inputs;
    }
};

const SDK = registry.SDK;

test "transition_many: named, every match in one call, refusals" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    var id_buffers: [many_module.part_max + 5][store.records.id_len]u8 = undefined;
    var ids: [many_module.part_max + 5][]const u8 = undefined;

    // Each made in an arena given back after it: the harness's is a few MiB for the test.
    for (&id_buffers, &ids, 0..) |*buffer, *id, index| {
        var document_buffer: [64]u8 = undefined;
        const shape = "{{\"title\":\"Many {d}\",\"body\":\"x\"}}";
        const document = try std.fmt.bufPrint(&document_buffer, shape, .{index});
        const mark = harness.fixed.end_index;
        const created = try SDK.dispatch(&editor, record_operations.Create, .{
            .type = "post",
            .document = document,
        });

        @memcpy(buffer, created.id[0..store.records.id_len]);
        id.* = buffer;
        harness.fixed.end_index = mark;
    }

    const named = try SDK.dispatch(&editor, TransitionMany, .{
        .transition = "archive",
        .ids = ids[0..2],
    });
    try std.testing.expectEqual(@as(u32, 2), named.moved);

    const unknown = SDK.dispatch(&editor, TransitionMany, .{
        .transition = "nowhere",
        .matching = true,
        .type = "post",
    });
    try std.testing.expectError(error.Invalid, unknown);

    // Past one part: every draft moves in the one call.
    const published = try SDK.dispatch(&editor, TransitionMany, .{
        .transition = "publish",
        .matching = true,
        .type = "post",
        .filters = &.{"status:is:draft"},
    });
    try std.testing.expectEqual(@as(u32, many_module.part_max + 3), published.moved);
    try std.testing.expectEqual(@as(u32, 0), published.not_moved);

    const listed = try SDK.dispatch(&editor, record_operations.List, .{
        .type = "post",
        .filters = &.{"status:is:published"},
        .limit = 1,
        .count = true,
    });
    try std.testing.expectEqual(@as(u32, many_module.part_max + 3), listed.total);

    // Archived records may not be published straight away: reported, not moved.
    const refused = try SDK.dispatch(&editor, TransitionMany, .{
        .transition = "publish",
        .ids = ids[0..2],
    });
    try std.testing.expectEqual(@as(u32, 0), refused.moved);
    try std.testing.expectEqual(@as(u32, 2), refused.not_moved);
    try std.testing.expectEqual(@as(usize, 2), refused.failed.len);

    const again = try SDK.dispatch(&editor, TransitionMany, .{
        .transition = "publish",
        .matching = true,
        .type = "post",
    });
    try std.testing.expectEqual(@as(u32, 0), again.moved);

    const both = SDK.dispatch(&editor, TransitionMany, .{
        .transition = "unpublish",
        .ids = ids[0..1],
        .matching = true,
    });
    try std.testing.expectError(error.Invalid, both);
    const neither = SDK.dispatch(&editor, TransitionMany, .{
        .transition = "unpublish",
    });
    try std.testing.expectError(error.Invalid, neither);
}
