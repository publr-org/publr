//! What tooling outside Publr asks of a site's own data, through commands rather than its
//! database: `site state` (the release, the newest change and the newest write to the site,
//! the media records) and `site placeholders` (a stand-in file for every media record whose
//! file is missing). The `publr` command builds clone, pull and push on these.
const std = @import("std");
const db = @import("../../lib/db.zig");
const report = @import("../../lib/report.zig");
const activity = @import("../../store/activity.zig");
const placeholders = @import("placeholders.zig");
const operator = @import("../operator.zig");

const version = @import("../../publr/version.zig").version;

pub const help =
    \\  site state [--until <ms>]
    \\                    The site's release, its newest change, its newest write to the site
    \\                    (made by <ms> when given) and its media records, as JSON
    \\  site placeholders A stand-in file for every media record whose file is missing (a
    \\                    picture of its size and type); prints each one's storage key and
    \\                    bytes, a tab between, one a line
    \\
;

/// One media record: its storage key and its file's hash.
pub const Media = struct {
    key: []const u8,
    hash: []const u8,
};

pub const State = struct {
    release: []const u8 = version,
    /// The newest activity entry (`activity.latest`).
    latest_change: i64,
    /// The newest write to the site (`activity.latest_site_write`).
    latest_write: i64,
    media: []const Media,
};

/// `publr site state [--until <ms>]`.
pub fn state(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);

    const until: ?i64 = if (args.len == 2 and std.mem.eql(u8, args[0], "--until"))
        std.fmt.parseInt(i64, args[1], 10) catch null
    else
        null;

    if (args.len != 0 and until == null) {
        try out.print("usage:\n{s}", .{help});
        return 2;
    }

    if (!exists(init.io, db_path)) {
        report.err("publr site state: no site here ({s})", .{db_path});
        return 1;
    }

    const arena = init.arena.allocator();
    // In this command's own process: never in a server, whose SQLite this would shut down.
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, db_path);
    defer connection.close();

    var select = try connection.prepare("SELECT storage_key, hash FROM media ORDER BY storage_key");
    defer select.finalize();

    const Row = struct {
        storage_key: []const u8,
        hash: []const u8,
    };
    var media: std.ArrayList(Media) = .empty;

    while (try select.step()) {
        const row = try select.read(Row, arena);

        try media.append(arena, .{
            .key = row.storage_key,
            .hash = row.hash,
        });
    }

    const found: State = .{
        .latest_change = try activity.latest(&connection),
        .latest_write = try activity.latest_site_write(&connection, until),
        .media = media.items,
    };

    try out.print("{f}\n", .{std.json.fmt(found, .{})});

    return 0;
}

/// `publr site placeholders`.
pub fn write_placeholders(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);

    if (args.len != 0) {
        try out.print("usage:\n{s}", .{help});
        return 2;
    }

    if (!exists(init.io, db_path)) {
        report.err("publr site placeholders: no site here ({s})", .{db_path});
        return 1;
    }

    const arena = init.arena.allocator();

    if (try operator.find(init.io, arena, db_path)) |running| {
        report.err("publr site placeholders: a server runs for {s} on port {d}", .{
            db_path,
            running.port,
        });
        return 1;
    }

    // The data folder's parent is the folder the media paths are under.
    const data = std.fs.path.dirname(db_path) orelse ".";
    const folder = std.fs.path.dirname(data) orelse ".";

    _ = try placeholders.write_missing(init.io, arena, if (folder.len == 0) "." else folder, out);

    return 0;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}
