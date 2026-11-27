//! Other Publr servers on this host, and sites packed as bundles: what a built-in plugin
//! running several copies of a site works with (`publr.Host.processes`). Each running
//! server leaves a note beside its database (`running_file`) holding its port and a key only
//! processes of the host read; a POST carrying the key reaches its operator routes.
const std = @import("std");
const operator = @import("../../server/operator.zig");

/// A server running on a database of this host, as its note says.
pub const Running = struct {
    port: u16,
    /// What its operator routes take, never shown to anyone.
    key: [key_len]u8,
    /// The binary it runs, as `build_stamp` read it when it started.
    build: u64 = 0,
    /// Where its site answers, and its admin.
    url: []const u8 = "",
    admin: []const u8 = "",
};

pub const key_len: u32 = 64;

comptime {
    std.debug.assert(key_len == operator.key_len);
}

/// The server running on the database at `db_path`, or null; a note whose server no longer
/// answers is removed.
pub fn find_running(io: std.Io, arena: std.mem.Allocator, db_path: []const u8) !?Running {
    std.debug.assert(db_path.len > 0);

    const found = try operator.find(io, arena, db_path) orelse return null;

    std.debug.assert(found.port > 0);

    return .{
        .port = found.port,
        .key = found.key,
        .build = found.build,
        .url = found.url,
        .admin = found.admin,
    };
}

/// `payload` posted to the running server at `path` with its key: its answer's body.
pub fn post(
    io: std.Io,
    arena: std.mem.Allocator,
    running: Running,
    path: []const u8,
    payload: []const u8,
) ![]const u8 {
    std.debug.assert(path.len > 0 and path[0] == '/');
    std.debug.assert(running.port > 0);

    return operator.post(io, arena, .{
        .port = running.port,
        .key = running.key,
        .build = running.build,
        .url = running.url,
        .admin = running.admin,
    }, path, payload);
}

/// Where the server on the database at `db_path` leaves its note.
pub fn running_file(arena: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    return operator.path_of(arena, db_path);
}

/// The binary this process runs, as it is now: its file's modification time, 0 when it
/// cannot be read. A server whose `build` is older runs an older binary.
pub fn build_stamp(io: std.Io, arena: std.mem.Allocator) u64 {
    return operator.build_stamp(io, arena);
}

/// What a site bundle says of itself.
pub const Manifest = struct {
    /// The Publr release that packed it.
    publr: []const u8,
    /// The release that last opened its database; empty when none recorded one.
    release: []const u8,
    name: []const u8,
    made_at_ms: i64,
    /// The database's file name under `data/`.
    database: []const u8,
    /// Media keys whose files it leaves out: whoever unpacks it takes them from its source.
    placeholders: []const []const u8 = &.{},
    /// The site's newest change when it was packed.
    latest_change: i64 = 0,
};

/// The bundle at `bundle_path` written out as the site whose database is `db_path`, in
/// `folder`: its manifest. Refused past 64 GiB unpacked.
pub fn unpack(
    io: std.Io,
    arena: std.mem.Allocator,
    db_path: []const u8,
    folder: []const u8,
    bundle_path: []const u8,
) !Manifest {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(bundle_path.len > 0);

    const backup = @import("../../server/gate/backup.zig");
    const site = try backup.Site.of(io, arena, db_path, folder);
    const read = try @import("../../server/bundle.zig").unpack(site, arena, bundle_path, .{});

    return .{
        .publr = read.publr,
        .release = read.release,
        .name = read.name,
        .made_at_ms = read.made_at_ms,
        .database = read.database,
        .placeholders = read.placeholders,
        .latest_change = read.latest_change,
    };
}

/// The release of Publr this process is.
pub const version = @import("../../publr.zig").version;

/// A line on the error output, as Publr's commands write one: for a `before_command` that
/// turns the command down.
pub fn report_error(comptime format: []const u8, args: anytype) void {
    @import("../../lib/report.zig").err(format, args);
}
