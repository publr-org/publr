//! Stop means stop. The worker learns of a Stop only between its steps, so one stuck inside
//! a call never would. The supervisor looks at the conversation from a thread of its own;
//! once the person asked it to stop and the worker has not, after a grace period, it ends
//! the worker, and the turn ends stopped, with what it did kept.

const std = @import("std");
const operator = @import("../operator.zig");
const Channel = @import("channel.zig").Channel;

/// How often the supervisor looks.
const look_every_s: i64 = 10;
/// How long a worker may take to stop on its own, between steps, once asked.
pub const grace_ms: i64 = 60 * 1000;

const Read = struct {
    conversation: struct {
        state: []const u8,
    },
};

pub const Stopper = struct {
    io: std.Io,
    session: operator.Session,
    id: []const u8,
    pid: std.posix.pid_t,
    /// Set by the supervisor once the worker ended: the thread stops looking.
    done: std.atomic.Value(bool) = .init(false),
    /// Set when the stopper ended the worker: the turn ends stopped, not failed.
    ended_it: std.atomic.Value(bool) = .init(false),

    pub fn start(stopper: *Stopper) !void {
        std.debug.assert(stopper.id.len > 0);
        std.debug.assert(stopper.pid > 0);

        const thread = try std.Thread.spawn(.{}, watch, .{stopper});

        thread.detach();
    }

    fn watch(stopper: *Stopper) void {
        std.debug.assert(grace_ms > look_every_s * 1000);

        var asked_ms: i64 = 0;

        while (!stopper.done.load(.acquire)) {
            std.Io.sleep(stopper.io, .fromSeconds(look_every_s), .awake) catch return;

            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();

            const stopping = stopper.asked_to_stop(arena_state.allocator());
            const now_ms = std.Io.Clock.awake.now(stopper.io).toMilliseconds();

            if (!stopping) {
                asked_ms = 0;
                continue;
            }

            if (asked_ms == 0) {
                asked_ms = now_ms;
                continue;
            }

            if (now_ms - asked_ms > grace_ms and !stopper.done.load(.acquire)) {
                std.log.err("conversation {s}: asked to stop and still running: ending it", .{
                    stopper.id,
                });
                stopper.ended_it.store(true, .release);
                stopper.end_worker();
                return;
            }
        }
    }

    /// Asks the worker to end (it may still record the stop itself), then makes it.
    fn end_worker(stopper: *Stopper) void {
        std.debug.assert(stopper.pid > 0);
        std.debug.assert(stopper.ended_it.load(.acquire));

        std.posix.kill(stopper.pid, .TERM) catch |err| {
            return std.log.err("stop: {t}", .{err});
        };
        std.Io.sleep(stopper.io, .fromSeconds(10), .awake) catch return;

        if (stopper.done.load(.acquire)) {
            return;
        }

        std.posix.kill(stopper.pid, .KILL) catch |err| {
            std.log.err("stop: {t}", .{err});
        };
    }

    /// Whether the person asked the turn to stop; a server that does not answer is no.
    fn asked_to_stop(stopper: *const Stopper, arena: std.mem.Allocator) bool {
        std.debug.assert(stopper.id.len > 0);

        var channel = Channel.of(stopper.io, arena, stopper.session);
        const read = channel.operate(Read, &.{
            "--as-admin", "ai", "conversation", "--id", stopper.id, "--limit", "1",
        }) catch return false;

        return std.mem.eql(u8, read.conversation.state, "stopping");
    }
};
