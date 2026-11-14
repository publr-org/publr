//! `publr pull`: the site brought down again into the folder linked to it, only what changed:
//! the database when the site moved past what the folder took, and of the media only the
//! files the folder does not hold the same. It never touches the folder's own work: a folder
//! with changes not pushed, or pushed and still waiting for review, is left as it is.
//! `--check` only says where the folder is, as JSON, for Publr Studio.
const std = @import("std");
const report = @import("../../lib/report.zig");
const bundle = @import("../bundle.zig");
const credentials = @import("../credentials.zig");
const remote = @import("../remote.zig");
const operator = @import("../operator.zig");
const clone = @import("../clone.zig");
const linking = @import("link.zig");
const changes = @import("changes.zig");
const downloads = @import("download.zig");
const progress = @import("progress.zig");
const writing = @import("folder.zig");
const applying = @import("apply.zig");

const download_path = ".publr/pull" ++ bundle.extension;
const list_path = "/api/environments.list";
const activity_path = "/api/activity.list";

/// Exit codes Studio tells apart: signed out of the site, work of the folder's own in the
/// way, a server running in the folder.
pub const signed_out: u8 = 3;
pub const own_work: u8 = 4;
pub const serving: u8 = 5;

/// Where the folder is, as `--check` says it.
pub const Where = struct {
    /// The folder holds work of its own.
    changes: bool,
    /// Some of it was not pushed.
    unsent: bool,
    /// It was all pushed, and its branch is still there for review.
    waiting: bool,
    /// The site has changed since the folder last came down.
    behind: bool,
    /// The branch it pushes to, and the site.
    branch: []const u8,
    site: []const u8,
    /// While waiting: the page where a person reviews and merges the branch.
    review: []const u8 = "",
};

pub fn pull(init: std.process.Init, out: *std.Io.Writer, checking: bool) !u8 {
    std.debug.assert(download_path.len > 0);

    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    var link = try linking.read(init.io, arena, cwd) orelse {
        report.err("publr pull: this folder is not linked to a site", .{});
        return 1;
    };
    const site = try credentials.find(init, link.site) orelse {
        report.err("publr pull: not signed in to {s}; run \"publr login {s}\"", .{
            link.site,
            link.site,
        });
        return signed_out;
    };
    const folder = try cwd.realPathFileAlloc(init.io, ".", arena);

    if (!try ensure_base(init, site, &link, folder)) {
        return 1;
    }

    const where = try where_of(init, site, link, folder) orelse return 1;

    if (checking) {
        try out.print("{f}\n", .{std.json.fmt(where, .{})});
        return 0;
    }

    if (where.unsent) {
        report.err("publr pull: this folder has changes not on the site yet; push them first", .{});
        return own_work;
    }

    if (where.waiting) {
        report.err("publr pull: this folder's changes wait for review as {s}", .{link.branch});
        return own_work;
    }

    if (!where.behind and !where.changes) {
        try out.print("Up to date with {s}\n", .{link.site});
        return 0;
    }

    if (try serving_here(init)) {
        return serving;
    }

    const brought = try bring_down(init, site, folder, .whole) orelse return 1;

    link.pulled = brought.latest_change;
    link.pushed = "";
    link.since = 0;
    try linking.write(init.io, arena, cwd, link);
    try out.print("Pulled {s}: {d} KiB came down\n", .{ link.site, brought.bytes / 1024 });

    return 0;
}

/// A deployed folder has no base until it first pulls: the site as it is now is one, the
/// folder left as it is. False, having said why, when the site could not give it.
pub fn ensure_base(
    init: std.process.Init,
    site: credentials.Site,
    link: *linking.Link,
    folder: []const u8,
) !bool {
    std.debug.assert(folder.len > 0);

    if (has_base(init.io)) {
        return true;
    }

    const brought = try bring_down(init, site, folder, .base_only) orelse return false;

    link.pulled = brought.latest_change;
    try linking.write(init.io, init.arena.allocator(), std.Io.Dir.cwd(), link.*);

    return true;
}

fn has_base(io: std.Io) bool {
    std.debug.assert(clone.base_dir.len > 0);

    std.Io.Dir.cwd().access(io, clone.base_dir ++ "/" ++ clone.db_path, .{}) catch return false;

    return true;
}

fn serving_here(init: std.process.Init) !bool {
    std.debug.assert(clone.db_path.len > 0);

    const running = try operator.find(init.io, init.arena.allocator(), clone.db_path);

    if (running) |found| {
        report.err("publr pull: a server runs this folder on port {d}; stop it first", .{
            found.port,
        });
        return true;
    }

    return false;
}

