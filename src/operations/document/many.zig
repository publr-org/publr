//! Many documents moved to one status at once: every one a list's conditions keep. They are
//! read a part at a time, each checked as a move of its own is (a registered move, a status
//! the type takes, the grant), the caller's intrinsic hooks run over the part, and the part
//! is moved by one statement and handed to the event hooks together. A document that may
//! not move is reported and the rest go on. Pending changes going live are applied one by
//! one: each keeps its old live copy as a revision.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Match = store.documents.Match;
const Record = store.documents.Record;
const Refusals = @import("../../sdk/bulk.zig").Refusals;

/// Documents read and moved at a time: what one part's working memory holds.
pub const part_max: u32 = 100;
/// Failures reported by name; past it, only counted.
pub const failed_kept_max: u32 = 100;
/// Parts one move goes through at most: a million documents.
pub const parts_max: u32 = 10_000;

pub const Failed = struct {
    id: []const u8,
    title: []const u8,
    why: []const u8,
};

pub const Outcome = struct {
    moved: u32 = 0,
    not_moved: u32 = 0,
    failed: []const Failed = &.{},
};

/// What the caller's intrinsic hooks make of each document about to move, and of each
/// moved: a refusal by position, for the ones not refused yet.
pub const Hooks = struct {
    before: *const Hook,
    after: *const Hook,
};

