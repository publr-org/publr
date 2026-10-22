//! Between requests, the due jobs plugins queued, and the `on` hook runs kept to run again,
//! are run (`sdk/jobs.zig`): a few a tick, so a request never waits long behind them.
const std = @import("std");
const registry = @import("registry.zig");
const job_queue = @import("../store/job_queue.zig");
const identity = @import("../adapters/rest/identity.zig");

const Project = @import("project.zig").Project;

/// How often the queue is looked at when nothing is due sooner.
pub const look_ms: i64 = 1000;
/// How often each repeating job is checked for a run waiting.
pub const repeat_ms: i64 = 60 * 1000;

pub const Clock = struct {
    /// When the queue is next looked at: at once on start, so due work runs after a restart.
    next_ms: i64 = 0,
    /// When the repeating jobs are next checked: at once on start.
    repeat_next_ms: i64 = 0,
};

pub fn tick(project: *const Project, gpa: std.mem.Allocator, clock: *Clock, now_ms: i64) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(now_ms >= 0);

    // Kept `on` hook runs and installed plugins' jobs wait here too, whatever is compiled in.
    if (now_ms < clock.next_ms) {
        return;
    }

    clock.next_ms = now_ms + look_ms;

    if (now_ms >= clock.repeat_next_ms) {
        clock.repeat_next_ms = now_ms + repeat_ms;
        repeat(project, gpa);
    }

    const due = job_queue.next_due(project.connection) catch |err| {
        std.log.warn("jobs: queue not read: {t}", .{err});
        return;
    };

    if (due == null or due.? > now_ms) {
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var ctx = identity.context(project, arena_state.allocator(), .system);

    const ran = registry.SDK.jobs.drain(&ctx, job_queue.take_max) catch |err| blk: {
        std.log.warn("jobs: not run: {t}", .{err});
        break :blk 0;
    };

    // A full pass leaves more due: the next tick takes them up without waiting.
    if (ran == job_queue.take_max) {
        clock.next_ms = now_ms;
    }
}

fn repeat(project: *const Project, gpa: std.mem.Allocator) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(repeat_ms > look_ms);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var ctx = identity.context(project, arena_state.allocator(), .system);

    _ = registry.SDK.jobs.repeat(&ctx) catch |err| {
        std.log.warn("jobs: repeating ones not queued: {t}", .{err});
    };
}
