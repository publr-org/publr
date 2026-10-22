const std = @import("std");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");

const manifest_bytes_max: u32 = 64 << 10;
const copy_buffer_bytes: u32 = 64 << 10;

pub const Options = struct {
    /// The most the files may hold once unpacked; a bundle past it is refused.
    bytes_max: u64 = 64 << 30,
};

/// The bundle at `bundle_path` written out as `site`: `data/` into its data folder (the
/// database under the site's own name), `site/` into its project folder. Refused when the
/// site has a database already, for a manifest of another format or a newer version, and
/// for a name that would land outside the two folders, a link, or more than `bytes_max`.
/// A refused bundle leaves no database behind, so it can be tried again.
pub fn unpack(
    site: backup.Site,
    arena: std.mem.Allocator,
    bundle_path: []const u8,
    options: Options,
) !bundle.Manifest {
    std.debug.assert(bundle_path.len > 0);
    std.debug.assert(options.bytes_max > 0);

    const io = site.io;
    const cwd = std.Io.Dir.cwd();
    const database = try std.fs.path.join(arena, &.{ site.data_dir, site.database });

    if (cwd.access(io, database, .{})) |_| {
        return error.SiteExists;
    } else |_| {}

    errdefer cwd.deleteFile(io, database) catch |err| {
        std.log.debug("removing the unfinished {s}: {t}", .{ database, err });
    };

    var file = try cwd.openFile(io, bundle_path, .{});
    defer file.close(io);
    var file_buffer: [copy_buffer_bytes]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const window = try std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.heap.page_allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, window);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var entries: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    const manifest = try read_manifest(arena, &entries);

    try write_all(site, arena, &entries, manifest, .{
        .database = database,
        .bytes_max = options.bytes_max,
    });

    return manifest;
}

fn read_manifest(arena: std.mem.Allocator, entries: *std.tar.Iterator) !bundle.Manifest {
    std.debug.assert(entries.unread_file_bytes == 0);
    std.debug.assert(manifest_bytes_max > 0);

    const first = (entries.next() catch return error.NotABundle) orelse return error.NotABundle;

    if (!std.mem.eql(u8, first.name, bundle.manifest_name) or first.size > manifest_bytes_max) {
        return error.NotABundle;
    }

    const about = try arena.alloc(u8, @intCast(first.size));

    try entries.reader.readSliceAll(about);
    entries.unread_file_bytes = 0;

    const manifest = std.json.parseFromSliceLeaky(bundle.Manifest, arena, about, .{
        .ignore_unknown_fields = true,
    }) catch return error.NotABundle;

    if (!std.mem.eql(u8, manifest.format, bundle.format_name) or !safe_name(manifest.database)) {
        return error.NotABundle;
    }

    if (manifest.version > bundle.format_version) {
        return error.NewerBundle;
    }

    return manifest;
}

const Limits = struct {
    database: []const u8,
    bytes_max: u64,
};

fn write_all(
    site: backup.Site,
    arena: std.mem.Allocator,
    entries: *std.tar.Iterator,
    manifest: bundle.Manifest,
    limits: Limits,
) !void {
    std.debug.assert(limits.database.len > 0);
    std.debug.assert(limits.bytes_max > 0);

    var written: u64 = 0;
    var has_database = false;

    while (try entries.next()) |entry| {
        if (entry.kind == .sym_link) {
            return error.InvalidBundle;
        }

        const target = try target_of(site, arena, manifest, entry.name) orelse
            return error.InvalidBundle;

        if (entry.kind == .directory) {
            try std.Io.Dir.cwd().createDirPath(site.io, target);
            continue;
        }

        written = std.math.add(u64, written, entry.size) catch return error.TooLarge;

        if (written > limits.bytes_max) {
            return error.TooLarge;
        }

        has_database = has_database or std.mem.eql(u8, target, limits.database);
        try write_entry(site.io, entries, entry, target);
    }

    if (!has_database) {
        return error.InvalidBundle;
    }
}

