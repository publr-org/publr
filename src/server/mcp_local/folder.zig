//! The site a folder works on, for `publr mcp`: the one its `.publr/site` names, else the
//! site it is (`data/publr.db`) through the server running it. Looked for in the folder and
//! the folders above it, as an agent may start in a subfolder of its project.
const std = @import("std");
const credentials = @import("../credentials.zig");
const operator = @import("../operator.zig");

pub const database_path = "data/publr.db";
const depth_max: u32 = 32;
const site_bytes_max: u32 = 512;

pub const Target = union(enum) {
    /// A site elsewhere, named by `.publr/site` in `folder`.
    linked: Found,
    /// This folder is a site and its server runs: the admin's origin.
    serving: Found,
    /// This folder is a site and nothing serves it, or a server too old to say its admin.
    stopped: Found,
    /// Neither, up to the root.
    none,
};

pub const Found = struct {
    folder: []const u8,
    address: []const u8 = "",
};

/// The folder an agent's tool started this in: `given` unless the tool left its variable
/// unexpanded (Cursor with no folder open), else the current one.
pub fn start_folder(io: std.Io, arena: std.mem.Allocator, given: ?[]const u8) ![]const u8 {
    std.debug.assert(depth_max > 0);

    if (given) |folder| {
        const unexpanded = std.mem.indexOf(u8, folder, "${") != null;

        if (folder.len > 0 and !unexpanded) {
            return folder;
        }
    }

    const current = try std.process.currentPathAlloc(io, arena);

    std.debug.assert(current.len > 0);

    return current;
}

pub fn find(io: std.Io, arena: std.mem.Allocator, start: []const u8) !Target {
    std.debug.assert(start.len > 0);

    var folder: []const u8 = start;
    var depth: u32 = 0;

    while (depth < depth_max) : (depth += 1) {
        if (try site_named(io, arena, folder)) |address| {
            return .{
                .linked = .{
                    .folder = folder,
                    .address = address,
                },
            };
        }

        const database = try std.fs.path.join(arena, &.{ folder, database_path });

        if (exists(io, database)) {
            const running = try operator.find(io, arena, database);
            const admin = if (running) |session| session.admin else "";
            const found: Found = .{
                .folder = folder,
                .address = admin,
            };

            return if (admin.len > 0) .{
                .serving = found,
            } else .{
                .stopped = found,
            };
        }

        folder = std.fs.path.dirname(folder) orelse return .none;
    }

    return .none;
}

/// Names `address` as the site `folder` works on. A folder that is a site keeps itself.
pub fn link(io: std.Io, arena: std.mem.Allocator, folder: []const u8, address: []const u8) !void {
    std.debug.assert(folder.len > 0);
    std.debug.assert(address.len > 0 and address.len <= site_bytes_max);

    if (try is_site(io, arena, folder)) {
        return error.FolderIsASite;
    }

    const path = try std.fs.path.join(arena, &.{ folder, credentials.site_path });
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data = try std.fmt.allocPrint(arena, "{s}\n", .{address}),
    });
}

/// Whether `folder` is a site: it works on itself. A folder inside one never reaches `link`,
/// as it already works on that site.
pub fn is_site(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !bool {
    std.debug.assert(folder.len > 0);

    const database = try std.fs.path.join(arena, &.{ folder, database_path });

    return exists(io, database);
}

fn site_named(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !?[]const u8 {
    std.debug.assert(folder.len > 0);

    const path = try std.fs.path.join(arena, &.{ folder, credentials.site_path });
    const limit: std.Io.Limit = .limited(site_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => err,
        };
    };
    const site = std.mem.trim(u8, text, " \n\r\t");

    return if (site.len > 0) site else null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}

test "a folder works on the site it names, from itself or a folder below it" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const below = try std.fs.path.join(arena, &.{ root, "apps", "www" });

    try std.Io.Dir.cwd().createDirPath(io, below);
    // Folders above the scratch one may be a site (a checkout's own data/publr.db).
    try std.testing.expect(try find(io, arena, below) != .linked);

    try link(io, arena, root, "https://shop--admin.publr.app");

    const linked = try find(io, arena, below);

    try std.testing.expectEqualStrings("https://shop--admin.publr.app", linked.linked.address);
    try std.testing.expectEqualStrings(root, linked.linked.folder);
}

test "a folder that is a site is never linked elsewhere, and says when nothing serves it" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);

    try scratch.dir.createDirPath(io, "data");
    try scratch.dir.writeFile(io, .{
        .sub_path = database_path,
        .data = "",
    });

    try std.testing.expectError(error.FolderIsASite, link(io, arena, root, "https://elsewhere"));
    try std.testing.expect(try find(io, arena, root) == .stopped);
    try std.testing.expectEqualStrings(
        "/somewhere",
        try start_folder(io, arena, "/somewhere"),
    );
    try std.testing.expect((try start_folder(io, arena, "${workspaceFolder}")).len > 0);
}
