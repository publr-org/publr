//! The templates an app imports from outside its folder: another app's, or a shared
//! folder's (one with no `app.zon`), anywhere in the project's apps folder. They join the
//! app's own as `../<folder>/<path>`, so their classes reach its stylesheet and a change
//! to one rebuilds it like a change to its own.
const std = @import("std");
const engine = @import("../../template.zig");
const spec_module = @import("spec.zig");

const File = spec_module.File;
const imports = engine.imports;
const registry = @import("../../server/registry.zig");
const provider_slots = @import("provider_slots.zig");
const Component = registry.PluginComponent;

const template_bytes_max: u32 = 4 << 20;

/// `own`, the app's templates, followed by every template they import from outside the
/// folder, and what those import in turn: another folder's, or a plugin's component among
/// `slots.components` from a plugin the app reaches (`plugins`, null for every one). Each
/// `<ProviderSlot>` is drawn as its providers' components first. An import that leads
/// nowhere is left for the compiler to name.
pub fn with_imported(
    arena: std.mem.Allocator,
    io: std.Io,
    apps_dir: []const u8,
    folder: []const u8,
    own: []const File,
    templates_max: u32,
    slots: provider_slots.Sources,
    plugins: ?[]const []const u8,
    reason: ?*@import("../../lib/report.zig").Reason,
) ![]const File {
    std.debug.assert(apps_dir.len > 0);
    std.debug.assert(own.len <= templates_max);

    var files: std.ArrayList(File) = .empty;
    var index: u32 = 0;

    try files.appendSlice(arena, own);

    while (index < files.items.len) : (index += 1) {
        // A slot left for a contract's chosen provider draws the providers' components.
        files.items[index].data = try provider_slots.expand(
            arena,
            files.items[index].data,
            slots.providers,
            slots.components,
            plugins,
            reason,
        );

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
                try arena.dupe(u8, component_of(slots.components, plugins, target) orelse continue)
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

/// Reading `props` whole runs it as JavaScript, which takes any prop.
const stand_in = "---\nconst given = Object.keys(props);\n---\n<slot />";

/// `files` with a stand-in for every component they import from a plugin not among `present`:
/// one that takes any props and draws what it is given (`<slot />`). The build's check of its apps
/// (`publr check-apps`) runs before any plugin is installed, so an app that imports an
/// installable plugin's component is checked around it; the component itself is checked
/// when the app is loaded beside the installed plugin, as `serve` does.
pub fn with_stand_ins(
    arena: std.mem.Allocator,
    files: []const File,
    present: []const []const u8,
    templates_max: u32,
) ![]const File {
    std.debug.assert(files.len <= templates_max);

    var out: std.ArrayList(File) = .empty;

    try out.appendSlice(arena, files);

    for (files) |file| {
        for (try imports.specs(
            @import("pjsx_syntax").template_syntax,
            arena,
            file.data,
            file.path,
        )) |spec| {
            const named = imports.plugin_component(arena, spec) catch continue;
            const target = named orelse continue;

            if (has(out.items, target)) {
                continue;
            }

            const plugin = imports.plugin_of(target);
            const compiled = for (present) |name| {
                if (std.mem.eql(u8, name, plugin)) break true;
            } else false;

            if (compiled) {
                continue;
            }

            if (out.items.len == templates_max) {
                return error.TooManyTemplates;
            }

            try out.append(arena, .{
                .path = target,
                .data = stand_in,
            });
        }
    }

    std.debug.assert(out.items.len >= files.len);

    return out.items;
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

const no_slots: provider_slots.Sources = .{
    .providers = &.{},
    .components = &.{},
    .interactive = &.{},
};

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
    const files = try with_imported(
        arena,
        io,
        apps_dir,
        "waitlist",
        &own,
        16,
        no_slots,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), files.len);
    try std.testing.expectEqualStrings("../www/layouts/base.publr", files[1].path);
    try std.testing.expectEqualStrings("../shared/nav.publr", files[2].path);
    try std.testing.expectEqualStrings("../shared/mark.publr", files[3].path);
    try std.testing.expectError(
        error.TooManyTemplates,
        with_imported(arena, io, apps_dir, "waitlist", &own, 2, no_slots, null, null),
    );
}

test "a component from a plugin not present stands in; a present plugin's is left to resolve" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = "---\nimport Frame from 'plugin:customers/AccountFrame';\n" ++
        "import Card from 'plugin:products/Card';\n---\n<Frame><Card /></Frame>";
    const own = [_]File{.{
        .path = "content/index.publr",
        .data = page,
    }};
    const files = try with_stand_ins(arena, &own, &.{"products"}, 16);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("plugin:customers/AccountFrame.publr", files[1].path);
    try std.testing.expectEqualStrings(stand_in, files[1].data);
}
