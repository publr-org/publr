const std = @import("std");
const vendors = @import("vendors.zig");
const native_plugins = @import("native_plugins.zig");
const gen = @import("gen.zig");
const jit = @import("jit.zig");
const apps = @import("apps.zig");
const diagnostic = @import("diagnostic.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");

/// Where the compiled-in apps and native plugins come from, relative to this repository:
/// a project built from another repository (Publr Cloud) names its own.
pub const Sources = struct {
    apps_dir: []const u8,
    native_plugins_dir: []const u8,
    apps_max: u32,
    /// The sandboxed plugins `zig build sandboxed-plugins` builds.
    sandboxed_plugins_dir: []const u8 = "sandboxed-plugins",
    /// Where `serve` reads each app's `public/` files by default: `apps`, relative to where
    /// it runs, or (built with `-Dpreset`) the preset's apps folder, wherever it runs.
    public_dir: []const u8 = "apps",
    /// Whether the binary carries the compiler for sandboxed plugins (`publr zig`).
    compiler: bool = true,
};

/// `-Dpreset=<dir>`: a project's parts kept together, `<dir>/apps`, `<dir>/native-plugins`
/// and `<dir>/sandboxed-plugins`, for developing against locally. Null without it.
pub fn preset(builder: *std.Build) ?[]const u8 {
    std.debug.assert(builder.build_root.path != null);

    const dir = builder.option(
        []const u8,
        "preset",
        "A preset folder, relative to this repository: its apps, native and sandboxed plugins",
    ) orelse return null;

    if (dir.len == 0 or std.fs.path.isAbsolute(dir)) {
        diagnostic.fail("-Dpreset: pass a path relative to {s}", .{builder.build_root.path.?});
    }

    return dir;
}

pub fn sources(builder: *std.Build) Sources {
    const from_preset = preset(builder);
    const apps_dir = builder.option(
        []const u8,
        "apps",
        "The folder of compiled-in apps, relative to this repository (default: apps)",
    ) orelse if (from_preset) |dir| builder.pathJoin(&.{ dir, "apps" }) else apps.dir_default;
    const native_plugins_dir = builder.option(
        []const u8,
        "native-plugins",
        "The folder of native plugins, relative to this repository (default: native-plugins)",
    ) orelse if (from_preset) |dir|
        builder.pathJoin(&.{ dir, "native-plugins" })
    else
        native_plugins.dir_default;
    const sandboxed_plugins_dir = builder.option(
        []const u8,
        "sandboxed-plugins",
        "The folder of sandboxed plugins `zig build sandboxed-plugins` builds " ++
            "(default: sandboxed-plugins)",
    ) orelse if (from_preset) |dir|
        builder.pathJoin(&.{ dir, "sandboxed-plugins" })
    else
        "sandboxed-plugins";
    const apps_max = builder.option(
        u32,
        "apps-max",
        "How many apps one project may compile in (default: 32)",
    ) orelse apps.apps_max_default;
    const compiler = builder.option(
        bool,
        "compiler",
        "Carry the compiler for sandboxed plugins, `publr zig` (default: true)",
    ) orelse true;
    const chosen: Sources = .{
        .apps_dir = apps_dir,
        .native_plugins_dir = native_plugins_dir,
        .apps_max = apps_max,
        .sandboxed_plugins_dir = sandboxed_plugins_dir,
        .public_dir = if (from_preset != null) builder.pathFromRoot(apps_dir) else "apps",
        .compiler = compiler,
    };
    const root = builder.build_root.path.?;

    for ([_][]const u8{ chosen.apps_dir, chosen.native_plugins_dir }) |dir| {
        if (dir.len == 0 or std.fs.path.isAbsolute(dir)) {
            diagnostic.fail("{s}: pass a path relative to {s}", .{ dir, root });
        }
    }

    if (apps_max == 0 or apps_max > 1024) {
        diagnostic.fail("-Dapps-max is 1 to 1024", .{});
    }

    std.debug.assert(chosen.apps_dir.len > 0);
    std.debug.assert(chosen.native_plugins_dir.len > 0);

    return chosen;
}

/// The same sources with the apps from `dir` instead.
pub fn with_apps(from: Sources, dir: []const u8) Sources {
    std.debug.assert(dir.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(dir));

    var changed = from;

    changed.apps_dir = dir;

    return changed;
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

    // The sandbox runs plugins natively; the browser build has none yet, nor a compiler.
    if (target.result.os.tag != .wasi) {
        const publr_wasm = builder.dependency("publr_wasm", .{
            .target = target,
            .release = optimize != .Debug,
        });

        module.addImport("publr_wasm", publr_wasm.module("publr_wasm"));
        module.addAnonymousImport("agents_guide", .{
            .root_source_file = builder.path("docs/agents.md"),
        });
    }

    add_compiler(builder, module, target, optimize, from.compiler);

    vendors.add_include_paths(builder, module);
    module.linkLibrary(vendors.add_library(builder, target));
    native_plugins.add(builder, module, from.native_plugins_dir);

    const generated = gen.add(builder, target, optimize);

    module.addImport("views", generated.views);
    module.addImport("runtime", generated.runtime);
    jit.add(builder, module, generated.classes, optimize);
    add_admin_scripts(builder, module, generated.stores);
    add_apps(builder, module, generated, optimize, from);

    std.debug.assert(module.link_libc == true);
    std.debug.assert(module.root_source_file != null);

    return module;
}

/// The compiler for sandboxed plugins, built for `target` without LLVM, unless the binary is
/// built without it (`-Dcompiler=false`) or for the browser. `toolchain_options.compiler`
/// says which.
fn add_compiler(
    builder: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wanted: bool,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.build_root.path != null);

    const carried = wanted and target.result.os.tag != .wasi;
    const options = builder.addOptions();

    options.addOption(bool, "compiler", carried);
    module.addImport("toolchain_options", options.createModule());

    if (carried) {
        const publr_zig = builder.dependency("publr_zig", .{
            .target = target,
            .release = optimize != .Debug,
        });

        module.addImport("publr_zig", publr_zig.module("publr_zig"));
        module.addAnonymousImport("sdk_archive", .{
            .root_source_file = sandboxed_plugins.sdk_archive(builder, publr_zig.artifact("pack")),
        });
    }
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
/// whose rendering changed builds every page again, though no app changed.
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

/// The compiled-in apps and what the run-time JIT compiles their stylesheets with.
fn add_apps(
    builder: *std.Build,
    module: *std.Build.Module,
    generated: gen.Generated,
    optimize: std.builtin.OptimizeMode,
    from: Sources,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(from.apps_max > 0);

    const jit_host = builder.dependency("publr_jit", .{ .target = builder.graph.host });
    const options = builder.addOptions();

    options.addOption(u32, "apps_max", from.apps_max);
    options.addOption(bool, "minify", optimize != .Debug);
    options.addOption([]const u8, "engine_stamp", engine_stamp(builder));
    options.addOption([]const u8, "public_dir", from.public_dir);

    module.addImport("apps_options", options.createModule());
    module.addAnonymousImport("apps_preflight_css", .{
        .root_source_file = jit_host.path("src/preflight.css"),
    });
    apps.add(builder, module, generated.runtime, generated.tool, from.apps_dir, from.apps_max);
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
