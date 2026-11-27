//! `publr.pages`: every page of an operation that answers a page at a time (`after` in its
//! input, `next` in its answer), walked as records are. One page is held at a time: the page
//! before, and what the plugin allocated while it looked at it, are given back when the next
//! is asked for.
//!
//!     var roles = publr.pages(ctx, publr.operations.role.List, .{});
//!
//!     while (try roles.next()) |page| {
//!         for (page.roles) |role| { ... }
//!     }
//!
//! A page is good until the next `next`; what must outlive it is copied out of it first.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const Error = @import("../operation.zig").Error;
const lists = @import("../../sdk/operation/lists.zig");
const queue = @import("../../sdk/plugin/queue.zig");
const walks = @import("../../sdk/plugin/walks.zig");
const PluginCtx = @import("../../sdk/plugin/context.zig").PluginCtx;

/// What the build calls `Operation`: core's by name, a plugin's own by its verb.
fn named(comptime Operation: type) []const u8 {
    return if (@hasDecl(Operation, "name")) Operation.name else Operation.verb;
}

pub fn Pages(comptime Operation: type) type {
    comptime {
        if (!lists.paged(Operation)) {
            @compileError(named(Operation) ++ " answers in one piece: `ctx.call` it");
        }
    }

    return struct {
        ctx: *PluginCtx,
        in: Operation.In,
        walk: ?walks.Handle = null,
        after_bytes: [lists.next_bytes_max]u8 = undefined,
        after_len: u32 = 0,
        /// The last page was handed out: the next `next` ends the walk.
        last: bool = false,
        done: bool = false,
        page: Operation.Out = undefined,
        /// The memory the walk began in: where `keep` copies and what outlives the loop grows.
        outer: ?std.mem.Allocator = null,

        const Self = @This();

        /// Where what outlives the loop is made: a page's memory is given back at the next.
        pub fn memory(self: *const Self) std.mem.Allocator {
            std.debug.assert(self.walk != null);

            return self.outer orelse unreachable;
        }

        /// `text` from a page, copied where the walk began: good after the next page.
        pub fn keep(self: *const Self, text: []const u8) Error![]const u8 {
            const outer = self.outer orelse return error.Invalid;

            std.debug.assert(self.walk != null);

            return outer.dupe(u8, text) catch error.OutOfMemory;
        }

        /// The next page, or null after the last. Good until the next call.
        pub fn next(self: *Self) Error!?*const Operation.Out {
            std.debug.assert(self.after_len <= lists.next_bytes_max);

            if (self.done) {
                return null;
            }

            const handle = self.walk orelse try self.opened();

            // Given back with the work around it: a walk is read inside that work.
            if (!walks.alive(self.ctx, handle)) {
                return error.Invalid;
            }

            walks.turn_end(self.ctx, handle);

            if (self.last) {
                self.end();

                return null;
            }

            var asked = self.in;

            asked.after = self.after_bytes[0..self.after_len];
            walks.page_begin(self.ctx, handle);

            const answered = self.ctx.call(Operation, asked);

            walks.page_leave(self.ctx, handle);
            self.page = try answered;
            try self.continued(self.page.next);
            walks.turn_begin(self.ctx, handle);

            return &self.page;
        }

        /// The walk given back before its last page: what a loop left early may do.
        pub fn end(self: *Self) void {
            self.done = true;

            const handle = self.walk orelse return;

            walks.close(self.ctx, handle);

            std.debug.assert(!walks.alive(self.ctx, handle));
        }

        fn opened(self: *Self) Error!walks.Handle {
            std.debug.assert(self.walk == null);

            self.outer = self.ctx.arena();

            const handle = try walks.open(self.ctx);

            self.walk = handle;

            return handle;
        }

        /// Where the page after this one starts, kept past the page's memory.
        fn continued(self: *Self, next_position: []const u8) Error!void {
            std.debug.assert(self.after_len <= lists.next_bytes_max);

            if (next_position.len > lists.next_bytes_max) {
                return error.Invalid;
            }

            // A page that names itself as the next would walk for ever.
            const same = next_position.len > 0 and
                std.mem.eql(u8, next_position, self.after_bytes[0..self.after_len]);

            if (same) {
                return error.Invalid;
            }

            @memcpy(self.after_bytes[0..next_position.len], next_position);
            self.after_len = @intCast(next_position.len);
            self.last = next_position.len == 0;
        }
    };
}

/// Every page of `Operation`, asked with `in` (its `after` is set for each page).
pub fn pages(any_ctx: anytype, comptime Operation: type, in: Operation.In) Pages(Operation) {
    const ctx: *PluginCtx = queue.base_of(any_ctx);

    comptime std.debug.assert(named(Operation).len > 0);

    return .{
        .ctx = ctx,
        .in = in,
    };
}
