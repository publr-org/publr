const std = @import("std");
const db = @import("../../lib/db.zig");
const time = @import("../../lib/time.zig");

/// How many updates' backups are kept beside the site.
pub const kept_max: u32 = 3;
pub const backups_max: u32 = 256;
pub const folder_name = "backups";
const about_name = "backup.json";
const about_bytes_max: u32 = 64 << 10;
/// What the project folder holds besides the data folder: the site as its owner made it.
const project_items = [_][]const u8{ "publr.zon", "apps", "plugins" };

/// Where a site is on disk: the database, the folder it lives in (media, installed plugins),
/// and the project folder around it (`publr.zon`, apps, compiled-in plugins' sources). In a
/// Cloud project both are the same folder.
pub const Site = struct {
    io: std.Io,
    /// The database file's name inside `data_dir` (`publr.db`).
    database: []const u8,
    data_dir: []const u8,
    project_dir: []const u8,

    /// The site whose database is at `db_path`, in `project_dir` (the folder `publr` runs
    /// in when null).
    pub fn of(
        io: std.Io,
        arena: std.mem.Allocator,
        db_path: []const u8,
        project_dir: ?[]const u8,
    ) !Site {
        std.debug.assert(db_path.len > 0);
        std.debug.assert(!std.mem.endsWith(u8, db_path, "/"));

        const parent = std.fs.path.dirname(db_path) orelse ".";
        const cwd = std.Io.Dir.cwd();

        return .{
            .io = io,
            .database = std.fs.path.basename(db_path),
            .data_dir = try cwd.realPathFileAlloc(io, if (parent.len == 0) "." else parent, arena),
            .project_dir = try cwd.realPathFileAlloc(io, project_dir orelse ".", arena),
        };
    }

    pub fn backups_dir(site: Site, arena: std.mem.Allocator) ![]const u8 {
        std.debug.assert(site.data_dir.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(site.data_dir));

        return std.fs.path.join(arena, &.{ site.data_dir, folder_name });
    }

    /// Whether the project folder's items are their own, outside the data folder.
    fn project_apart(site: Site) bool {
        std.debug.assert(site.project_dir.len > 0);
        std.debug.assert(site.data_dir.len > 0);

        return !std.mem.eql(u8, site.project_dir, site.data_dir);
    }
};

/// What a backup says about itself, in `backup.json`.
pub const About = struct {
    /// The release that last opened the site, empty when none recorded one.
    from: []const u8,
    to: []const u8,
    at_ms: i64,
    database: []const u8,
};

pub const MakeOptions = struct {
    /// Remove the oldest past `kept_max`; off when the one about to be restored may be it.
    prune: bool = true,
};

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    about: About,
};

/// The whole site copied into `backups/<time>-<from>-to-<to>/` beside the database: the
/// database through `VACUUM INTO` (consistent while others read it), media hard-linked
/// (a media file is never rewritten in place, so a link costs no space), everything else
/// copied. The oldest past `kept_max` are removed. Returns the backup's folder.
pub fn make(
    site: Site,
    connection: *db.Db,
    arena: std.mem.Allocator,
    about: About,
    options: MakeOptions,
) ![]const u8 {
    std.debug.assert(about.to.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    const name = try name_of(arena, about);
    const root = try std.fs.path.join(arena, &.{ try site.backups_dir(arena), name });
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(site.io, try std.fs.path.join(arena, &.{ root, "data" }));
    errdefer cwd.deleteTree(site.io, root) catch |err| {
        std.log.warn("removing the unfinished backup {s}: {t}", .{ root, err });
    };

    try db.copy_to(connection, try std.fs.path.join(arena, &.{ root, "data", site.database }));
    try copy_tree(site, arena, site.data_dir, try std.fs.path.join(arena, &.{ root, "data" }));

    if (site.project_apart()) {
        try copy_project(site, arena, try std.fs.path.join(arena, &.{ root, "site" }));
    }

    try write_about(site, arena, root, about);

    if (options.prune) {
        try prune(site, arena);
    }

    return root;
}

/// Every backup beside the site, newest first.
pub fn list(site: Site, arena: std.mem.Allocator) ![]const Entry {
    std.debug.assert(site.data_dir.len > 0);
    std.debug.assert(backups_max > kept_max);

    const dir_path = try site.backups_dir(arena);
    var dir = try open_listing(site.io, dir_path) orelse return &.{};
    defer dir.close(site.io);

    var entries: std.ArrayList(Entry) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(site.io)) |item| {
        if (item.kind != .directory or entries.items.len == backups_max) {
            continue;
        }

        const path = try std.fs.path.join(arena, &.{ dir_path, item.name });
        const about = read_about(site, arena, path) catch continue;

        const name = try arena.dupe(u8, item.name);

        try entries.append(arena, .{
            .name = name,
            .path = path,
            .about = about,
        });
    }

    std.mem.sort(Entry, entries.items, {}, newer_first);

    return entries.items;
}

