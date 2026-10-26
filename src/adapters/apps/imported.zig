//! The templates an app imports from outside its folder: another app's, or a shared
//! folder's (one with no `app.zon`), anywhere in the project's apps folder. They join the
//! app's own as `../<folder>/<path>`, so their classes reach its stylesheet and a change
//! to one rebuilds it like a change to its own.
const std = @import("std");
const engine = @import("../../template.zig");
const spec_module = @import("spec.zig");

const File = spec_module.File;
const imports = engine.imports;
const Component = @import("../../server/registry.zig").PluginComponent;

const template_bytes_max: u32 = 4 << 20;

/// `own`, the app's templates, followed by every template they import from outside the
/// folder, and what those import in turn: another folder's, or a plugin's component among
/// `components` from a plugin the app reaches (`plugins`, null for every one). An import
/// that leads nowhere is left for the compiler to name.
pub fn with_imported(
    arena: std.mem.Allocator,
    io: std.Io,
    apps_dir: []const u8,
    folder: []const u8,
    own: []const File,
    templates_max: u32,
    components: []const Component,
    plugins: ?[]const []const u8,
) ![]const File {
    std.debug.assert(apps_dir.len > 0);
    std.debug.assert(own.len <= templates_max);

    var files: std.ArrayList(File) = .empty;
    var index: u32 = 0;

    try files.appendSlice(arena, own);

    while (index < files.items.len) : (index += 1) {
        const file = files.items[index];

        for (try imports.specs(
            @import("pjsx_syntax").template_syntax,
            arena,
            file.data,
            file.path,
        )) |spec| {
            const target = imports.resolve(arena, file.path, spec, folder) catch continue;

            const outside = std.mem.startsWith(u8, target, imports.outside_prefix);
            const plugin = std.mem.startsWith(u8, target, imports.plugin_prefix);

            if ((!outside and !plugin) or has(files.items, target)) {
                continue;
            }

            if (files.items.len == templates_max) {
                return error.TooManyTemplates;
            }

            const data = if (plugin)
                component_of(components, plugins, target) orelse continue
            else
                read(arena, io, apps_dir, target) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };

            try files.append(arena, .{
                .path = target,
                .data = data,
            });
        }
    }

    std.debug.assert(files.items.len >= own.len);

    return files.items;
}

/// The text of the component `target` names (`plugin:cart/MiniCart.publr`), when its plugin
/// is one the app reaches; null otherwise, for the compiler to name.
fn component_of(
    components: []const Component,
    plugins: ?[]const []const u8,
    target: []const u8,
) ?[]const u8 {
    std.debug.assert(std.mem.startsWith(u8, target, imports.plugin_prefix));
    std.debug.assert(std.mem.endsWith(u8, target, ".publr"));

    const plugin = imports.plugin_of(target);
    const name = target[imports.plugin_prefix.len + plugin.len + 1 .. target.len - ".publr".len];

    if (plugins) |reached| {
        const listed = for (reached) |one| {
            if (std.mem.eql(u8, one, plugin)) break true;
        } else false;

        if (!listed) {
            return null;
        }
    }

    for (components) |component| {
        if (std.mem.eql(u8, component.plugin, plugin) and std.mem.eql(u8, component.name, name)) {
            return component.text;
        }
    }

    return null;
}

fn read(arena: std.mem.Allocator, io: std.Io, apps_dir: []const u8, target: []const u8) ![]u8 {
    std.debug.assert(std.mem.startsWith(u8, target, imports.outside_prefix));
    std.debug.assert(apps_dir.len > 0);

    const inside = target[imports.outside_prefix.len..];
    const path = try std.fs.path.join(arena, &.{ apps_dir, inside });
    const limit: std.Io.Limit = .limited(template_bytes_max);

    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit);
}

fn has(files: []const File, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) {
            return true;
        }
    }

    return false;
}

test "an app's imports from other folders join it, followed transitively, each once" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const nav = "---\nimport Mark from './mark.publr';\n---\n<nav><Mark /></nav>";
    const base = "---\nimport Nav from '../../shared/nav.publr';\n---\n<Nav /><slot />";

    try scratch.dir.createDirPath(io, "shared");
    try scratch.dir.createDirPath(io, "www/layouts");
    try scratch.dir.writeFile(io, .{
        .sub_path = "shared/nav.publr",
        .data = nav,
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "shared/mark.publr",
        .data = "<svg></svg>",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "www/layouts/base.publr",
        .data = base,
    });

    const apps_dir = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const page = "---\nimport Base from '../../www/layouts/base.publr';\n" ++
        "import Gone from '../../shared/gone.publr';\n---\n<Base />";
    const own = [_]File{.{
        .path = "content/index.publr",
        .data = page,
    }};
    const files = try with_imported(arena, io, apps_dir, "waitlist", &own, 16, &.{}, null);

    try std.testing.expectEqual(@as(usize, 4), files.len);
    try std.testing.expectEqualStrings("../www/layouts/base.publr", files[1].path);
    try std.testing.expectEqualStrings("../shared/nav.publr", files[2].path);
    try std.testing.expectEqualStrings("../shared/mark.publr", files[3].path);
    try std.testing.expectError(
        error.TooManyTemplates,
        with_imported(arena, io, apps_dir, "waitlist", &own, 2, &.{}, null),
    );
}
