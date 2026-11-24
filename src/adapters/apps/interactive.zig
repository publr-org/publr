//! The interactive components of the plugins an app reaches, joined to it as it loads: each
//! plugin's components placeable by name (`import X from '../interactive/X.ptsx'` in the
//! plugin's own components, `plugin:<plugin>/X.ptsx` in the app's), drawn by their render as
//! JavaScript (`ui/scripted.zig`), their classes in the app's sheet, their stores served as
//! `interactive-<plugin>.js` beside the app's own and loaded on every page that holds an
//! interactive component.
const std = @import("std");
const engine = @import("../../template.zig");
const sdk = @import("../../sdk.zig");
const spec_module = @import("spec.zig");
const scripted = @import("../../ui/scripted.zig");
const vm_module = @import("../../template/javascript/vm.zig");
const report = @import("../../lib/report.zig");
const imports = @import("../../template/imports.zig");

const Spec = spec_module.Spec;
const File = spec_module.File;
const Interactive = sdk.sandboxed_plugins.Interactive;

pub const components_max: u32 = 64;

/// A component as `components.json` lists it.
const Described = struct {
    name: []const u8,
    props: []const struct {
        name: []const u8,
        kind: []const u8,
        has_default: bool,
    } = &.{},
    takes_children: bool = false,
};

/// `spec` with the interactive components of every bundle from a plugin whose components it
/// places (`reaches`); a name the app already places is kept the app's.
pub fn add(
    arena: std.mem.Allocator,
    spec: *Spec,
    bundles: []const Interactive,
    reason: ?*report.Reason,
) !void {
    std.debug.assert(spec.name.len > 0);
    std.debug.assert(spec.pjsx_components.len == spec.pjsx_renders.len);

    var components: std.ArrayList(engine.PjsxComponent) = .empty;
    var renders: std.ArrayList(engine.PjsxRender) = .empty;
    var assets: std.ArrayList(File) = .empty;
    var modules: std.ArrayList([]const u8) = .empty;
    var classes: std.ArrayList(u8) = .empty;

    try components.appendSlice(arena, spec.pjsx_components);
    try renders.appendSlice(arena, spec.pjsx_renders);
    try assets.appendSlice(arena, spec.assets);
    try modules.appendSlice(arena, spec.interactive_modules);
    try classes.appendSlice(arena, spec.interactive_classes);

    for (bundles) |bundle| {
        if (!try reaches(arena, spec, bundle.plugin)) {
            continue;
        }

        const added = join(arena, bundle, &components, &renders) catch |err| {
            if (reason) |said| {
                said.set("[{s}] {s}'s interactive components do not load: {s}", .{
                    spec.name,
                    bundle.plugin,
                    @errorName(err),
                });
            }

            return err;
        };

        if (added == 0) {
            continue;
        }

        const own = bundle.plugin.len == 0;
        // Loaded again when plugins change, as its slots are: what they bring may have.
        spec.slotted = spec.slotted or !own;

        const path = if (own)
            "interactive.js"
        else
            try std.fmt.allocPrint(arena, "interactive-{s}.js", .{bundle.plugin});

        try assets.append(arena, .{
            .path = path,
            .data = bundle.browser,
        });
        try modules.append(arena, path);
        try classes.append(arena, '\n');
        try classes.appendSlice(arena, bundle.classes);
    }

    if (assets.items.len > spec_module.assets_max) {
        return error.TooManyAssets;
    }

    spec.pjsx_components = components.items;
    spec.pjsx_renders = renders.items;
    spec.assets = assets.items;
    spec.interactive_modules = modules.items;
    spec.interactive_classes = classes.items;
}

/// Whether the app places a component of `plugin`'s: the plugin is one it reaches (its
/// `.plugins`, every one when null) and a template of it imports one, its own
/// (`plugin:<plugin>/X.ptsx`) or a component of the plugin's it drew (`../interactive/X.ptsx`).
/// A plugin it places nothing of adds no script to its pages.
fn reaches(arena: std.mem.Allocator, spec: *const Spec, plugin: []const u8) !bool {
    std.debug.assert(spec.name.len > 0);

    // The app's own, built from its folder.
    if (plugin.len == 0) {
        return true;
    }

    if (spec.plugins) |listed| {
        const found = for (listed) |name| {
            if (std.mem.eql(u8, name, plugin)) break true;
        } else false;

        if (!found) {
            return false;
        }
    }

    return imports_from(arena, spec.templates, plugin);
}

fn imports_from(arena: std.mem.Allocator, templates: []const File, plugin: []const u8) !bool {
    std.debug.assert(plugin.len > 0);

    const own = try std.fmt.allocPrint(arena, "{s}{s}/", .{ imports.plugin_prefix, plugin });

    for (templates) |template| {
        const specs = imports.component_specs(
            @import("pjsx_syntax").template_syntax,
            arena,
            template.data,
            template.path,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Unsupported => continue,
        };
        const plugins_own = std.mem.startsWith(u8, template.path, own);

        for (specs) |spec| {
            if (std.mem.startsWith(u8, spec, own)) {
                return true;
            }

            if (plugins_own and std.mem.indexOf(u8, spec, "interactive/") != null) {
                return true;
            }
        }
    }

    return false;
}

