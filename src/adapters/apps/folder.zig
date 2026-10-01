//! A project's apps read from its folder (`<apps_dir>/<folder>/app.zon` and the templates
//! beside it) when `serve` starts and whenever it is told to load them again, so changing an
//! app never needs a rebuild. What still needs compiling comes from the build's app of the
//! same `.name`: its interactive components, its middleware and the client code they bring. An
//! app with none compiled in serves the common client code and may have neither.
const std = @import("std");
const jit = @import("publr_jit");
const model_app = @import("../../model/app.zig");
const registry = @import("../../server/registry.zig");
const report = @import("../../lib/report.zig");
const spec_module = @import("spec.zig");

const Spec = spec_module.Spec;
const File = spec_module.File;

const zon_bytes_max: u32 = 1 << 20;
const template_bytes_max: u32 = 4 << 20;
const templates_max: u32 = 4096;

/// The specs read, and the memory they live in, until the next load replaces them.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    specs: []const Spec,

    pub fn deinit(loaded: *Loaded) void {
        std.debug.assert(loaded.specs.len <= spec_module.apps_max);

        loaded.arena.deinit();
        loaded.* = undefined;
    }
};

/// Where a project's apps are: `dir` when it was named (`--apps`); else the project's own
/// `apps/` beside where Publr runs, when there is one; else where the build's apps came from
/// (a binary built from a preset points at the preset's).
pub fn resolve_dir(io: std.Io, dir: []const u8) []const u8 {
    std.debug.assert(dir.len > 0);

    const named = !std.mem.eql(u8, dir, spec_module.public_dir);
    var own = std.Io.Dir.cwd().openDir(io, "apps", .{}) catch return dir;

    own.close(io);

    return if (named) dir else "apps";
}

/// The apps a project serves: those in its folder when it has any, else the binary's own.
pub const Apps = struct {
    loaded: ?Loaded,
    specs: []const Spec,

    pub fn deinit(apps: *Apps) void {
        std.debug.assert(apps.specs.len <= spec_module.apps_max);

        if (apps.loaded) |*loaded| {
            loaded.deinit();
        }

        apps.* = undefined;
    }
};

pub fn project_apps(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    reason: *report.Reason,
) !Apps {
    std.debug.assert(dir.len > 0);

    const loaded = try read(gpa, io, dir, reason) orelse {
        return .{ .loaded = null, .specs = spec_module.all };
    };

    std.debug.assert(loaded.specs.len > 0);

    return .{ .loaded = loaded, .specs = loaded.specs };
}

/// The apps under `dir`, or null when it holds none: the binary's own are served then. A
/// problem (an `app.zon` that does not parse, a mount taken twice) names the app in `reason`.
pub fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    reason: *report.Reason,
) !?Loaded {
    std.debug.assert(dir.len > 0);

    var loaded: Loaded = .{ .arena = .init(gpa), .specs = &.{} };
    errdefer loaded.arena.deinit();

    const arena = loaded.arena.allocator();
    const folders = try app_folders(arena, io, dir) orelse {
        loaded.arena.deinit();
        return null;
    };
    const specs = try arena.alloc(Spec, folders.len);

    for (folders, specs) |folder, *spec| {
        spec.* = try read_app(arena, io, dir, folder, reason);
    }

    try check_all(specs, reason);
    loaded.specs = specs;

    std.debug.assert(loaded.specs.len > 0);

    return loaded;
}

/// Every folder under `dir` with an `app.zon`, sorted; null when there is none.
fn app_folders(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !?[]const []const u8 {
    var root = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer root.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = root.iterate();

    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or names.items.len > spec_module.apps_max) {
            continue;
        }

        const zon = try std.fmt.allocPrint(arena, "{s}/app.zon", .{entry.name});

        root.access(io, zon, .{}) catch continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, less_than);

    if (names.items.len == 0) {
        return null;
    }

    std.debug.assert(names.items.len > 0);

    return names.items;
}

