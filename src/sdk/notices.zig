//! A notice's way to the event hooks (`stage = .on`). An intrinsic hook (`pub const
//! intrinsic = true`) is part of the write: it hears the notice inside the write's
//! transaction, so what it keeps commits or rolls back with the write, and a write over many
//! records hands it all of them at once when it has a set form (`run_many`). Every other
//! hook, compiled in or installed, is extrinsic: a side effect, queued in the transaction and
//! handed on once the write has committed, between requests.
const std = @import("std");
const sdk = @import("../sdk.zig");
const notice_queue = @import("../store/notice_queue.zig");

const Ctx = sdk.Ctx;
const Event = sdk.Event;
const Notice = Event.Notice;

pub fn Notices(comptime SDK: type, comptime registry: sdk.Registry) type {
    return struct {
        /// Whether a compiled-in event hook is part of the write that raises a notice.
        pub fn intrinsic(comptime Middleware: type) bool {
            comptime std.debug.assert(Middleware.stage == .on);

            return @hasDecl(Middleware, "intrinsic") and Middleware.intrinsic;
        }

        /// One notice: the intrinsic hooks now, the extrinsic ones from the queue.
        pub fn hand(ctx: *Ctx, notice: Notice) void {
            std.debug.assert(notice.name.len > 0);
            std.debug.assert(notice.operation_id != 0);

            const event: Event = .{
                .notice = notice,
            };

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and intrinsic(Middleware);

                if (listens and sdk.hears(Middleware, event)) {
                    SDK.run_listener(ctx, Middleware, event);
                }
            }

            queue(ctx, notice);
        }

        /// Many notices of one write: an intrinsic hook with a set form hears them in one
        /// call, the others one by one; each is queued for the extrinsic hooks.
        pub fn hand_many(ctx: *Ctx, many: []const Notice) sdk.Error!void {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(many.len > 0);

            for (many) |notice| {
                SDK.follow_notice(ctx, notice);
            }

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and intrinsic(Middleware);

                if (listens) {
                    try hand_to(ctx, Middleware, many);
                }
            }

            for (many) |notice| {
                queue(ctx, notice);
            }
        }

        fn hand_to(ctx: *Ctx, comptime Middleware: type, many: []const Notice) sdk.Error!void {
            comptime std.debug.assert(intrinsic(Middleware));
            std.debug.assert(many.len > 0);

            if (comptime !@hasDecl(Middleware, "run_many")) {
                for (many) |notice| {
                    const event: Event = .{
                        .notice = notice,
                    };

                    if (sdk.hears(Middleware, event)) {
                        SDK.run_listener(ctx, Middleware, event);
                    }
                }

                return;
            }

            var heard: std.ArrayList(Notice) = .empty;

            for (many) |notice| {
                const event: Event = .{
                    .notice = notice,
                };

                if (sdk.hears(Middleware, event)) {
                    heard.append(ctx.arena, notice) catch return error.OutOfMemory;
                }
            }

            if (heard.items.len > 0) {
                Middleware.run_many(ctx, heard.items);
            }
        }

        /// Kept for the extrinsic hooks, when any would hear it. A notice that could not be
        /// kept fails the write, as a site change not raised does: they would never hear it.
        fn queue(ctx: *Ctx, notice: Notice) void {
            std.debug.assert(notice.name.len > 0);
            std.debug.assert(notice.operation_id != 0);

            if (!heard_outside(ctx, notice)) {
                return;
            }

            notice_queue.push(
                ctx.db,
                notice.operation_id,
                notice.name,
                notice.subject,
                ctx.now_ms,
            ) catch |err| {
                ctx.dependency_failure = true;
                std.log.warn("notices: {s} not queued: {t}", .{ notice.name, err });
            };
        }

        /// Whether an extrinsic hook, compiled in or installed, hears the notice.
        fn heard_outside(ctx: *const Ctx, notice: Notice) bool {
            std.debug.assert(notice.name.len > 0);
            std.debug.assert(registry.middleware.len <= sdk.middleware.middleware_max);

            const event: Event = .{
                .notice = notice,
            };

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and !intrinsic(Middleware);

                if (listens and sdk.hears(Middleware, event)) {
                    return true;
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return false;

            return sandboxed.hooked(.event, notice.name);
        }

        /// The queued notices handed to the extrinsic hooks, oldest first, up to `max`:
        /// what the server does between requests. Answers how many it handed on.
        pub fn drain(ctx: *Ctx, max: u32) notice_queue.Error!u32 {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(max > 0 and max <= notice_queue.take_max);

            const queued = try notice_queue.take(ctx.db, ctx.arena, max);

            // The hooks hear them as events of a pass of its own.
            _ = ctx.allocate_operation_id();

            for (queued) |row| {
                deliver(ctx, .{
                    .operation_id = @intCast(row.operation_id),
                    .name = row.name,
                    .subject = row.subject,
                });
            }

            if (queued.len > 0) {
                try notice_queue.remove_through(ctx.db, queued[queued.len - 1].id);
            }

            return @intCast(queued.len);
        }

        fn deliver(ctx: *Ctx, notice: Notice) void {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(notice.operation_id != 0);

            const event: Event = .{
                .notice = notice,
            };

            if (ctx.sandboxed_plugins) |sandboxed| {
                sandboxed.event(ctx, event);
            }

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and !intrinsic(Middleware);

                if (listens and sdk.hears(Middleware, event)) {
                    SDK.run_listener(ctx, Middleware, event);
                }
            }
        }
    };
}
