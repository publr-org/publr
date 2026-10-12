//! Between requests, the notices writes queued for the extrinsic hooks are handed on
//! (`sdk/notices.zig`): a few hundred a tick, so a request never waits long behind them.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("registry.zig");
const notice_queue = @import("../store/notice_queue.zig");
const identity = @import("../adapters/rest/identity.zig");

const Project = @import("project.zig").Project;

pub fn tick(project: *const Project, gpa: std.mem.Allocator) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(notice_queue.take_max > 0);

    const waiting = notice_queue.waiting(project.connection) catch |err| {
        std.log.warn("notices: queue not read: {t}", .{err});
        return;
    };

    if (!waiting) {
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var ctx = identity.context(project, arena_state.allocator(), .system);

    _ = registry.SDK.notices.drain(&ctx, notice_queue.take_max) catch |err| {
        std.log.warn("notices: not handed on: {t}", .{err});
    };
}
