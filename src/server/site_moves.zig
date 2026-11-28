//! The site answering at another address while it runs (`addresses.zon`): what knows its
//! address outside the apps follows it. The session beside the database is written again
//! with it, so the `publr` command says the new address, and the queue worker starts again
//! told it, so its plugins' outside calls follow the same rule as the server's.
const std = @import("std");
const builtin = @import("builtin");
const operator = @import("operator.zig");
const queue_worker = @import("queue_worker.zig");
const outside = @import("../model/outside.zig");

pub const Follower = struct {
    io: std.Io,
    /// The binary the worker runs and its database: memory that outlives `buffer`.
    executable: []const u8,
    db_path: []const u8,
    /// None for a server no command reaches.
    session: ?operator.Session,
    worker: *queue_worker.Keeper,
    /// The worker's arguments and the session's text, made again at each move.
    buffer: [8 << 10]u8 = undefined,

    /// The site answers at `address` now (its `--url` again, or another); `origins` its
    /// rule's.
    pub fn moved(follower: *Follower, address: []const u8, origins: outside.Origins) void {
        std.debug.assert(address.len > 0);
        std.debug.assert(origins.site.len > 0);

        follower.follow(address, origins) catch |err| {
            std.log.warn("publr: the site answers at {s}; the worker or the session " ++
                "still say the address before: {t}", .{ address, err });
        };
    }

    fn follow(follower: *Follower, address: []const u8, origins: outside.Origins) !void {
        std.debug.assert(follower.executable.len > 0);
        std.debug.assert(follower.db_path.len > 0);

        var fixed = std.heap.FixedBufferAllocator.init(&follower.buffer);
        const arena = fixed.allocator();
        const argv = try queue_worker.argv_of(arena, follower.executable, follower.db_path, .{
            .site = try arena.dupe(u8, origins.site),
            .admin = origins.admin,
            .started = origins.started,
        });

        // The browser build has no worker process to start again.
        if (builtin.os.tag != .wasi) {
            follower.worker.restart(argv.ptr);
        }

        if (follower.session) |session| {
            try operator.readdress(follower.io, arena, follower.db_path, session, address);
        }
    }
};
