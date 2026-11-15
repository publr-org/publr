//! What a new site starts with when it has a front end: an app copied into its `apps/`,
//! then the site's own. Publr writes it when it first sets a project up (`set_up`), as a
//! meta framework's default page; a project made with an empty `apps/` (admin only) gets
//! none. The page tells a site on Publr Cloud from one running on its own by
//! `Publr.build.managed()`, so the same files serve both.
const std = @import("std");

/// The project file a site's folder holds, naming it.
pub const project_file = "publr.zon";
const project_bytes_max: u32 = 1 << 20;

pub const File = struct {
    path: []const u8,
    data: []const u8,
};

pub const Starter = struct {
    name: []const u8,
    files: []const File,
};

pub const default: Starter = .{
    .name = "default",
    .files = &.{
        .{
            .path = "www/app.zon",
            .data = @embedFile("starter/www/app.zon"),
        },
        .{
            .path = "www/content/index.publr",
            .data = @embedFile("starter/www/content/index.publr"),
        },
        .{
            .path = "www/public/style.css",
            .data = @embedFile("starter/www/public/style.css"),
        },
    },
};

/// Writes `starter`'s apps into `apps`, a site's apps folder, made when missing.
pub fn write(io: std.Io, arena: std.mem.Allocator, apps: []const u8, starter: Starter) !void {
    std.debug.assert(apps.len > 0);
    std.debug.assert(starter.files.len > 0);

    const cwd = std.Io.Dir.cwd();

    for (starter.files) |file| {
        const path = try std.fs.path.join(arena, &.{ apps, file.path });

        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        try cwd.writeFile(io, .{
            .sub_path = path,
            .data = file.data,
        });
    }
}

/// The default starter written into this folder's `apps/`, when this folder is a project
/// (its `publr.zon` names it) with no `apps` folder at all; true when it was written. Run
/// once, as the project's database is first made.
pub fn set_up(io: std.Io, arena: std.mem.Allocator) !bool {
    std.debug.assert(default.files.len > 0);

    const cwd = std.Io.Dir.cwd();

    if (cwd.access(io, "apps", .{})) |_| {
        return false;
    } else |_| {}

    const limit: std.Io.Limit = .limited(project_bytes_max);
    const text = cwd.readFileAllocOptions(io, project_file, arena, limit, .of(u8), 0) catch
        return false;
    const Project = struct {
        name: []const u8 = "",
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const project = std.zon.parse.fromSlice(Project, .{
        .gpa = arena,
        .arena = arena,
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch return false;

    if (project.name.len == 0) {
        return false;
    }

    try write(io, arena, "apps", default);

    return true;
}

test "the default starter is one app at the root, its page reading where it runs" {
    try std.testing.expect(std.mem.indexOf(u8, default.files[0].data, "\"/\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, default.files[1].data, "Publr.build.managed()") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, default.files[1].data, "Deploy now") != null);
    try std.testing.expect(std.mem.indexOf(u8, default.files[1].data, "Dashboard") != null);
}
