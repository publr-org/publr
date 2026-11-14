//! A folder's link to the site it works on, `.publr/clone.json`: written by `clone`, or made
//! the first time from the `cloud.json` a deploy left, since a deployed folder is a clone of
//! its project too. It says where the folder came from, the branch it pushes to, how far it
//! has pulled and what it last pushed.
const std = @import("std");
const cloud_deploy = @import("../cloud_deploy.zig");
const clone = @import("../clone.zig");
const changes = @import("changes.zig");

pub const path = ".publr/clone.json";
const link_bytes_max: u32 = 4 << 10;
const branch_suffix_len: u32 = 6;

pub const Link = struct {
    site: []const u8,
    branch: []const u8,
    /// The site's newest activity entry when the folder last came down (`bundle.Manifest`):
    /// the site is ahead when its own is newer.
    pulled: i64 = 0,
    /// The folder's own work as it was pushed (`changes.zig`'s mark), empty when nothing was.
    pushed: []const u8 = "",
    /// The folder's newest write to the site when it last matched it: 0 for a folder that
    /// came down (its log came empty), a deployed folder's newest by the time it went up.
    since: i64 = 0,
};

/// The link in `folder`; made from its `cloud.json` when it has only that; null for neither.
pub fn read(io: std.Io, arena: std.mem.Allocator, folder: std.Io.Dir) !?Link {
    std.debug.assert(link_bytes_max > 0);

    const limit: std.Io.Limit = .limited(link_bytes_max);
    const text = folder.readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.FileNotFound => return try from_deploy(io, arena, folder),
        else => return err,
    };

    return try std.json.parseFromSliceLeaky(Link, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn write(io: std.Io, arena: std.mem.Allocator, folder: std.Io.Dir, link: Link) !void {
    std.debug.assert(link.site.len > 0);
    std.debug.assert(link.branch.len > 0);

    const text = try std.json.Stringify.valueAlloc(arena, link, .{
        .whitespace = .indent_2,
    });

    try folder.createDirPath(io, std.fs.path.dirname(path).?);
    try folder.writeFile(io, .{
        .sub_path = path,
        .data = text,
    });
}

/// A branch name of this folder's own: `work-` and six letters.
pub fn new_branch(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    std.debug.assert(branch_suffix_len > 0);

    var random: [branch_suffix_len]u8 = undefined;

    io.random(&random);

    for (&random) |*byte| {
        byte.* = "abcdefghijkmnpqrstuvwxyz23456789"[byte.* & 31];
    }

    const name = try std.fmt.allocPrint(arena, "work-{s}", .{&random});

    std.debug.assert(name.len == "work-".len + branch_suffix_len);

    return name;
}

/// A deployed folder's link: its project's address, a branch of its own, nothing pulled yet.
fn from_deploy(io: std.Io, arena: std.mem.Allocator, folder: std.Io.Dir) !?Link {
    std.debug.assert(cloud_deploy.link_name.len > 0);

    const limit: std.Io.Limit = .limited(link_bytes_max);
    const name = cloud_deploy.link_name;
    const text = folder.readFileAlloc(io, name, arena, limit) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const Deployed = struct {
        address: []const u8,
        deployed_at_ms: i64 = 0,
    };
    const deployed = try std.json.parseFromSliceLeaky(Deployed, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const found = folder.realPathFileAlloc(io, clone.db_path, arena);
    const database = found catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const since = if (database.len > 0)
        try changes.latest_write(try arena.dupeZ(u8, database), deployed.deployed_at_ms)
    else
        0;
    const link: Link = .{
        .site = std.mem.trimEnd(u8, deployed.address, "/"),
        .branch = try new_branch(io, arena),
        .since = since,
    };

    try write(io, arena, folder, link);

    return link;
}

test "a deployed folder's link is made from its cloud.json, once" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;

    try std.testing.expect(try read(io, arena, scratch.dir) == null);
    try scratch.dir.writeFile(io, .{
        .sub_path = cloud_deploy.link_name,
        .data = "{\"address\":\"https://shop.publr.app/\",\"slug\":\"shop\"}",
    });

    const made = (try read(io, arena, scratch.dir)).?;
    const again = (try read(io, arena, scratch.dir)).?;

    try std.testing.expectEqualStrings("https://shop.publr.app", made.site);
    try std.testing.expectEqualStrings(made.branch, again.branch);
    try std.testing.expectEqual(@as(i64, 0), again.pulled);
}