fn write_entry(
    io: std.Io,
    entries: *std.tar.Iterator,
    entry: std.tar.Iterator.File,
    target: []const u8,
) !void {
    std.debug.assert(target.len > 0);
    std.debug.assert(entry.kind == .file);

    const cwd = std.Io.Dir.cwd();

    if (std.fs.path.dirname(target)) |parent| {
        try cwd.createDirPath(io, parent);
    }

    // The secrets' key opens every secret: its owner's alone, as it was made.
    const private = std.mem.eql(u8, std.fs.path.basename(target), "secret.key");
    var out = try cwd.createFile(io, target, .{
        .exclusive = true,
        .permissions = if (private) .fromMode(0o600) else .default_file,
    });
    defer out.close(io);
    var buffer: [copy_buffer_bytes]u8 = undefined;
    var writer = out.writer(io, &buffer);

    try entries.streamRemaining(entry, &writer.interface);
    try writer.interface.flush();
}

/// Where a bundle's `name` goes: `data/<path>` under the data folder (its database under
/// the site's own name), `site/<item>/...` under the project folder for the project's
/// items; null for anything else, or a name that climbs out.
pub fn target_of(
    site: backup.Site,
    arena: std.mem.Allocator,
    manifest: bundle.Manifest,
    name: []const u8,
) !?[]const u8 {
    std.debug.assert(site.database.len > 0);
    std.debug.assert(manifest.database.len > 0);

    if (!safe_name(name)) {
        return null;
    }

    const trimmed = std.mem.trimEnd(u8, name, "/");

    if (std.mem.startsWith(u8, trimmed, "data/")) {
        const rest = trimmed["data/".len..];
        const own = if (std.mem.eql(u8, rest, manifest.database)) site.database else rest;

        return try std.fs.path.join(arena, &.{ site.data_dir, own });
    }

    if (!std.mem.startsWith(u8, trimmed, "site/")) {
        return null;
    }

    const rest = trimmed["site/".len..];
    const item = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];

    for (bundle.project_items) |known| {
        if (std.mem.eql(u8, item, known)) {
            return try std.fs.path.join(arena, &.{ site.project_dir, rest });
        }
    }

    return null;
}

/// Relative, `/`-separated, with no empty, `.` or `..` part and no backslash.
fn safe_name(name: []const u8) bool {
    std.debug.assert(name.len <= std.fs.max_path_bytes);

    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null) {
        return false;
    }

    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "/"), '/');

    while (parts.next()) |part| {
        const empty_or_dots = part.len == 0 or std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..");

        if (empty_or_dots) {
            return false;
        }
    }

    std.debug.assert(name[0] != '/');

    return true;
}

test "a bundle's names land in the site's two folders, nowhere else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const site: backup.Site = .{
        .io = std.testing.io,
        .database = "site.db",
        .data_dir = "/site/data",
        .project_dir = "/site",
    };
    const manifest: bundle.Manifest = .{
        .release = "",
        .name = "ada",
        .made_at_ms = 1,
        .database = "publr.db",
    };
    const Case = struct {
        []const u8,
        ?[]const u8,
    };
    const cases = [_]Case{
        .{ "data/publr.db", "/site/data/site.db" },
        .{ "data/media/a/photo.webp", "/site/data/media/a/photo.webp" },
        .{ "site/apps/www/app.zon", "/site/apps/www/app.zon" },
        .{ "site/publr.zon", "/site/publr.zon" },
        .{ "site/output/index.html", null },
        .{ "site/site.json", null },
        .{ "data/../../etc/passwd", null },
        .{ "data/media/./x", null },
        .{ "/etc/passwd", null },
        .{ "data//x", null },
        .{ "data\\x", null },
        .{ "elsewhere/x", null },
        .{ "", null },
    };

    for (cases) |case| {
        const found = try target_of(site, arena, manifest, case[0]);

        if (case[1]) |expected| {
            try std.testing.expectEqualStrings(expected, found.?);
        } else {
            try std.testing.expect(found == null);
        }
    }
}
