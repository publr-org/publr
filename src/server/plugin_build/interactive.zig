//! An installed plugin's interactive components: its `interactive/*.ptsx` through the
//! lowering the SDK carries (`pjsx_gen --script`), into `<module>.interactive/` beside the
//! module: their render as JavaScript, the browser's stores, the classes and the components
//! a page may place. The module carries them in `publr.interactive`; nothing is compiled
//! where the site runs.
const std = @import("std");
const report = @import("../../lib/report.zig");
const interactive_module = @import("../sandboxed_plugins/interactive.zig");

const file_bytes_max: u32 = 16 << 20;

/// Where the lowering of the module `built` writes.
pub fn folder_of(arena: std.mem.Allocator, built: []const u8) ![]const u8 {
    std.debug.assert(built.len > 0);

    return std.fmt.allocPrint(arena, "{s}.interactive", .{built});
}

/// Lowers the plugin at `dir`'s `interactive/` against the SDK in `sdk`; nothing when it has
/// none.
pub fn lower(init: std.process.Init, sdk: []const u8, dir: []const u8, built: []const u8) !void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(sdk.len > 0);

    const arena = init.arena.allocator();
    const sources = try std.fs.path.join(arena, &.{ dir, "interactive" });
    const out = try folder_of(arena, built);

    try std.Io.Dir.cwd().deleteTree(init.io, out);

    if (!try has_components(init, sources)) {
        return;
    }

    const argv = [_][]const u8{
        try std.fs.path.join(arena, &.{ sdk, "tools", "pjsx_gen" }),
        "--engine",
        "--script",
        sources,
        try std.fs.path.join(arena, &.{ sdk, "ws", "ui", "src", "components" }),
        try std.fs.path.join(arena, &.{ sdk, "ws", "icons", "icons" }),
        out,
    };
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
    });

    switch (try child.wait(init.io)) {
        .exited => |code| if (code != 0) {
            report.err("publr plugin build: the interactive components did not lower", .{});
            return error.InteractiveFailed;
        },
        else => |term| {
            report.err("publr plugin build: their lowering stopped: {any}", .{term});
            return error.InteractiveFailed;
        },
    }
}

/// The `publr.interactive` section for the module `built`, or null when its plugin has no
/// interactive components.
pub fn section_of(init: std.process.Init, built: []const u8) !?[]const u8 {
    std.debug.assert(built.len > 0);

    const arena = init.arena.allocator();
    const out = try folder_of(arena, built);
    var folder = std.Io.Dir.cwd().openDir(init.io, out, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer folder.close(init.io);

    const limit: std.Io.Limit = .limited(file_bytes_max);
    const components = try folder.readFileAlloc(init.io, "components.json", arena, limit);
    const render = try folder.readFileAlloc(init.io, "render.js", arena, limit);
    const browser = try folder.readFileAlloc(init.io, "stores.js", arena, limit);
    const classes = try folder.readFileAlloc(init.io, "classes.txt", arena, limit);

    return try interactive_module.section(arena, components, render, browser, classes);
}

fn has_components(init: std.process.Init, sources: []const u8) !bool {
    std.debug.assert(sources.len > 0);

    var folder = std.Io.Dir.cwd().openDir(init.io, sources, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer folder.close(init.io);

    var entries = folder.iterate();

    while (try entries.next(init.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".ptsx")) {
            return true;
        }
    }

    return false;
}
