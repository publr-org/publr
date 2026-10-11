//! What a new site starts with when it has a front end: an app copied into its `apps/`,
//! then the site's own. The page tells a site on Publr Cloud from one running on its own by
//! `Publr.build.managed()`, so the same files serve both.
const std = @import("std");

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

test "the default starter is one app at the root, its page reading where it runs" {
    try std.testing.expect(std.mem.indexOf(u8, default.files[0].data, "\"/\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, default.files[1].data, "Publr.build.managed()") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, default.files[1].data, "Deploy now") != null);
    try std.testing.expect(std.mem.indexOf(u8, default.files[1].data, "Dashboard") != null);
}
