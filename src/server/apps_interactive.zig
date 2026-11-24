//! An app's `interactive/*.ptsx`, for an app read from the project's folder: built before the
//! apps load (`publr apps load`, `publr serve`) by the lowering this binary carries in its SDK
//! (`tools/pjsx_gen --script`, run as its own process: Publr links no compiler), into the
//! app's `.interactive/`, which the folder's reader takes them from: their render as
//! JavaScript, the browser's stores, the classes and the components a page may place. An app
//! whose components changed since they were built is built again; one with none is left.
const std = @import("std");
const report = @import("../lib/report.zig");
const plugin_sdk = @import("plugin_sdk.zig");
const version = @import("../publr.zig").version;
const own = @import("../adapters/apps/interactive.zig");

/// Where an app keeps its built interactive components, inside its folder.
const built_dir = own.built_dir;
const apps_max: u32 = 1024;

/// Builds the interactive components of every app under `apps_dir` that changed since they
/// were built. The SDK is written once per release beside the database (`<data>/sdk/<version>`).
/// False, having said why, when one does not build.
pub fn build(init: std.process.Init, db_path: []const u8, apps_dir: []const u8) !bool {
    return build_in(.{
        .io = init.io,
        .arena = init.arena.allocator(),
    }, db_path, apps_dir);
}

/// Where a build runs: the process's io, and an arena for its paths.
pub const Place = struct {
    io: std.Io,
    arena: std.mem.Allocator,
};

/// `build` from a running server: `serve` reading its apps again (`publr apps load`, a
/// merge, the folder's watch) builds what changed first, as it did when it started.
pub fn build_in(place: Place, db_path: []const u8, apps_dir: []const u8) !bool {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(apps_dir.len > 0);

    const arena = place.arena;
    var root = std.Io.Dir.cwd().openDir(place.io, apps_dir, .{
        .iterate = true,
    }) catch return true;
    defer root.close(place.io);

    var entries = root.iterate();
    var sdk: ?[]const u8 = null;
    var count: u32 = 0;

    while (try entries.next(place.io)) |entry| {
        count += 1;

        if (count > apps_max) {
            break;
        }

        if (entry.kind != .directory and entry.kind != .sym_link) {
            continue;
        }

        const app_dir = try std.fs.path.join(arena, &.{ apps_dir, entry.name });

        if (!try own.stale(place.io, arena, app_dir)) {
            continue;
        }

        const tools = sdk orelse try sdk_of(place, db_path);

        sdk = tools;

        if (!try lower(place, tools, app_dir)) {
            report.err("publr: [{s}] its interactive components did not build", .{entry.name});
            return false;
        }
    }

    return true;
}

/// This release's SDK, written once beside the database.
fn sdk_of(place: Place, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    const arena = place.arena;
    const data = std.fs.path.dirname(db_path) orelse ".";
    const dir = try std.fs.path.join(arena, &.{ data, "sdk", version });
    const tool = try std.fs.path.join(arena, &.{ dir, "tools", "pjsx_gen" });
    const cwd = std.Io.Dir.cwd();

    if (cwd.access(place.io, tool, .{})) |_| {
        return dir;
    } else |_| {}

    try cwd.deleteTree(place.io, dir);

    var folder = try cwd.createDirPathOpen(place.io, dir, .{});
    defer folder.close(place.io);

    try plugin_sdk.extract_sdk(place.io, folder);

    return dir;
}

fn lower(place: Place, sdk: []const u8, app_dir: []const u8) !bool {
    std.debug.assert(sdk.len > 0);
    std.debug.assert(app_dir.len > 0);

    const arena = place.arena;
    const out = try std.fs.path.join(arena, &.{ app_dir, built_dir });

    try std.Io.Dir.cwd().deleteTree(place.io, out);

    const argv = [_][]const u8{
        try std.fs.path.join(arena, &.{ sdk, "tools", "pjsx_gen" }),
        "--engine",
        "--script",
        try std.fs.path.join(arena, &.{ app_dir, "interactive" }),
        try std.fs.path.join(arena, &.{ sdk, "ws", "ui", "src", "components" }),
        try std.fs.path.join(arena, &.{ sdk, "ws", "icons", "icons" }),
        out,
    };
    var child = try std.process.spawn(place.io, .{
        .argv = &argv,
    });

    return switch (try child.wait(place.io)) {
        .exited => |code| code == 0,
        else => false,
    };
}
