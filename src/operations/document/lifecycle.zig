//! The status moves: transition, publish (pending edits applied), discard, delete, purge.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Record = store.documents.Record;

pub const Moved = struct { status: []const u8, changed: bool, version: i64 };

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;
        const document = Domain.document;
        const load = Domain.access.load;
        const check_status = Domain.access.check_status;
        const notice_name = Domain.notice_name;

        /// Make the pending copy the live document (if there is one) and drop the mark.
        fn apply_pending(ctx: *Ctx, row: Record) Error!bool {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (!row.changed) {
                return false;
            }

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;

            for (type_row.def.fields) |field| {
                if (field.unique or model.field.is_slug(field.kind)) {
                    try refuse_taken(ctx, row, field);
                }
            }

            try document.snapshot_live(ctx, row, type_row.def);

            const promoted = try values.promote(ctx.db, row.id, values.pending, values.live);

            if (!promoted) {
                // `changed` also represents an intentionally empty pending document.
                try values.clear(ctx.db, row.id, values.live);
            }

            ctx.notice(notice_name("saved"), row.id);

            return true;
        }

        fn check_references(ctx: *Ctx, row: Record) Error!void {
            std.debug.assert(row.id.len > 0);
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const slot = if (row.changed) values.pending else values.live;
            const parsed = try document.document_of(ctx, row.id, slot, type_row.def);
            try document.refuse_unpublished_targets(ctx, type_row.def, parsed);
        }

        /// A parked slug or unique value was checked against live values when it was
        /// typed; check again now.
        fn refuse_taken(ctx: *Ctx, row: Record, field: model.field.Def) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(field.name.len > 0);

            const slot = values.pending;
            const type_id = row.type_id;
            const name = field.name;
            const kind = registry.Kinds.find_kind(field.kind) orelse return;
            const holder = if (kind.storage == .int) blk: {
                const id = row.id;
                const parked = try values.read_integer(ctx.db, ctx.arena, id, slot, name) orelse {
                    return;
                };

                break :blk try values.find_by_integer(ctx.db, ctx.arena, type_id, name, parked);
            } else blk: {
                const parked = try values.read_text(ctx.db, ctx.arena, row.id, slot, name) orelse {
                    return;
                };

                break :blk try values.find_by_text(ctx.db, ctx.arena, type_id, name, parked);
            };

            if (holder != null and !std.mem.eql(u8, holder.?, row.id)) {
                return error.Conflict;
            }
        }

        /// The outcome notice of a status move, if the move has a name of its own.
        fn notify_transition(ctx: *Ctx, id: []const u8, from: []const u8, to: []const u8) void {
            std.debug.assert(id.len > 0);
            std.debug.assert(!std.mem.eql(u8, from, to) or from.len > 0);

            ctx.notice(notice_name("transitioned"), id);

            const from_live = registry.Statuses.is_live(from);
            const to_live = registry.Statuses.is_live(to);

            if (to_live and !from_live) {
                ctx.notice(notice_name("published"), id);
            } else if (from_live and !to_live) {
                ctx.notice(notice_name("unpublished"), id);
            }

            if (std.mem.eql(u8, to, "archived")) {
                ctx.notice(notice_name("archived"), id);
            } else if (std.mem.eql(u8, to, "deleted")) {
                ctx.notice(notice_name("deleted"), id);
            } else if (std.mem.eql(u8, from, "archived") or std.mem.eql(u8, from, "deleted")) {
                ctx.notice(notice_name("restored"), id);
            }
        }

        pub fn transition(
            ctx: *Ctx,
            granted: *const Grant,
            id: []const u8,
            to: []const u8,
            expected: ?i64,
        ) Error!Moved {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (to.len == 0 or to.len > model.status.id_len_max) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;

            return move(ctx, row, to, expected, granted);
        }

        fn move(
            ctx: *Ctx,
            row: Record,
            to: []const u8,
            expected: ?i64,
            granted: *const Grant,
        ) Error!Moved {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(to.len > 0);

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;

            if (!registry.Statuses.allows(row.status, to)) {
                return error.Invalid;
            }

            try check_status(type_row.def, to, granted);

            if (!granted.allows_transition(row.status, to)) {
                return error.Denied;
            }

            if (registry.Statuses.is_live(to)) {
                try check_references(ctx, row);
            }

            const applied = if (registry.Statuses.is_live(to))
                try apply_pending(ctx, row)
            else
                false;
            const changed = row.changed and !applied;
            const actor = ctx.caller.user_id();
            const version = try documents.set_status(
                ctx.db,
                row.id,
                to,
                expected,
                ctx.now_ms,
                actor,
                changed,
            );

            notify_transition(ctx, row.id, row.status, to);

            return .{ .status = to, .changed = changed, .version = version };
        }

        pub fn publish(
            ctx: *Ctx,
            granted: *const Grant,
            id: []const u8,
            expected: ?i64,
        ) Error!Moved {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (id.len > 128) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;

            if (!registry.Statuses.is_live(row.status)) {
                return move(ctx, row, "published", expected, granted);
            }

            if (!row.changed) {
                return error.Invalid;
            }

            if (!granted.allows_transition(row.status, row.status)) {
                return error.Denied;
            }

            try check_references(ctx, row);
            _ = try apply_pending(ctx, row);

            const actor = ctx.caller.user_id();
            const version = try documents.save(ctx.db, row.id, actor, expected, ctx.now_ms, false);

            ctx.notice(notice_name("published"), row.id);

            return .{ .status = row.status, .changed = false, .version = version };
        }

        pub fn discard(ctx: *Ctx, granted: *const Grant, id: []const u8, expected: ?i64) Error!i64 {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (id.len > 128) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;

            if (!row.changed) {
                return error.Invalid;
            }

            try values.clear(ctx.db, row.id, values.pending);

            const actor = ctx.caller.user_id();
            const version = try documents.save(ctx.db, row.id, actor, expected, ctx.now_ms, false);

            ctx.notice(notice_name("changes_discarded"), row.id);

            return version;
        }

        pub fn delete(
            ctx: *Ctx,
            granted: *const Grant,
            id: []const u8,
            expected: ?i64,
        ) Error!Moved {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (id.len > 128) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;

            return move(ctx, row, "deleted", expected, granted);
        }

        pub fn purge(ctx: *Ctx, granted: *const Grant, id: []const u8) Error!bool {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (id.len > 128) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;

            try document.unlink_or_block(ctx, row.id);

            _ = try store.snapshots.delete_all(ctx.db, row.id);

            const purged = try documents.delete(ctx.db, row.id);

            ctx.notice(notice_name("purged"), row.id);

            return purged;
        }
    };
}
