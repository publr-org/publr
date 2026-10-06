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
                    try refuse_taken(ctx, row, field, values.pending);
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

        fn check_references(ctx: *Ctx, row: Record, slot: []const u8) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(slot.len > 0);

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const parsed = try document.document_of(ctx, row.id, slot, type_row.def);
            try document.refuse_unpublished_targets(ctx, type_row.def, parsed);
        }

        /// A slug or unique value in `slot` held live by another document is refused: a
        /// parked one was checked when it was typed and is checked again as it goes live.
        fn refuse_taken(
            ctx: *Ctx,
            row: Record,
            field: model.field.Def,
            slot: []const u8,
        ) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(field.name.len > 0);

            const type_id = row.type_id;
            const name = field.name;
            const kind = registry.Kinds.find_kind(field.kind) orelse return;
            const holder = if (kind.storage == .int) blk: {
                const id = row.id;
                const parked = try values.read_integer(ctx.db, ctx.arena, id, slot, name) orelse {
                    return;
                };

                break :blk try values.find_by_integer(ctx.db, ctx.arena, type_id, name, parked, id);
            } else blk: {
                const parked = try values.read_text(ctx.db, ctx.arena, row.id, slot, name) orelse {
                    return;
                };

                const id = row.id;

                break :blk try values.find_by_text(ctx.db, ctx.arena, type_id, name, parked, id);
            };

            if (holder != null and !std.mem.eql(u8, holder.?, row.id)) {
                return error.Conflict;
            }
        }

        /// What a document was before something other than these operations replaced its
        /// rows (a merge, a rollback): its status and its live document as JSON text.
        pub const Before = struct { status: []const u8, live: ?[]const u8 };

        /// Taken before the rows are replaced; null when the document is not there.
        pub fn landing(ctx: *Ctx, id: []const u8) Error!?Before {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const row = try documents.get(ctx.db, ctx.arena, id) orelse return null;
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;

            return .{ .status = row.status, .live = try live_text(ctx, row, type_row.def) };
        }

        /// After the rows were replaced, everything a person making the same move gets: the
        /// checks of going live (slugs and unique values free, targets live), the revision of
        /// the live document replaced, and the notices. A refused check fails the write.
        /// Called once every document of the write is in place, so targets written in the
        /// same write count.
        pub fn landed(ctx: *Ctx, id: []const u8, before: ?Before) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const found = try documents.get(ctx.db, ctx.arena, id);
            const row = found orelse {
                if (before != null) {
                    ctx.notice(notice_name("purged"), id);
                }

                return;
            };
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const def = type_row.def;
            const live = registry.Statuses.is_live(row.status);

            try rewrite_copies(ctx, row, def);

            if (live) {
                try check_live(ctx, row, def);
            }

            const was = before orelse {
                ctx.notice(notice_name("created"), row.id);

                if (live) {
                    ctx.notice(notice_name("published"), row.id);
                }

                return;
            };

            try announce(ctx, row, def, was);
        }

        /// Each copy written again from its document: what is derived from the values
        /// (search text) follows what was written, whichever side each value came from.
        fn rewrite_copies(ctx: *Ctx, row: Record, def: store.definitions.Def) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            for ([_][]const u8{ values.live, values.pending }) |slot| {
                if (!try values.has_slot(ctx.db, row.id, slot)) {
                    continue;
                }

                const copy = try document.document_of(ctx, row.id, slot, def);
                const kinds = registry.Kinds.all;

                try values.write(kinds, ctx.db, row.id, slot, row.type_id, def.fields, copy);
            }
        }

        fn check_live(ctx: *Ctx, row: Record, def: store.definitions.Def) Error!void {
            std.debug.assert(registry.Statuses.is_live(row.status));
            std.debug.assert(def.fields.len <= model.field.fields_max);

            for (def.fields) |field| {
                if (field.unique or model.field.is_slug(field.kind)) {
                    try refuse_taken(ctx, row, field, values.live);
                }
            }

            try check_references(ctx, row, values.live);
        }

        /// The revision of the live document replaced, and the notices of the move.
        fn announce(ctx: *Ctx, row: Record, def: store.definitions.Def, was: Before) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(was.status.len > 0);

            const live = registry.Statuses.is_live(row.status);
            const now = try live_text(ctx, row, def);
            const replaced = if (was.live) |old|
                now == null or !std.mem.eql(u8, old, now.?)
            else
                now != null;

            if (replaced and was.live != null) {
                const actor = ctx.caller.user_id();
                const kind = store.snapshots.revision;

                _ = try store.snapshots.take(ctx.db, row.id, kind, ctx.now_ms, actor, was.live.?);
            }

            ctx.notice(notice_name("saved"), row.id);

            if (!std.mem.eql(u8, was.status, row.status)) {
                notify_transition(ctx, row.id, was.status, row.status);
            } else if (live and replaced) {
                ctx.notice(notice_name("published"), row.id);
            }
        }

        fn live_text(ctx: *Ctx, row: Record, def: store.definitions.Def) Error!?[]const u8 {
            std.debug.assert(row.id.len > 0);

            if (!try values.has_slot(ctx.db, row.id, values.live)) {
                return null;
            }

            const live = try document.document_of(ctx, row.id, values.live, def);

            return std.json.Stringify.valueAlloc(ctx.arena, live, .{}) catch error.OutOfMemory;
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

            return move(ctx, row, to, expected, granted, .apply_pending);
        }

        /// Whether `row` may end in status `to`: its own status again, or a registered move
        /// the type accepts and the grant allows. Refused before anything is written.
        pub fn check_move(
            row: Record,
            def: store.definitions.Def,
            to: []const u8,
            granted: *const Grant,
        ) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(to.len > 0);

            const staying = std.mem.eql(u8, row.status, to);

            if (!staying and !registry.Statuses.allows(row.status, to)) {
                return error.Invalid;
            }

            try check_status(def, to, granted);

            if (!granted.allows_transition(row.status, to)) {
                return error.Denied;
            }
        }

        /// Moves a record that was just saved straight into its live document: its pending
        /// copy, if any, stays pending.
        pub fn settle(
            ctx: *Ctx,
            row: Record,
            to: []const u8,
            granted: *const Grant,
        ) Error!Moved {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(!std.mem.eql(u8, row.status, to));

            return move(ctx, row, to, null, granted, .keep_pending);
        }

        const Pending = enum { apply_pending, keep_pending };

        fn move(
            ctx: *Ctx,
            row: Record,
            to: []const u8,
            expected: ?i64,
            granted: *const Grant,
            pending: Pending,
        ) Error!Moved {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(to.len > 0);

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const applying = pending == .apply_pending and row.changed;

            try check_move(row, type_row.def, to, granted);

            if (std.mem.eql(u8, row.status, to)) {
                return error.Invalid;
            }

            if (registry.Statuses.is_live(to)) {
                try check_references(ctx, row, if (applying) values.pending else values.live);
            }

            const applied = if (registry.Statuses.is_live(to) and applying)
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
                return move(ctx, row, "published", expected, granted, .apply_pending);
            }

            if (!row.changed) {
                return error.Invalid;
            }

            if (!granted.allows_transition(row.status, row.status)) {
                return error.Denied;
            }

            try check_references(ctx, row, values.pending);
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

            return move(ctx, row, "deleted", expected, granted, .apply_pending);
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
