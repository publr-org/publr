//! An installed plugin's views: its `ui/*.ptsx` lowered by the lowering the admin's views
//! go through (`pjsx_gen`, built for this binary and carried in its SDK), into a folder beside
//! the module. It reads the admin's views, the design system and the icons from the SDK. Only
//! the plugin's own modules are written, with a stand-in for each component the host draws
//! for it; a plugin without views gets nothing.
const std = @import("std");
const toolchain = @import("../toolchain.zig");
const report = @import("../../lib/report.zig");

/// The folder holding the plugin's lowered views (`views.zig` and its modules), or null when
/// it has none.
pub fn lower(
    init: std.process.Init,
    tools: toolchain.Toolchain,
    dir: []const u8,
    built: []const u8,
) !?[]const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(built.len > 0);

    const arena = init.arena.allocator();
    const ui = try std.fs.path.join(arena, &.{ dir, "ui" });

    if (!try has_views(init, ui)) {
        return null;
    }

    const out = try std.fmt.allocPrint(arena, "{s}.views", .{built});
    const sdk = tools.sdk;

    try std.Io.Dir.cwd().deleteTree(init.io, out);

    const argv = [_][]const u8{
        try std.fs.path.join(arena, &.{ sdk, "tools", "pjsx_gen" }),
        "--plugin",
        try std.fs.path.join(arena, &.{ sdk, "ws", "publr", "ui" }),
        try std.fs.path.join(arena, &.{ sdk, "ws", "ui", "src", "components" }),
        try std.fs.path.join(arena, &.{ sdk, "ws", "icons", "icons" }),
        out,
        ui,
    };
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
    });

    // The lowering names the file and what is wrong with it as it goes.
    switch (try child.wait(init.io)) {
        .exited => |code| if (code != 0) {
            report.err("publr plugin build: the plugin's views did not lower", .{});
            return error.ViewsFailed;
        },
        else => |term| {
            report.err("publr plugin build: the views' lowering stopped: {any}", .{term});
            return error.ViewsFailed;
        },
    }

    return out;
}

/// Whether `ui` holds a `.ptsx` file, at any depth.
fn has_views(init: std.process.Init, ui: []const u8) !bool {
    std.debug.assert(ui.len > 0);

    var folder = std.Io.Dir.cwd().openDir(init.io, ui, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer folder.close(init.io);

    var walker = try folder.walk(init.arena.allocator());
    defer walker.deinit();

    while (try walker.next(init.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".ptsx")) {
            return true;
        }
    }

    return false;
}