fn read_app(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    folder: []const u8,
    reason: *report.Reason,
) !Spec {
    std.debug.assert(folder.len > 0);

    const app_dir = try std.fs.path.join(arena, &.{ dir, folder });
    const config = try read_config(arena, io, app_dir, folder, reason);
    const name = config.name;

    if (!model_app.valid_name(name) or !model_app.valid_label(config.label)) {
        reason.set("[{s}] app.zon: `.name` is [a-z][a-z0-9_]*, 1 to 32 characters; " ++
            "`.label` one line of at most 64 bytes", .{folder});
        return error.InvalidApp;
    }

    const compiled = spec_module.find(name);
    const style_path = try std.fs.path.join(arena, &.{ app_dir, "public", "style.css" });
    const limit: std.Io.Limit = .limited(zon_bytes_max);
    const style_css = std.Io.Dir.cwd().readFileAlloc(io, style_path, arena, limit) catch "";

    if (compiled == null) {
        try refuse_compiled_parts(arena, io, app_dir, name, reason);
    }

    const tokens = try arena.alloc(jit.Token, config.tokens.len);

    for (config.tokens, 0..) |token, index| {
        tokens[index] = .{ .name = token.name, .value = token.value };
    }

    return .{
        .name = name,
        .label = model_app.label_of(name, config.label),
        .folder = folder,
        .mount = config.mount,
        .roles = config.roles,
        .plugins = config.plugins,
        .templates = try read_templates(arena, io, app_dir),
        .assets = if (compiled) |built| built.assets else spec_module.common_assets,
        .tokens = try jit.extendThemeRuntime(arena, jit.default_theme, .{ .tokens = tokens }),
        .style_css = style_css,
        .interactive_classes = if (compiled) |built| built.interactive_classes else "",
        .pjsx_components = if (compiled) |built| built.pjsx_components else &.{},
        .pjsx_renders = if (compiled) |built| built.pjsx_renders else &.{},
        .middleware = if (compiled) |built| built.middleware else null,
    };
}

fn read_config(
    arena: std.mem.Allocator,
    io: std.Io,
    app_dir: []const u8,
    folder: []const u8,
    reason: *report.Reason,
) !model_app.Config {
    std.debug.assert(app_dir.len > 0);

    const path = try std.fs.path.join(arena, &.{ app_dir, "app.zon" });
    const limit: std.Io.Limit = .limited(zon_bytes_max);
    const text = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, limit, .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = .{};

    return std.zon.parse.fromSliceAlloc(model_app.Config, arena, text, &diagnostics, .{}) catch {
        reason.set("[{s}] app.zon: {f}", .{ folder, diagnostics });
        return error.InvalidApp;
    };
}

/// What only a build compiles, in an app the build does not have.
fn refuse_compiled_parts(
    arena: std.mem.Allocator,
    io: std.Io,
    app_dir: []const u8,
    name: []const u8,
    reason: *report.Reason,
) !void {
    std.debug.assert(name.len > 0);

    const cwd = std.Io.Dir.cwd();
    const middleware = try std.fs.path.join(arena, &.{ app_dir, "middleware.zig" });
    const interactive = try std.fs.path.join(arena, &.{ app_dir, "interactive" });

    if (cwd.access(io, middleware, .{})) |_| {
        reason.set("[{s}] middleware.zig needs a build of Publr; a plugin's request hook " ++
            "will replace it", .{name});
        return error.InvalidApp;
    } else |_| {}

    if (cwd.access(io, interactive, .{})) |_| {
        reason.set("[{s}] interactive/ components need a build of Publr for now", .{name});
        return error.InvalidApp;
    } else |_| {}
}

/// `**/*.publr` under the app, by their app-relative paths; `public/` and `interactive/` hold
/// no templates, and a template sits in a folder, never at the app's root.
fn read_templates(arena: std.mem.Allocator, io: std.Io, app_dir: []const u8) ![]const File {
    var root = try std.Io.Dir.cwd().openDir(io, app_dir, .{ .iterate = true });
    defer root.close(io);

    var files: std.ArrayList(File) = .empty;
    var walker = try root.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const top = entry.path[0 .. std.mem.indexOfScalar(u8, entry.path, '/') orelse 0];
        const skipped = std.mem.eql(u8, top, "public") or std.mem.eql(u8, top, "interactive");

        if (entry.kind != .file or top.len == 0 or skipped) {
            continue;
        }

        if (!std.mem.endsWith(u8, entry.basename, ".publr") or files.items.len == templates_max) {
            continue;
        }

        const data = try root.readFileAlloc(io, entry.path, arena, .limited(template_bytes_max));

        try files.append(arena, .{ .path = try arena.dupe(u8, entry.path), .data = data });
    }

    std.mem.sort(File, files.items, {}, file_less_than);

    std.debug.assert(files.items.len <= templates_max);

    return files.items;
}

