//! The status moves: transition, publish (pending edits applied), discard, delete, purge.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const operation_define = @import("../../sdk/plugin/operation_define.zig");
const flow_model = model.flow;

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Record = store.documents.Record;

pub const Moved = struct {
    status: []const u8,
    changed: bool,
    version: i64,
    /// Not made: it waits for a person (a destroy asked by code, an agent or a device).
    pending: bool = false,
};

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;
        const document = Domain.document;
        const load = Domain.access.load;
        const check_status = Domain.access.check_status;

        pub const requests = @import("requests.zig").Of(Domain);

        /// Make the pending copy the live document (if there is one) and drop the mark.
        pub fn apply_pending(ctx: *Ctx, row: Record) Error!bool {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (!row.changed) {
                return false;
            }

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;

            for (type_row.def.fields) |field| {
                if (field.validation.unique or model.field.is_slug(field.kind)) {
                    try refuse_taken(ctx, row, field, values.pending);
                }
            }

            try document.snapshot_live(ctx, row, type_row.def);

            const promoted = try values.promote(ctx.db, row.id, values.pending, values.live);

            if (!promoted) {
                // `changed` also represents an intentionally empty pending document.
                try values.clear(ctx.db, row.id, values.live);
            }

            return true;
        }

        pub fn check_references(ctx: *Ctx, row: Record, slot: []const u8) Error!void {
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
        pub const Before = struct {
            status: []const u8,
            live: ?[]const u8,
        };

        /// Taken before the rows are replaced; null when the document is not there.
        pub fn landing(ctx: *Ctx, id: []const u8) Error!?Before {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const row = try documents.get(ctx.db, ctx.arena, id) orelse return null;
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;

            return .{
                .status = row.status,
                .live = try live_text(ctx, row, type_row.def),
            };
        }

        /// After the rows were replaced, everything a person making the same move gets: the
        /// checks of going live (slugs and unique values free, targets live), the revision of
        /// the live document replaced, and the move's transition event. A refused check fails
        /// the write.
        /// Called once every document of the write is in place, so targets written in the
        /// same write count.
        pub fn landed(ctx: *Ctx, id: []const u8, before: ?Before) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const found = try documents.get(ctx.db, ctx.arena, id);
            const row = found orelse return;
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const def = type_row.def;
            const live = def.flow.is_live(row.status);

            try rewrite_copies(ctx, row, def);

            if (live) {
                try check_live(ctx, row, def);
            }

            const was = before orelse {
                ctx.publishes = ctx.publishes or live;
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

                try values.write(kinds, ctx, ctx.db, row.id, slot, row.type_id, def.fields, copy);
            }
        }

        fn check_live(ctx: *Ctx, row: Record, def: store.definitions.Def) Error!void {
            std.debug.assert(def.flow.is_live(row.status));
            std.debug.assert(def.fields.len <= model.field.fields_max);

            for (def.fields) |field| {
                if (field.validation.unique or model.field.is_slug(field.kind)) {
                    try refuse_taken(ctx, row, field, values.live);
                }
            }

            try check_references(ctx, row, values.live);
        }

        /// The revision of the live document replaced, and the transition event of the move.
        fn announce(ctx: *Ctx, row: Record, def: store.definitions.Def, was: Before) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(was.status.len > 0);

            const live = def.flow.is_live(row.status);
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

            if (std.mem.eql(u8, was.status, row.status)) {
                ctx.publishes = ctx.publishes or (live and replaced);
                return;
            }

            const heard = try transition_heard(ctx, def, row.id, was.status, row.status);

            mark_live_change(ctx, def.flow, was.status, row.status);
            ctx.emit_json(heard.name, heard.payload, false);
        }

        fn live_text(ctx: *Ctx, row: Record, def: store.definitions.Def) Error!?[]const u8 {
            std.debug.assert(row.id.len > 0);

            if (!try values.has_slot(ctx.db, row.id, values.live)) {
                return null;
            }

            const live = try document.document_of(ctx, row.id, values.live, def);

            return std.json.Stringify.valueAlloc(ctx.arena, live, .{}) catch error.OutOfMemory;
        }

        /// A move that puts the document live or takes it off changes what visitors see: a
        /// caller who may only draft is refused it at commit (`check_drafts`).
        pub fn mark_live_change(
            ctx: *Ctx,
            flow: model.flow.Flow,
            from: []const u8,
            to: []const u8,
        ) void {
            std.debug.assert(to.len > 0);
            std.debug.assert(!std.mem.eql(u8, from, to));

            if (flow.is_live(from) != flow.is_live(to)) {
                ctx.publishes = true;
            }
        }

        /// Moves a record by the transition `name` of its type's flow: refused unless the
        /// record is in one of the transition's `from` statuses and the caller passes the
        /// transition's own `authorize` (administrators always do).
        pub fn transition(
            ctx: *Ctx,
            granted: *const Grant,
            id: []const u8,
            name: []const u8,
            expected: ?i64,
        ) Error!Moved {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (name.len == 0 or name.len > model.status.id_len_max) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const flow = type_row.def.flow;

            if (!flow_model.reserved(name) and !flow.lists(name)) {
                return error.Invalid;
            }

            if (std.mem.eql(u8, name, "publish") and flow.is_live(row.status)) {
                return publish_changes(ctx, granted, row, expected);
            }

            const target = flow.named(name, row.status) orelse {
                return ctx.fail(.{
                    .name = "NotFrom",
                    .status = 409,
                    .message = "the record is not where this transition starts",
                });
            };

            if (!passes(ctx, target.authorize)) {
                return error.Denied;
            }

            if (std.mem.eql(u8, name, "destroy")) {
                // Plugin code destroys only from a `.destructive` operation.
                if (ctx.plugin_called and !ctx.destructive) {
                    return error.Denied;
                }

                return if (may_destroy(ctx, row.type))
                    destroy(ctx, granted, row)
                else
                    requests.ask(ctx, row, name);
            }

            const to = if (std.mem.eql(u8, name, "restore"))
                flow.restored_to(try documents.trashed_from(ctx.db, ctx.arena, row.id))
            else
                target.to;

            const publishing = requests.needs_publish(flow, row.status, to);

            if (publishing and !requests.may_publish(ctx, row.type)) {
                return requests.ask(ctx, row, name);
            }

            return move(ctx, row, to, expected, granted, .apply_pending);
        }

        /// `publish` named on a live record: its pending changes go live, or wait for
        /// someone who may publish.
        fn publish_changes(
            ctx: *Ctx,
            granted: *const Grant,
            row: Record,
            expected: ?i64,
        ) Error!Moved {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (!row.changed) {
                return error.Invalid;
            }

            if (!requests.may_publish(ctx, row.type)) {
                return requests.ask(ctx, row, "publish");
            }

            return publish(ctx, granted, row.id, expected);
        }

        /// A trashed record gone for good, asked by a person who may destroy.
        fn destroy(ctx: *Ctx, granted: *const Grant, row: Record) Error!Moved {
            std.debug.assert(std.mem.eql(u8, row.status, flow_model.trashed));
            std.debug.assert(row.version >= 1);

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const heard = try transition_heard(ctx, type_row.def, row.id, row.status, "destroyed");

            const named = heard.named.len > 0;

            try registry.SDK.hooks_on(ctx, .before, heard.name, heard.payload, true);

            if (named) {
                try registry.SDK.hooks_on(ctx, .before, heard.named, heard.payload, true);
            }

            _ = try purge(ctx, granted, row.id);
            try registry.SDK.hooks_on(ctx, .after, heard.name, heard.payload, true);
            ctx.emit_json(heard.name, heard.payload, false);

            if (named) {
                try registry.SDK.hooks_on(ctx, .after, heard.named, heard.payload, true);
                ctx.emit_json(heard.named, heard.payload, false);
            }

            return .{
                .status = "destroyed",
                .changed = false,
                .version = row.version,
            };
        }

        /// A person who is an administrator, or Publr itself; plugin code only for a person,
        /// with `records.destroy` on the type. An agent's device, a token and queued work never
        /// erase; they leave the record in the trash.
        fn may_destroy(ctx: *Ctx, handle: []const u8) bool {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(handle.len > 0);

            if (ctx.plugin_called) {
                const person = ctx.caller == .user and is_admin(ctx);

                return person and registry.SDK.may_on_type(ctx, purge_name, handle);
            }

            return ctx.caller == .system or is_admin(ctx);
        }

        const purge_name = Domain.namespace ++ ".purge";

        fn is_admin(ctx: *const Ctx) bool {
            std.debug.assert(ctx.now_ms >= 0);

            return switch (ctx.caller) {
                .user => |user| for (user.roles) |held| {
                    if (std.mem.eql(u8, held, model.role.admin)) {
                        break true;
                    }
                } else false,
                else => false,
            };
        }

        /// Whether `row` may end in status `to`: its own status again, or a transition the
        /// type's flow lists, whose `authorize` the caller passes. Refused before anything
        /// is written, whichever operation transitions it.
        pub fn check_move(
            ctx: *Ctx,
            row: Record,
            def: store.definitions.Def,
            to: []const u8,
        ) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(to.len > 0);

            const staying = std.mem.eql(u8, row.status, to);

            if (!staying and !def.flow.allows(row.status, to)) {
                return error.Invalid;
            }

            if (!staying) {
                try check_authorized(ctx, def.flow, row.status, to);
            }

            const publishing = requests.needs_publish(def.flow, row.status, to);

            if (publishing and !requests.may_publish(ctx, def.handle)) {
                return error.Denied;
            }

            try check_status(def, to);
        }

        /// A flow's transition from `from` to `to` that says who may make it: the caller
        /// passes its answer (administrators always do).
        pub fn check_authorized(
            ctx: *const Ctx,
            flow: model.flow.Flow,
            from: []const u8,
            to: []const u8,
        ) Error!void {
            std.debug.assert(from.len > 0);
            std.debug.assert(to.len > 0);

            const listed = flow.transition_between(from, to) orelse return;

            if (!passes(ctx, listed.authorize)) {
                return error.Denied;
            }
        }

        /// Whether the caller passes a transition's `authorize`; none: whoever may write.
        pub fn passes(ctx: *const Ctx, authorize: ?model.flow.Who) bool {
            std.debug.assert(ctx.now_ms >= 0);

            const who = authorize orelse return true;
            const through_app = ctx.app_plugins != null;

            return operation_define.admits(who.answered(), ctx.caller, through_app);
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
            std.debug.assert(granted.allows());
            std.debug.assert(row.id.len > 0);
            std.debug.assert(to.len > 0);

            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const applying = pending == .apply_pending and row.changed;

            try check_move(ctx, row, type_row.def, to);

            if (std.mem.eql(u8, row.status, to)) {
                return error.Invalid;
            }

            const flow = type_row.def.flow;

            if (flow.is_live(to)) {
                try check_references(ctx, row, if (applying) values.pending else values.live);
            }

            const heard = try transition_heard(ctx, type_row.def, row.id, row.status, to);

            try registry.SDK.hooks_on(ctx, .before, heard.name, heard.payload, true);

            if (heard.named.len > 0) {
                try registry.SDK.hooks_on(ctx, .before, heard.named, heard.payload, true);
            }

            const applied = if (flow.is_live(to) and applying)
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

            mark_live_change(ctx, flow, row.status, to);
            try registry.SDK.hooks_on(ctx, .after, heard.name, heard.payload, true);
            ctx.emit_json(heard.name, heard.payload, false);

            if (heard.named.len > 0) {
                try registry.SDK.hooks_on(ctx, .after, heard.named, heard.payload, true);
                ctx.emit_json(heard.named, heard.payload, false);
            }

            return .{
                .status = to,
                .changed = changed,
                .version = version,
            };
        }

        pub const Heard = struct {
            name: []const u8,
            /// The transition's own hook point, `<plugin>.<type>_<transition>`; empty for a
            /// type no plugin declares, or a move no transition names.
            named: []const u8,
            /// The move as JSON (`model.flow.Transitioned`).
            payload: []const u8,
        };

        /// What hooks on every transition of the record's type hear, and the name they
        /// hook (`model.flow.any_name`).
        pub fn transition_heard(
            ctx: *Ctx,
            def: store.definitions.Def,
            id: []const u8,
            from: []const u8,
            to: []const u8,
        ) Error!Heard {
            std.debug.assert(id.len > 0);
            std.debug.assert(to.len > 0);

            const name = try model.flow.any_name(ctx.arena, def.handle);
            const by = if (std.mem.eql(u8, to, "destroyed"))
                "destroy"
            else
                def.flow.name_between(from, to);
            const plugin_type = std.mem.indexOfScalar(u8, def.handle, '.') != null;
            const named = if (plugin_type and by.len > 0)
                std.fmt.allocPrint(ctx.arena, "{s}_{s}", .{ def.handle, by }) catch {
                    return error.OutOfMemory;
                }
            else
                "";

            const payload: model.flow.Transitioned = .{
                .record = id,
                .transition = by,
                .from = from,
                .to = to,
            };

            return .{
                .name = name,
                .named = named,
                .payload = try sdk.stringify(ctx.arena, payload),
            };
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
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;

            if (!type_row.def.flow.is_live(row.status)) {
                return move(ctx, row, "published", expected, granted, .apply_pending);
            }

            if (!row.changed) {
                return error.Invalid;
            }

            try check_references(ctx, row, values.pending);
            _ = try apply_pending(ctx, row);
            _ = try documents.clear_request(ctx.db, row.id);

            const actor = ctx.caller.user_id();
            const version = try documents.save(ctx.db, row.id, actor, expected, ctx.now_ms, false);

            ctx.publishes = true;

            return .{
                .status = row.status,
                .changed = false,
                .version = version,
            };
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
            _ = try documents.clear_request(ctx.db, row.id);

            const actor = ctx.caller.user_id();
            const version = try documents.save(ctx.db, row.id, actor, expected, ctx.now_ms, false);

            std.debug.assert(version > row.version);

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

            return move(ctx, row, "trashed", expected, granted, .apply_pending);
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

            std.debug.assert(purged or row.version >= 1);

            return purged;
        }
    };
}