/// The site put back as `entry` holds it: the database file replaced (its journal
/// removed), and every folder the backup holds replaced by its copy. Nothing may have the
/// database open.
pub fn restore(site: Site, arena: std.mem.Allocator, entry: Entry) !void {
    std.debug.assert(entry.path.len > 0);
    std.debug.assert(entry.about.database.len > 0);

    const cwd = std.Io.Dir.cwd();
    const data = try std.fs.path.join(arena, &.{ entry.path, "data" });

    for ([_][]const u8{ "", "-wal", "-shm", "-journal" }) |suffix| {
        const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.database, suffix });

        cwd.deleteFile(site.io, try std.fs.path.join(arena, &.{ site.data_dir, file })) catch |err|
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
    }

    try replace_items(site, arena, data, site.data_dir);

    const project = try std.fs.path.join(arena, &.{ entry.path, "site" });

    if (site.project_apart() and exists(site.io, project)) {
        try replace_items(site, arena, project, site.project_dir);
    }
}

fn name_of(arena: std.mem.Allocator, about: About) ![]const u8 {
    std.debug.assert(about.at_ms > 0);
    std.debug.assert(about.to.len > 0);

    const clock = try time.datetime_text(arena, about.at_ms);
    var stamp: std.ArrayList(u8) = .empty;

    for (clock) |byte| {
        if (byte == ' ') {
            try stamp.append(arena, 'T');
        } else if (byte != ':') {
            try stamp.append(arena, byte);
        }
    }

    const from = if (about.from.len == 0) "new" else about.from;

    return std.fmt.allocPrint(arena, "{s}-{s}-to-{s}", .{ stamp.items, from, about.to });
}

/// Whether `relative` (inside the data folder) is something a backup leaves out: the
/// database and its journal (copied whole by `VACUUM INTO`), the server's key file, and
/// the backups themselves.
fn left_out(site: Site, relative: []const u8) bool {
    std.debug.assert(relative.len > 0);
    std.debug.assert(site.database.len > 0);

    const top = relative[0 .. std.mem.indexOfScalar(u8, relative, std.fs.path.sep) orelse
        relative.len];

    if (std.mem.eql(u8, top, folder_name)) {
        return true;
    }

    return std.mem.startsWith(u8, top, site.database);
}

fn copy_tree(
    site: Site,
    arena: std.mem.Allocator,
    source_path: []const u8,
    target_path: []const u8,
) !void {
    std.debug.assert(std.fs.path.isAbsolute(source_path));
    std.debug.assert(target_path.len > 0);

    const cwd = std.Io.Dir.cwd();
    var source = try cwd.openDir(site.io, source_path, .{
        .iterate = true,
    });
    defer source.close(site.io);
    var target = try cwd.openDir(site.io, target_path, .{});
    defer target.close(site.io);
    var walker = try source.walk(arena);
    defer walker.deinit();
    const inside_data = std.mem.eql(u8, source_path, site.data_dir);

    while (try walker.next(site.io)) |entry| {
        if (inside_data and left_out(site, entry.path)) {
            if (entry.kind == .directory) {
                walker.leave(site.io);
            }

            continue;
        }

        switch (entry.kind) {
            .directory => try target.createDirPath(site.io, entry.path),
            .file => try copy_file(site, source, target, entry.path, inside_data),
            else => {},
        }
    }
}