/// What the build checks of its apps, checked of these: names, mounts, roles, and no two in
/// one place.
fn check_all(specs: []const Spec, reason: *report.Reason) !void {
    std.debug.assert(specs.len > 0);

    if (specs.len > spec_module.apps_max) {
        reason.set("more than {d} apps", .{spec_module.apps_max});
        return error.InvalidApp;
    }

    for (specs, 0..) |spec, index| {
        try check_one(spec, reason);

        for (specs[index + 1 ..]) |other| {
            if (std.mem.eql(u8, spec.name, other.name)) {
                reason.set("[{s}] named in {s} and {s}; an app's `.name` is its id, one per " ++
                    "project", .{ spec.name, spec.folder, other.folder });
                return error.InvalidApp;
            }

            if (model_app.same_place(spec.mount, other.mount)) {
                reason.set("[{s}] mounted where app {s} is", .{ spec.name, other.name });
                return error.InvalidApp;
            }
        }
    }
}

fn check_one(spec: Spec, reason: *report.Reason) !void {
    std.debug.assert(spec.name.len > 0);

    if (!model_app.valid_name(spec.name)) {
        reason.set("[{s}] a name is [a-z][a-z0-9_]*, 1 to 32 characters", .{spec.name});
        return error.InvalidApp;
    }

    if (!model_app.valid_mount(spec.mount)) {
        reason.set("[{s}] `.mount` is `.{{ .path = \"/\" }}`, a path of lower-case segments " ++
            "(not /admin, /api, /auth or /_...), or `.{{ .subdomain = \"name\" }}`", .{spec.name});
        return error.InvalidApp;
    }

    if (spec.roles.len > model_app.roles_max) {
        reason.set("[{s}] `.roles` names at most 16 roles", .{spec.name});
        return error.InvalidApp;
    }

    if (model_app.plugins_problem(spec.plugins)) |problem| {
        reason.set("[{s}] {s}", .{ spec.name, problem });
        return error.InvalidApp;
    }

    for (spec.roles) |role| {
        if (registry.Roles.get(role) == null) {
            reason.set("[{s}] `.roles` names {s}, a role no plugin declares", .{ spec.name, role });
            return error.InvalidApp;
        }
    }
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn file_less_than(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

test "an app is known by its `.name`, whatever its folder; two of one name are refused" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const zon = ".{ .name = \"www\", .label = \"Website\", .mount = .{ .path = \"/\" } }";
    const again = ".{ .name = \"www\", .mount = .{ .path = \"/other\" } }";
    var reason: report.Reason = .{};

    try scratch.dir.createDirPath(io, "apps/site-2024/content");
    try scratch.dir.writeFile(io, .{ .sub_path = "apps/site-2024/app.zon", .data = zon });

    const root = try scratch.dir.realPathFileAlloc(io, "apps", gpa);
    defer gpa.free(root);
    var loaded = (try read(gpa, io, root, &reason)).?;

    try std.testing.expectEqual(1, loaded.specs.len);
    try std.testing.expectEqualStrings("www", loaded.specs[0].name);
    try std.testing.expectEqualStrings("Website", loaded.specs[0].label);
    try std.testing.expectEqualStrings("site-2024", loaded.specs[0].folder);
    loaded.deinit();

    try scratch.dir.createDirPath(io, "apps/copy/content");
    try scratch.dir.writeFile(io, .{ .sub_path = "apps/copy/app.zon", .data = again });
    try std.testing.expectError(error.InvalidApp, read(gpa, io, root, &reason));
    try std.testing.expect(std.mem.indexOf(u8, reason.text(), "copy and site-2024") != null);
}
