//! Transitions asked for by someone who may not publish: a person whose roles do not grant
//! `<noun>.publish`, a plugin whose `records.write` lacks `.publish`. What changes what
//! visitors see waits, kept on the document, until someone who may runs it or declines it.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const Moved = @import("lifecycle.zig").Moved;

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Record = store.documents.Record;

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const publish_name = Domain.namespace ++ ".publish";

        /// Whether the caller may put changes and transitions of a `handle` document live:
        /// call `<noun>.publish` on it.
        pub fn may_publish(ctx: *Ctx, handle: []const u8) bool {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(handle.len > 0);

            return registry.SDK.may_on_type(ctx, publish_name, handle);
        }

        /// Whether a move from `from` to `to` changes what visitors see.
        pub fn needs_publish(flow: model.flow.Flow, from: []const u8, to: []const u8) bool {
            std.debug.assert(from.len > 0);
            std.debug.assert(to.len > 0);

            return !std.mem.eql(u8, from, to) and (flow.is_live(from) or flow.is_live(to));
        }

        /// Keeps `transition` as asked by the caller, in place of any request before it: the
        /// document stays as it is.
        pub fn ask(ctx: *Ctx, row: Record, transition: []const u8) Error!Moved {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(transition.len > 0);

            try documents.ask(ctx.db, row.id, transition, ctx.caller.user_id());

            return .{
                .status = row.status,
                .changed = row.changed,
                .version = row.version,
                .pending = true,
            };
        }

        /// Drops the request waiting on `row`: the asker withdrawing it, or someone who may
        /// publish declining it. Not found when none waits.
        pub fn decline(ctx: *Ctx, row: Record) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (row.requested.len == 0) {
                return error.NotFound;
            }

            const asker = row.requested_by orelse "";
            const caller = ctx.caller.user_id() orelse "";
            const own = asker.len > 0 and std.mem.eql(u8, asker, caller);

            if (!own and !may_publish(ctx, row.type)) {
                return error.Denied;
            }

            _ = try documents.clear_request(ctx.db, row.id);
        }
    };
}
