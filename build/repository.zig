const std = @import("std");

/// `sub` under the repository's folder, absolute: Zig gives the build its root relative to
/// the working directory, and a step run in another folder must still find the path.
pub fn path(builder: *std.Build, sub: []const u8) []const u8 {
    std.debug.assert(sub.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(sub));

    const arena = builder.graph.arena;
    const relative = builder.root.joinString(arena, sub) catch @panic("OOM");

    if (std.fs.path.isAbsolute(relative)) {
        return relative;
    }

    const working = std.process.currentPathAlloc(builder.graph.io, arena) catch |err| {
        std.debug.panic("the working directory: {t}", .{err});
    };
    const absolute = std.fs.path.resolve(arena, &.{ working, relative }) catch @panic("OOM");

    std.debug.assert(std.fs.path.isAbsolute(absolute));
    return absolute;
}

/// The repository's folder, open: read through it, never close it.
pub fn dir(builder: *std.Build) std.Io.Dir {
    std.debug.assert(builder.root.sub_path.len == 0);
    std.debug.assert(builder.isRoot() or builder.root.root_dir.path != null);

    return builder.root.root_dir.handle;
}