/// Where the folder is against the site; null, having said why, when the site cannot say.
fn where_of(
    init: std.process.Init,
    site: credentials.Site,
    link: linking.Link,
    folder: []const u8,
) !?Where {
    std.debug.assert(folder.len > 0);

    const arena = init.arena.allocator();
    const size = try downloads.size_of(init, site) orelse return null;
    const own = try changes.mark(init.io, arena, folder, link.since);
    const unsent = own.len > 0 and !std.mem.eql(u8, own, link.pushed);
    const pushed = own.len > 0 and !unsent;
    const review = if (pushed) try review_of(init, site, link.branch) else null;
    const waiting = review != null and !try merged(init, site, link.branch, link.pulled);

    return .{
        .changes = own.len > 0,
        .unsent = unsent,
        .waiting = waiting,
        .behind = size.latest_change != link.pulled,
        .branch = link.branch,
        .site = link.site,
        .review = if (waiting) review.? else "",
    };
}

/// Where the site's branch is reviewed, when the site has it (empty when it names no page);
/// null once deleted, or on a site that keeps no copies.
fn review_of(init: std.process.Init, site: credentials.Site, branch: []const u8) !?[]const u8 {
    std.debug.assert(branch.len > 0);

    const arena = init.arena.allocator();
    const reply = try remote.post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, list_path }),
        .payload = "{}",
        .token = site.token,
    });

    if (reply.status == .not_found) {
        return null;
    }

    if (reply.status != .ok) {
        return error.ListRefused;
    }

    const Entry = struct {
        name: []const u8,
        merge: []const u8 = "",
    };
    const Listed = struct {
        environments: []const Entry,
    };
    const listed = try std.json.parseFromSliceLeaky(Listed, arena, reply.body, .{
        .ignore_unknown_fields = true,
    });

    for (listed.environments) |entry| {
        if (std.mem.eql(u8, entry.name, branch)) {
            return entry.merge;
        }
    }

    return null;
}

/// Whether the site merged `branch` since its change `after`: its activity log says so
/// (`merge.accept`), as a merged branch is kept for its history.
fn merged(init: std.process.Init, site: credentials.Site, branch: []const u8, after: i64) !bool {
    std.debug.assert(branch.len > 0);
    std.debug.assert(after >= 0);

    const arena = init.arena.allocator();
    const reply = try remote.post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, activity_path }),
        .payload = "{\"operation\":\"merge.accept\",\"limit\":50}",
        .token = site.token,
    });

    if (reply.status != .ok) {
        return error.ActivityRefused;
    }

    const Entry = struct {
        id: i64,
        input: []const u8,
    };
    const Listed = struct {
        entries: []const Entry,
    };
    const Accepted = struct {
        branch: []const u8 = "",
    };
    const listed = try std.json.parseFromSliceLeaky(Listed, arena, reply.body, .{
        .ignore_unknown_fields = true,
    });

    for (listed.entries) |entry| {
        if (entry.id <= after) {
            continue;
        }

        const accepted = std.json.parseFromSliceLeaky(Accepted, arena, entry.input, .{
            .ignore_unknown_fields = true,
        }) catch continue;

        if (std.mem.eql(u8, accepted.branch, branch)) {
            return true;
        }
    }

    return false;
}

const Reach = enum {
    /// Only `.publr/base/`, the site as it is: the folder stays as it was.
    base_only,
    /// The folder and its base.
    whole,
};

const Brought = struct {
    /// The site's newest change the bundle carries.
    latest_change: i64,
    /// What came down, compressed.
    bytes: u64,
};

/// The site packed without what the folder holds the same and put in place; null, having
/// said why, when it was not.
fn bring_down(
    init: std.process.Init,
    site: credentials.Site,
    folder: []const u8,
    reach: Reach,
) !?Brought {
    std.debug.assert(folder.len > 0);

    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const asked = if (reach == .base_only)
        "{\"media\":\"none\"}"
    else
        try std.json.Stringify.valueAlloc(arena, .{
            .have = try applying.held(init.io, arena, folder),
        }, .{});
    var shared: progress.Shared = .{
        .io = init.io,
        .site = site.address,
        .folder = folder,
        .media = reach == .whole,
    };
    var why: []const u8 = "";
    const made = try clone.prepared(init, site, asked, &shared, &why) orelse return null;

    defer cwd.deleteFile(init.io, download_path) catch |err| {
        std.log.debug("removing {s}: {t}", .{ download_path, err });
    };

    try downloads.fetch_bundle(init, site, made.bytes, download_path, &shared);

    const download = try cwd.realPathFileAlloc(init.io, download_path, arena);

    if (reach == .whole) {
        try applying.apply(init, arena, folder, download);
    }

    const base = try std.fs.path.join(arena, &.{ folder, clone.base_dir });

    try cwd.deleteTree(init.io, base);

    const manifest = try writing.unpack_into(init, arena, base, download, .{
        .media = false,
    });

    try writing.keep_only_database(init.io, arena, base);

    return .{
        .latest_change = manifest.latest_change,
        .bytes = made.bytes,
    };
}

test "where a folder is reads as Studio reads it" {
    const where: Where = .{
        .changes = true,
        .unsent = false,
        .waiting = true,
        .behind = false,
        .branch = "work-abc234",
        .site = "https://shop.publr.app",
    };
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, where, .{});
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"waiting\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"unsent\":false") != null);
}
