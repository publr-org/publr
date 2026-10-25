//! The apps folder watched while `serve` runs: a file written, changed or removed there (by
//! a person, an agent, or `apps write` from another machine) loads the apps again on its
//! own, once the folder has held still for a tick, so no edit waits on `publr apps load`.
//! Watching is a look at every file's size and modification time each tick: no OS events,
//! the same on every system and inside a VM.
const std = @import("std");
const report = @import("../lib/report.zig");
const AppsHost = @import("apps_host.zig").AppsHost;

/// Past this many entries the folder is not watched: `apps load` still loads it.
pub const entries_max: u32 = 20_000;

pub const Watch = struct {
    /// The folder as it looked at the last tick, waiting to hold still.
    seen: u64 = 0,

    /// Loads the apps again when the folder changed since they were loaded and has not
    /// changed since the last tick.
    pub fn tick(watch: *Watch, host: *AppsHost) void {
        std.debug.assert(host.apps.len <= 1 << 16);

        if (host.dir.len == 0) {
            return;
        }

        const now = stamp_of(host.project.io, host.dir) orelse return;
        const settled = now == watch.seen;

        watch.seen = now;

        if (now == host.stamp or !settled) {
            return;
        }

        host.reload() catch |err| {
            const reason = if (host.reason.len > 0) host.reason.text() else @errorName(err);

            const message = "publr: the apps changed and did not load ({s}); " ++
                "what loaded before still serves";

            report.warn_reason(reason, message, .{@errorName(err)});
            return;
        };

        std.debug.assert(watch.seen == now);
        std.debug.print("publr: the apps changed: loaded again\n", .{});
    }
};

/// Every file under `dir`, by its path, size and modification time, in one number; null when
/// the folder cannot be read or holds more than `entries_max` entries.
pub fn stamp_of(io: std.Io, dir: []const u8) ?u64 {
    std.debug.assert(dir.len > 0);

    var folder = std.Io.Dir.cwd().openDir(io, dir, .{
        .iterate = true,
    }) catch return null;
    defer folder.close(io);

    var buffer: [64 << 10]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var walker = folder.walk(fixed.allocator()) catch return null;
    defer walker.deinit();

    // Order-free: each entry hashed alone, then summed, so the walk's order never matters.
    var total: u64 = 0;

    for (0..entries_max) |_| {
        const entry = (walker.next(io) catch return null) orelse return total;

        if (entry.kind != .file) {
            continue;
        }

        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        var hasher = std.hash.Wyhash.init(0);

        hasher.update(entry.path);
        hasher.update(std.mem.asBytes(&stat.size));
        hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
        total +%= hasher.final();
    }

    return null;
}

test "a file changed, added or removed changes the stamp; nothing changed keeps it" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    const io = std.testing.io;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{scratch.sub_path});

    try scratch.dir.createDirPath(io, "www/content");
    try scratch.dir.writeFile(io, .{
        .sub_path = "www/content/index.publr",
        .data = "<h1>Hi</h1>",
    });

    const first = stamp_of(io, dir).?;

    try std.testing.expectEqual(first, stamp_of(io, dir).?);

    try scratch.dir.writeFile(io, .{
        .sub_path = "www/content/index.publr",
        .data = "<h1>Hello</h1>",
    });

    const changed = stamp_of(io, dir).?;

    try std.testing.expect(changed != first);

    try scratch.dir.writeFile(io, .{
        .sub_path = "www/style.css",
        .data = "h1{}",
    });

    const added = stamp_of(io, dir).?;

    try std.testing.expect(added != changed);

    try scratch.dir.deleteFile(io, "www/style.css");
    try std.testing.expectEqual(changed, stamp_of(io, dir).?);
}
