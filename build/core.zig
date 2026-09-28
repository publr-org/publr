const std = @import("std");
const vendors = @import("vendors.zig");
const plugins = @import("plugins.zig");
const gen = @import("gen.zig");
const jit = @import("jit.zig");
const theme = @import("theme.zig");
const diagnostic = @import("diagnostic.zig");

/// Where the embedded theme and the compiled-in plugins come from, as paths relative to
/// this repository: a site built from another repository (Publr Cloud) names its own.
pub const Sources = struct {
    theme_dir: []const u8,
    plugins_dir: []const u8,
};

pub fn sources(builder: *std.Build) Sources {
    const name = builder.option([]const u8, "theme", "The folder under themes/ to embed");
    const theme_dir = builder.option(
        []const u8,
        "theme-dir",
        "A theme folder anywhere, relative to this repository (instead of -Dtheme)",
    );
    const plugins_dir = builder.option(
        []const u8,
        "plugins",
        "The folder of compiled-in plugins, relative to this repository (default: plugins)",
    ) orelse plugins.dir_default;

    if (name != null and theme_dir != null) {
        diagnostic.fail("-Dtheme and -Dtheme-dir name the same thing; pass one", .{});
    }

    const named = builder.pathJoin(&.{ "themes", valid_name(name orelse "default") });
    const chosen: Sources = .{ .theme_dir = theme_dir orelse named, .plugins_dir = plugins_dir };

    const root = builder.build_root.path.?;

    for ([_][]const u8{ chosen.theme_dir, chosen.plugins_dir }) |dir| {
        if (dir.len == 0 or std.fs.path.isAbsolute(dir)) {
            diagnostic.fail("{s}: pass a path relative to {s}", .{ dir, root });
        }
    }

    std.debug.assert(chosen.theme_dir.len > 0);
    std.debug.assert(chosen.plugins_dir.len > 0);

    return chosen;
}

fn valid_name(name: []const u8) []const u8 {
    const separator = std.mem.indexOfAny(u8, name, "/\\") != null;
    const dots = std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");

    if (name.len == 0 or separator or dots) {
        diagnostic.fail("-Dtheme must name a folder under themes/", .{});
    }

    std.debug.assert(name.len > 0);
    std.debug.assert(!separator and !dots);

    return name;
}

pub fn add_module(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: Sources,
) *std.Build.Module {
    const publr_sqlite = builder.dependency("publr_sqlite", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const publr_http = builder.dependency("publr_http", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const publr_auth = builder.dependency("publr_auth", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const publr_deps = builder.dependency("publr_deps", .{
        .target = target,
        .release = optimize != .Debug,
    });
    const publr_jit = builder.dependency("publr_jit", .{ .target = target, .optimize = optimize });
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/publr.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "publr_sqlite", .module = publr_sqlite.module("publr_sqlite") },
            .{ .name = "publr_http", .module = publr_http.module("publr_http") },
            .{ .name = "publr_auth", .module = publr_auth.module("publr_auth") },
            .{ .name = "publr_deps", .module = publr_deps.module("publr_deps") },
            .{ .name = "publr_jit", .module = publr_jit.module("publr_jit") },
        },
    });

    vendors.add_include_paths(builder, module);
    module.linkLibrary(vendors.add_library(builder, target));
    plugins.add(builder, module, from.plugins_dir);

    const generated = gen.add(builder, target, optimize);

    module.addImport("views", generated.views);
    module.addImport("runtime", generated.runtime);
    jit.add(builder, module, generated.classes, optimize);
    add_admin_scripts(builder, module, generated.stores);
    add_theme(builder, module, generated, optimize, from.theme_dir);

    std.debug.assert(module.link_libc == true);
    std.debug.assert(module.root_source_file != null);

    return module;
}

/// What the admin's pages run in the browser: the PublrJS runtime from the sibling
/// repository and the generated stores, served under `/admin/`.
fn add_admin_scripts(
    builder: *std.Build,
    module: *std.Build.Module,
    stores: std.Build.LazyPath,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.build_root.path != null);

    module.addAnonymousImport("admin_stores_js", .{ .root_source_file = stores });

    inline for (@import("../src/ui/client_files.zig").names) |name| {
        module.addAnonymousImport(name, .{
            .root_source_file = builder.path("../publr-js/dist/" ++ name ++ ".js"),
        });
    }
}

/// Core's own source, fingerprinted: part of what a built site is stamped with, so a Publr
/// whose rendering changed builds every page again, though the theme did not change.
fn engine_stamp(builder: *std.Build) []const u8 {
    std.debug.assert(builder.build_root.path != null);

    const io = builder.graph.io;
    var dir = builder.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch
        @panic("src/ is missing");
    defer dir.close(io);

    var walker = dir.walk(builder.allocator) catch @panic("OOM");
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch @panic("walking src/")) |entry| {
        if (entry.kind == .file) {
            paths.append(builder.allocator, builder.dupe(entry.path)) catch @panic("OOM");
        }
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);

    var hash = std.hash.Fnv1a_64.init();

    for (paths.items) |path| {
        const data = dir.readFileAlloc(io, path, builder.allocator, .limited(64 << 20)) catch
            @panic("reading src/");

        hash.update(path);
        hash.update(data);
    }

    return builder.fmt("{x:0>16}", .{hash.final()});
}

/// The embedded theme and what the site's run-time JIT compiles it with.
fn add_theme(
    builder: *std.Build,
    module: *std.Build.Module,
    generated: gen.Generated,
    optimize: std.builtin.OptimizeMode,
    theme_dir: []const u8,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(theme_dir.len > 0);

    const embedded = theme.add(builder, generated.runtime, generated.tool, theme_dir);
    const options = builder.addOptions();

    options.addOption([]const u8, "theme_name", embedded.name);
    options.addOption(bool, "minify", optimize != .Debug);
    options.addOption([]const u8, "engine_stamp", engine_stamp(builder));

    module.addImport("theme_options", options.createModule());
    module.addImport("theme_templates", embedded.templates);
    module.addImport("theme_assets", embedded.assets);
    module.addImport("theme_interactive", embedded.interactive);
    module.addImport("theme_middleware", theme.middleware(builder, module, theme_dir));
    module.addAnonymousImport("theme_interactive_classes", .{
        .root_source_file = embedded.interactive_classes,
    });
    module.addAnonymousImport("theme_tokens", .{ .root_source_file = embedded.tokens });
    module.addAnonymousImport("theme_style_css", .{ .root_source_file = embedded.style });
    module.addAnonymousImport("theme_preflight_css", .{ .root_source_file = embedded.preflight });
}

pub fn add_entry(
    builder: *std.Build,
    root: []const u8,
    library: *std.Build.Module,
) *std.Build.Module {
    std.debug.assert(root.len > 0);
    std.debug.assert(library.root_source_file != null);

    const module = builder.createModule(.{
        .root_source_file = builder.path(root),
        .target = library.resolved_target,
        .optimize = library.optimize,
        .link_libc = true,
    });

    module.addImport("publr", library);

    return module;
}