fn copy_file(
    site: Site,
    source: std.Io.Dir,
    target: std.Io.Dir,
    path: []const u8,
    inside_data: bool,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(path));

    const media = inside_data and std.mem.startsWith(u8, path, "media" ++ std.fs.path.sep_str);

    if (media) {
        if (source.hardLink(path, target, path, site.io, .{})) {
            return;
        } else |err| {
            std.log.debug("hard link {s}: {t}; copying", .{ path, err });
        }
    }

    try source.copyFile(path, target, path, site.io, .{});
}

fn copy_project(site: Site, arena: std.mem.Allocator, root: []const u8) !void {
    std.debug.assert(site.project_apart());
    std.debug.assert(root.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(site.io, root);

    for (project_items) |item| {
        const source = try std.fs.path.join(arena, &.{ site.project_dir, item });
        const target = try std.fs.path.join(arena, &.{ root, item });
        const stat = cwd.statFile(site.io, source, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        if (std.mem.startsWith(u8, source, site.data_dir)) {
            continue;
        }

        if (stat.kind == .directory) {
            try cwd.createDirPath(site.io, target);
            try copy_tree(site, arena, source, target);
        } else {
            try cwd.copyFile(source, cwd, target, site.io, .{});
        }
    }
}

/// Each item in `source` put in `target` in place of what is there.
fn replace_items(
    site: Site,
    arena: std.mem.Allocator,
    source_path: []const u8,
    target_path: []const u8,
) !void {
    std.debug.assert(std.fs.path.isAbsolute(source_path));
    std.debug.assert(std.fs.path.isAbsolute(target_path));

    const cwd = std.Io.Dir.cwd();
    var source = try cwd.openDir(site.io, source_path, .{
        .iterate = true,
    });
    defer source.close(site.io);
    var iterator = source.iterate();

    while (try iterator.next(site.io)) |item| {
        const from = try std.fs.path.join(arena, &.{ source_path, item.name });
        const to = try std.fs.path.join(arena, &.{ target_path, item.name });

        if (item.kind == .directory) {
            try cwd.deleteTree(site.io, to);
            try cwd.createDirPath(site.io, to);
            try copy_tree(site, arena, from, to);
        } else {
            try cwd.copyFile(from, cwd, to, site.io, .{});
        }
    }
}

fn write_about(site: Site, arena: std.mem.Allocator, root: []const u8, about: About) !void {
    std.debug.assert(root.len > 0);
    std.debug.assert(about.at_ms > 0);

    const text = try std.json.Stringify.valueAlloc(arena, about, .{
        .whitespace = .indent_2,
    });

    try std.Io.Dir.cwd().writeFile(site.io, .{
        .sub_path = try std.fs.path.join(arena, &.{ root, about_name }),
        .data = text,
    });
}

fn read_about(site: Site, arena: std.mem.Allocator, root: []const u8) !About {
    std.debug.assert(root.len > 0);
    std.debug.assert(about_bytes_max > 0);

    const text = try std.Io.Dir.cwd().readFileAlloc(
        site.io,
        try std.fs.path.join(arena, &.{ root, about_name }),
        arena,
        .limited(about_bytes_max),
    );

    return std.json.parseFromSliceLeaky(About, arena, text, .{
        .ignore_unknown_fields = true,
    });
}

fn prune(site: Site, arena: std.mem.Allocator) !void {
    std.debug.assert(kept_max > 0);
    std.debug.assert(site.data_dir.len > 0);

    const entries = try list(site, arena);

    if (entries.len <= kept_max) {
        return;
    }

    for (entries[kept_max..]) |entry| {
        try std.Io.Dir.cwd().deleteTree(site.io, entry.path);
    }
}

fn newer_first(_: void, left: Entry, right: Entry) bool {
    std.debug.assert(left.name.len > 0);
    std.debug.assert(right.name.len > 0);

    return std.mem.order(u8, left.name, right.name) == .gt;
}

/// The folder at `path` opened to list, or null when there is none.
fn open_listing(io: std.Io, path: []const u8) !?std.Io.Dir {
    std.debug.assert(path.len > 0);

    const options: std.Io.Dir.OpenOptions = .{
        .iterate = true,
    };

    return std.Io.Dir.cwd().openDir(io, path, options) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn exists(io: std.Io, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;

    return true;
}

test {
    _ = @import("backup_test.zig");
}