pub const Hook = fn (
    ctx: *Ctx,
    ids: []const []const u8,
    name: []const u8,
    to: []const u8,
    refused: Refusals,
) Error!void;

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;
        const lifecycle = Domain.lifecycle;
        const document = Domain.document;
        const check_status = Domain.access.check_status;

        /// Every document `query` keeps moved to `to`; the ones in `to` already are left out
        /// by the caller's query.
        /// Every record `query` keeps, moved by the transition `name` into `to` (where that
        /// transition leads); one whose status it does not leave is refused.
        pub fn move(
            ctx: *Ctx,
            granted: *const Grant,
            query: store.documents.Query,
            name: []const u8,
            to: []const u8,
            hooks: ?Hooks,
        ) Error!Outcome {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(to.len > 0);

            if (to.len > model.status.id_len_max) {
                return error.Invalid;
            }

            if (try @import("../status.zig").find(ctx, to) == null) {
                return error.Invalid;
            }

            // Each part reads its types again: decoded once for the whole move, when the
            // caller has no cache of its own (the CLI, a test).
            var cache: sdk.DefinitionCache = .{};
            const cached = ctx.definitions == null;

            if (cached) {
                _ = try ctx.scratch();
                cache.begin(ctx.arena);
                ctx.definitions = &cache;
            }

            defer if (cached) {
                ctx.definitions = null;
                cache.end();
            };

            var outcome: Outcome = .{};
            var failed: std.ArrayList(Failed) = .empty;
            var position: i64 = 0;
            var parts: u32 = 0;

            _ = try documents.gather(ctx.db, ctx.arena, query);
            defer documents.release(ctx.db) catch |err| {
                std.log.warn("move: the gathered documents not released: {t}", .{err});
            };

            while (parts < parts_max) : (parts += 1) {
                const read = try move_part(ctx, granted, .{
                    .after = position,
                    .name = name,
                    .to = to,
                    .hooks = hooks,
                }, &outcome, &failed);

                if (read.count == 0) {
                    break;
                }

                std.debug.assert(read.last > position);
                position = read.last;

                if (read.count < part_max) {
                    break;
                }
            }

            outcome.failed = failed.items;

            return outcome;
        }

        const Read = struct {
            count: u32,
            last: i64,
        };

        /// One part, its working memory the request's scratch, given back once it is moved:
        /// only failures stay in the arena. Answers how many it read and the last id.
        const Part = struct {
            after: i64,
            name: []const u8,
            to: []const u8,
            hooks: ?Hooks,
        };

        fn move_part(
            ctx: *Ctx,
            granted: *const Grant,
            part: Part,
            outcome: *Outcome,
            failed: *std.ArrayList(Failed),
        ) Error!Read {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(part.after >= 0);

            const kept = ctx.arena;
            const scratch = try ctx.scratch();
            const begun = scratch.mark();

            ctx.arena = scratch.allocator();
            defer {
                ctx.arena = kept;
                scratch.rewind(begun);
            }

            const rows = try documents.gathered(ctx.db, ctx.arena, part.after, part_max);

            if (rows.len == 0) {
                return .{
                    .count = 0,
                    .last = part.after,
                };
            }

            const refused = try checked(ctx, granted, rows, part.name, part.to);

            if (part.hooks) |given| {
                try given.before(ctx, try ids_of(ctx.arena, rows), part.name, part.to, refused);
            }

            try write_part(ctx, rows, part, refused);
            try note_failures(kept, rows, refused, outcome, failed);

            return .{
                .count = @intCast(rows.len),
                .last = rows[rows.len - 1].position,
            };
        }

        /// Why each row may not move, as `transition` would refuse it; null for the others.
        fn checked(
            ctx: *Ctx,
            granted: *const Grant,
            rows: []const Match,
            name: []const u8,
            to: []const u8,
        ) Error!Refusals {
            std.debug.assert(rows.len > 0 and rows.len <= part_max);
            std.debug.assert(to.len > 0);

            const refused = ctx.arena.alloc(?[]const u8, rows.len) catch return error.OutOfMemory;

            for (rows, refused) |row, *reason| {
                reason.* = try refusal_of(ctx, granted, row, name, to);
            }

            return refused;
        }

        fn refusal_of(
            ctx: *Ctx,
            granted: *const Grant,
            row: Match,
            name: []const u8,
            to: []const u8,
        ) Error!?[]const u8 {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(!std.mem.eql(u8, row.status, to));

            if (!granted.record_filter.accepts(ctx, row.created_by)) {
                return "You may not change it";
            }

            const type_row = try definitions.find(ctx, row.type_id) orelse {
                return "Its type is gone";
            };

            const target = type_row.def.flow.named(name, row.status);

            if (target == null or !std.mem.eql(u8, target.?.to, to)) {
                return "Not a transition its status allows";
            }

            if (!lifecycle.passes(ctx, target.?.authorize)) {
                return "You may not make this transition";
            }

            const flow = type_row.def.flow;
            const publishing = lifecycle.requests.needs_publish(flow, row.status, to);

            if (publishing and !lifecycle.requests.may_publish(ctx, type_row.def.handle)) {
                return "Needs someone who may publish";
            }

            check_status(type_row.def, to) catch {
                return "Its type does not take that status";
            };

            if (type_row.def.flow.is_live(to)) {
                return try live_refusal(ctx, row, type_row.def);
            }

            return null;
        }

        /// Going live: a reference to a document not live is refused, as on its own.
        fn live_refusal(ctx: *Ctx, row: Match, def: store.definitions.Def) Error!?[]const u8 {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(def.handle.len > 0);

            const targets = model.field.contains_kind(def.fields, "reference") or
                model.field.contains_kind(def.fields, "user");

            if (!targets) {
                return null;
            }

            const slot = if (row.changed) values.pending else values.live;

            lifecycle.check_references(ctx, record_of(row), slot) catch |err| {
                if (err == error.OutOfMemory) {
                    return err;
                }

                ctx.failure = null;

                return "It points to something not published";
            };

            return null;
        }

        /// The rows not refused moved by one statement; pending changes going live applied
        /// first, each on its own; the moves' events handed on together; the `after` hooks
        /// over the moved, and a part whose hook refuses one moved again without it.
        fn write_part(ctx: *Ctx, rows: []const Match, part: Part, refused: Refusals) Error!void {
            std.debug.assert(rows.len == refused.len);
            std.debug.assert(rows.len > 0);

            const to = part.to;
            var attempts: u32 = 0;

            while (attempts <= part_max) : (attempts += 1) {
                var savepoint = try ctx.db.transaction();
                errdefer savepoint.rollback();

                const before = count_null(refused);

                try write_once(ctx, rows, to, refused);

                if (part.hooks) |given| {
                    try given.after(ctx, try ids_of(ctx.arena, rows), part.name, to, refused);
                }

                if (count_null(refused) == before) {
                    try savepoint.commit();
                    return;
                }

                savepoint.rollback();
            }

            unreachable;
        }

        fn write_once(
            ctx: *Ctx,
            rows: []const Match,
            to: []const u8,
            refused: Refusals,
        ) Error!void {
            std.debug.assert(rows.len == refused.len);
            std.debug.assert(to.len > 0);

            var moving: std.ArrayList([]const u8) = .empty;
            var applied: std.ArrayList([]const u8) = .empty;
            var events: std.ArrayList(sdk.Event.Emitted) = .empty;

            for (rows, refused) |row, reason| {
                if (reason != null) {
                    continue;
                }

                // A row not refused has its type: `refusal_of` read it.
                const type_row = try definitions.find(ctx, row.type_id) orelse unreachable;
                const flow = type_row.def.flow;

                moving.append(ctx.arena, row.id) catch return error.OutOfMemory;

                if (flow.is_live(to) and row.changed) {
                    if (try lifecycle.apply_pending(ctx, record_of(row))) {
                        applied.append(ctx.arena, row.id) catch return error.OutOfMemory;
                    }
                }

                try add_event(ctx, &events, type_row.def, row, to);
            }

            if (moving.items.len == 0) {
                return;
            }

            const moved = try documents.set_status_many(
                ctx.db,
                try sdk.stringify(ctx.arena, moving.items),
                try sdk.stringify(ctx.arena, applied.items),
                to,
                ctx.now_ms,
                ctx.caller.user_id(),
            );

            std.debug.assert(moved == moving.items.len);

            try registry.SDK.events.hand_many(ctx, events.items);
        }

        /// The record's own transition events (`post.transitioned`, and a plugin type's
        /// named one, `shop.order_ship`), as a move of its own raises them: each record's
        /// facts in a write over many.
        fn add_event(
            ctx: *Ctx,
            events: *std.ArrayList(sdk.Event.Emitted),
            def: store.definitions.Def,
            row: Match,
            to: []const u8,
        ) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.parent != null);

            const heard = try lifecycle.transition_heard(ctx, def, row.id, row.status, to);
            const subject = try sdk.stringify(ctx.arena, heard.payload);

            lifecycle.mark_live_change(ctx, def.flow, row.status, to);
            events.append(ctx.arena, .{
                .operation_id = ctx.parent.?,
                .name = heard.name,
                .subject = subject,
            }) catch return error.OutOfMemory;

            if (heard.named.len > 0) {
                events.append(ctx.arena, .{
                    .operation_id = ctx.parent.?,
                    .name = heard.named,
                    .subject = subject,
                }) catch return error.OutOfMemory;
            }
        }

        fn note_failures(
            kept: std.mem.Allocator,
            rows: []const Match,
            refused: Refusals,
            outcome: *Outcome,
            failed: *std.ArrayList(Failed),
        ) Error!void {
            std.debug.assert(rows.len == refused.len);
            std.debug.assert(failed.items.len <= failed_kept_max);

            for (rows, refused) |row, reason| {
                const why = reason orelse {
                    outcome.moved += 1;
                    continue;
                };

                outcome.not_moved += 1;

                if (failed.items.len < failed_kept_max) {
                    failed.append(kept, .{
                        .id = kept.dupe(u8, row.id) catch return error.OutOfMemory,
                        .title = kept.dupe(u8, row.title orelse "") catch return error.OutOfMemory,
                        .why = kept.dupe(u8, why) catch return error.OutOfMemory,
                    }) catch return error.OutOfMemory;
                }
            }
        }
    };
}

/// What a move reads of a document, as the record the single moves take.
fn record_of(row: Match) Record {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.type_id.len > 0);

    return .{
        .id = row.id,
        .type_id = row.type_id,
        .type = "",
        .status = row.status,
        .changed = row.changed,
        .version = 0,
        .title = row.title orelse "",
        .slug = null,
        .created_by = row.created_by,
        .updated_by = null,
        .created_at = 0,
        .updated_at = 0,
    };
}

fn ids_of(arena: std.mem.Allocator, rows: []const Match) Error![]const []const u8 {
    std.debug.assert(rows.len > 0);
    std.debug.assert(rows.len <= part_max);

    const ids = arena.alloc([]const u8, rows.len) catch return error.OutOfMemory;

    for (rows, ids) |row, *id| {
        id.* = row.id;
    }

    return ids;
}

fn count_null(refused: Refusals) u32 {
    std.debug.assert(refused.len <= part_max);

    var count: u32 = 0;

    for (refused) |reason| {
        if (reason == null) {
            count += 1;
        }
    }

    std.debug.assert(count <= refused.len);

    return count;
}