/// The bundle's components appended, each drawn by its program; how many.
fn join(
    arena: std.mem.Allocator,
    bundle: Interactive,
    components: *std.ArrayList(engine.PjsxComponent),
    renders: *std.ArrayList(engine.PjsxRender),
) !u32 {
    std.debug.assert(bundle.render.len > 0);
    std.debug.assert(components.items.len == renders.items.len);

    const listed = bundle.components;
    const described = try std.json.parseFromSliceLeaky([]const Described, arena, listed, .{
        .ignore_unknown_fields = true,
    });

    if (described.len > components_max) {
        return error.TooManyComponents;
    }

    const program = try arena.create(scripted.Bundle);

    program.* = .{
        .bytecode = try bytecode_of(arena, bundle),
    };

    var added: u32 = 0;

    for (described) |one| {
        if (taken(components.items, one.name)) {
            continue;
        }

        const component = try arena.create(scripted.Component);

        component.* = .{
            .bundle = program,
            .name = one.name,
        };
        try components.append(arena, .{
            .name = one.name,
            .props = try props_of(arena, one),
            .takes_children = one.takes_children,
        });
        try renders.append(arena, component.pjsx_render());
        added += 1;
    }

    return added;
}

fn bytecode_of(arena: std.mem.Allocator, bundle: Interactive) ![]const u8 {
    std.debug.assert(bundle.render.len > 0);

    var vm = try vm_module.VM.init(arena);
    defer vm.deinit();

    const name = try std.fmt.allocPrint(arena, "publr:interactive:{s}", .{bundle.plugin});

    return vm.compile(bundle.render, name) catch |err| {
        std.log.scoped(.interactive).err("{s}: {s}", .{ bundle.plugin, vm.failure });
        return err;
    };
}

fn taken(components: []const engine.PjsxComponent, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (components) |component| {
        if (std.mem.eql(u8, component.name, name)) {
            return true;
        }
    }

    return false;
}

/// The props a call site fills: text, numbers and true or false, and lists and objects the
/// page's script made, which reach the program as their JSON.
fn props_of(arena: std.mem.Allocator, described: Described) ![]const engine.PjsxProp {
    std.debug.assert(described.name.len > 0);

    var props: std.ArrayList(engine.PjsxProp) = .empty;

    for (described.props) |prop| {
        try props.append(arena, .{
            .name = prop.name,
            .has_default = prop.has_default,
        });
    }

    return props.items;
}

test {
    _ = @import("interactive_parity.zig");
}

/// Where an app read from the project's folder keeps its built interactive components.
pub const built_dir = ".interactive";

/// An app's own interactive components, as `publr apps load` built them into its
/// `.interactive/` (`server/apps_interactive.zig`): null when it has none; refused, saying
/// why, when they changed since.
pub fn read_own(
    arena: std.mem.Allocator,
    io: std.Io,
    app_dir: []const u8,
    name: []const u8,
    reason: *report.Reason,
) !?Interactive {
    std.debug.assert(app_dir.len > 0);
    std.debug.assert(name.len > 0);

    const sources = try std.fs.path.join(arena, &.{ app_dir, "interactive" });

    if (try newest_source(io, sources) == null) {
        return null;
    }

    if (try stale(io, arena, app_dir)) {
        reason.set("[{s}] interactive/ changed since it was built: `publr apps load` " ++
            "builds it", .{name});
        return error.InvalidApp;
    }

    const built = try std.fs.path.join(arena, &.{ app_dir, built_dir });
    var folder = try std.Io.Dir.cwd().openDir(io, built, .{});
    defer folder.close(io);

    const limit: std.Io.Limit = .limited(16 << 20);

    return .{
        .plugin = "",
        .components = try folder.readFileAlloc(io, "components.json", arena, limit),
        .render = try folder.readFileAlloc(io, "render.js", arena, limit),
        .browser = try folder.readFileAlloc(io, "stores.js", arena, limit),
        .classes = try folder.readFileAlloc(io, "classes.txt", arena, limit),
    };
}

/// Whether the app at `app_dir` has interactive components newer than their build.
pub fn stale(io: std.Io, arena: std.mem.Allocator, app_dir: []const u8) !bool {
    std.debug.assert(app_dir.len > 0);

    const sources = try std.fs.path.join(arena, &.{ app_dir, "interactive" });
    const newest = try newest_source(io, sources) orelse return false;
    const render = try std.fs.path.join(arena, &.{ app_dir, built_dir, "render.js" });
    const built = std.Io.Dir.cwd().statFile(io, render, .{}) catch return true;

    std.debug.assert(newest != 0);

    return built.mtime.nanoseconds < newest;
}

/// When the newest `.ptsx` under `sources` changed; null when it holds none.
fn newest_source(io: std.Io, sources: []const u8) !?i96 {
    std.debug.assert(sources.len > 0);

    var folder = std.Io.Dir.cwd().openDir(io, sources, .{
        .iterate = true,
    }) catch return null;
    defer folder.close(io);

    var entries = folder.iterate();
    var newest: ?i96 = null;
    var count: u32 = 0;

    while (try entries.next(io)) |entry| : (count += 1) {
        if (count == components_max * 16) {
            break;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ptsx")) {
            continue;
        }

        const stat = try folder.statFile(io, entry.name, .{});

        newest = @max(newest orelse stat.mtime.nanoseconds, stat.mtime.nanoseconds);
    }

    return newest;
}
