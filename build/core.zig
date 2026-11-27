const std = @import("std");
const repository = @import("repository.zig");
const limits_module = @import("limits.zig");
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
    /// Every plugin, one folder each: `<dir>/<name>/main.zig`.
    plugins_dir: []const u8,
    /// Which of them are compiled in, from `publr.zon` beside the folder; the rest are
    /// built for the sandbox.
    native: native_plugins.Native,
    apps_max: u32,
    /// Where `serve` reads each app's `public/` files by default: `apps`, relative to where
    /// it runs, or (built with `-Dpreset`) the preset's apps folder, wherever it runs.
    public_dir: []const u8 = "apps",
    /// What one type and one entry may hold (`limits.zig`).
    limits: limits_module.Limits = .{},
    /// In Debug, the request arenas name the call sites that fill them (`-Darena-trace`).
    arena_trace: bool = false,
};

/// `-Dpreset=<dir>`: a project's parts kept together, `<dir>/apps`, `<dir>/plugins` and
/// `<dir>/publr.zon`, for developing against locally. Null without it.
pub fn preset(builder: *std.Build) ?[]const u8 {
    std.debug.assert(builder.root.sub_path.len == 0);

    const dir = builder.option(
        []const u8,
        "preset",
        "A preset folder, relative to this repository: its apps, native and sandboxed plugins",
    ) orelse return null;

    if (dir.len == 0 or std.fs.path.isAbsolute(dir)) {
        diagnostic.fail("-Dpreset: pass a path relative to {s}", .{repository.path(builder, ".")});
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
    const plugins_dir = builder.option(
        []const u8,
        "plugins",
        "The folder of plugins, relative to this repository (default: plugins); " ++
            "`publr.zon` beside it says which are compiled in",
    ) orelse if (from_preset) |dir|
        builder.pathJoin(&.{ dir, "plugins" })
    else
        native_plugins.dir_default;
    const apps_max = builder.option(
        u32,
        "apps-max",
        "How many apps one project may compile in (default: 32)",
    ) orelse apps.apps_max_default;
    const arena_trace = builder.option(
        bool,
        "arena-trace",
        "In Debug, name the call sites that fill a request's arena (slow: a stack per allocation)",
    ) orelse false;
    const chosen: Sources = .{
        .apps_dir = apps_dir,
        .plugins_dir = plugins_dir,
        .native = native_plugins.native_of(builder, plugins_dir),
        .apps_max = apps_max,
        .public_dir = if (from_preset != null) repository.path(builder, apps_dir) else "apps",
        .limits = limits_module.from(builder),
        .arena_trace = arena_trace,
    };
    const root = repository.path(builder, ".");

    for ([_][]const u8{ chosen.apps_dir, chosen.plugins_dir }) |dir| {
        if (dir.len == 0 or std.fs.path.isAbsolute(dir)) {
            diagnostic.fail("{s}: pass a path relative to {s}", .{ dir, root });
        }
    }

    if (apps_max == 0 or apps_max > 1024) {
        diagnostic.fail("-Dapps-max is 1 to 1024", .{});
    }

    std.debug.assert(chosen.apps_dir.len > 0);
    std.debug.assert(chosen.plugins_dir.len > 0);

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
    optimize: std.builtin.Optimize,
    from: Sources,
) *std.Build.Module {
    const publr_sqlite = builder.dependency("publr_sqlite", .{
        .target = target,
        .release = optimize != .debug,
    });
    const publr_http = builder.dependency("publr_http", .{
        .target = target,
        .release = optimize != .debug,
        .@"arena-trace" = from.arena_trace,
    });
    const publr_auth = builder.dependency("publr_auth", .{
        .target = target,
        .release = optimize != .debug,
    });
    const publr_groq = builder.dependency("publr_groq", .{
        .target = target,
        .release = optimize != .debug,
    });
    const publr_deps = builder.dependency("publr_deps", .{
        .target = target,
        .release = optimize != .debug,
    });
    const publr_ai = builder.dependency("publr_ai", .{
        .target = target,
        .release = optimize != .debug,
    });
    const publr_text = builder.dependency("publr_text", .{
        .target = target,
    });
    const publr_api = builder.dependency("publr_api", .{
        .target = target,
        .optimize = optimize,
    });
    const publr_jit = builder.dependency("publr_jit", .{
        .target = target,
        .optimize = optimize,
    });
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/p.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "publr_sqlite",
                .module = publr_sqlite.module("publr_sqlite"),
            },
            .{
                .name = "limits_options",
                .module = limits_module.module(builder, from.limits),
            },
            .{
                .name = "publr_http",
                .module = publr_http.module("publr_http"),
            },
            .{
                .name = "publr_auth",
                .module = publr_auth.module("publr_auth"),
            },
            .{
                .name = "publr_groq",
                .module = publr_groq.module("publr_groq"),
            },
            .{
                .name = "publr_deps",
                .module = publr_deps.module("publr_deps"),
            },
            .{
                .name = "publr_ai",
                .module = publr_ai.module("publr_ai"),
            },
            .{
                .name = "publr_text",
                .module = publr_text.module("publr_text"),
            },
            .{
                .name = "publr_api",
                .module = publr_api.module("publr_api"),
            },
            .{
                .name = "publr_jit",
                .module = publr_jit.module("publr_jit"),
            },
        },
    });

    // The sandbox runs installed plugins on WAMR natively and on the browser's own
    // WebAssembly in the browser build (`publr_wasm` picks by target).
    const publr_wasm = builder.dependency("publr_wasm", .{
        .target = target,
        .release = optimize != .debug,
    });

    module.addImport("publr_wasm", publr_wasm.module("publr_wasm"));

    // The browser build has no CLI, nor the guide it hands out.
    if (target.result.os.tag != .wasi) {
        module.addAnonymousImport("agents_guide", .{
            .root_source_file = builder.path("docs/agents.md"),
        });
    }

    vendors.add_image_api(builder, module);
    module.linkLibrary(vendors.add_library(builder, target));
    @import("javascript.zig").add(builder, module);
    add_public(builder, module);
    native_plugins.add(builder, module, from.plugins_dir, from.native);

    const plugin_ui = native_plugins.ui_dirs(builder, from.plugins_dir, from.native);
    const plugin_names = native_plugins.names_of(builder, from.plugins_dir, from.native);

    @import("i18n.zig").add(builder, module, from.plugins_dir, plugin_names);
    const generated = gen.add(builder, target, optimize, plugin_ui);
    @import("native_interactive.zig").add(
        builder,
        module,
        from.plugins_dir,
        from.native,
        generated.tool,
    );

    module.addImport("views", generated.views);
    module.addImport("runtime", generated.runtime);
    module.addImport("request", generated.request);
    module.addImport("pjsx_syntax", generated.runtime);
    const book = jit.add(builder, module, generated.classes, optimize);

    generated.class_merge.addAnonymousImport("class_book", .{
        .root_source_file = book.zig,
    });
    module.addImport("class_merge", generated.class_merge);
    add_admin_scripts(builder, module, generated.stores);
    const asset_version = @import("admin_assets.zig").add(builder, module, .{
        .styles = book.css,
        .stores = generated.stores,
        .class_book = book.json,
    });
    module.addAnonymousImport("admin_expressions", .{
        .root_source_file = generated.expressions,
    });
    add_apps(builder, module, generated, optimize, from);
    add_sdk(builder, module, target, from, .{
        .views = generated.out,
        .asset_version = asset_version,
    });

    std.debug.assert(module.link_libc == true);
    std.debug.assert(module.root_source_file != null);

    return module;
}

/// What the build made that the SDK archive carries.
const SdkGenerated = struct {
    /// The admin's generated views.
    views: std.Build.LazyPath,
    /// The version of the admin's files (`admin_assets.zig`).
    asset_version: std.Build.LazyPath,
};

/// The SDK sandboxed plugins are built against, carried wherever there is a file system:
/// `plugin sdk` and `plugin prepare` write it out for the compiler outside this binary (the
/// `publr` command's). `sdk_options.sdk` says whether it is there. The archive is packed by
/// `../lib/zig`'s `pack` tool; Publr carries no compiler.
fn add_sdk(
    builder: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    from: Sources,
    generated: SdkGenerated,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.root.sub_path.len == 0);

    const has_sdk = target.result.os.tag != .wasi;
    const options = builder.addOptions();

    options.addOption(bool, "sdk", has_sdk);
    module.addImport("sdk_options", options.createModule());

    if (!has_sdk) {
        return;
    }

    const publr_zig = builder.dependency("publr_zig", .{});

    module.addAnonymousImport("sdk_archive", .{
        .root_source_file = sandboxed_plugins.sdk_archive(
            builder,
            publr_zig.artifact("pack"),
            limits_module.source(builder, from.limits),
            .{
                .views = generated.views,
                .lowering = lowering(builder, target),
                .asset_version = generated.asset_version,
            },
        ),
    });
}

/// The views' lowering (`scripts/pjsx_gen.zig` on the PJSX compiler) as an executable for the
/// target, carried in the SDK archive: `publr plugin build` runs it on an installed plugin's
/// views, so nothing is compiled to lower them.
fn lowering(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
) std.Build.LazyPath {
    std.debug.assert(builder.root.sub_path.len == 0);

    const pjsx = builder.dependency("pjsx", .{
        .target = target,
        .optimize = .safe,
    });
    const tool = builder.addExecutable(.{
        .name = "pjsx_gen",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/pjsx_gen.zig"),
            .target = target,
            .optimize = .safe,
            .imports = &.{
                .{
                    .name = "pjsx",
                    .module = pjsx.module("pjsx"),
                },
                // Only `Shape` is read here, so the render runtime is not needed.
                .{
                    .name = "request",
                    .module = builder.createModule(.{
                        .root_source_file = builder.path("ui/request.zig"),
                    }),
                },
            },
        }),
    });

    return tool.getEmittedBin();
}

/// What the admin's pages run in the browser: the PublrJS runtime from the sibling
/// repository and the generated stores, served under `/admin/`.
fn add_admin_scripts(
    builder: *std.Build,
    module: *std.Build.Module,
    stores: std.Build.LazyPath,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.root.sub_path.len == 0);

    module.addAnonymousImport("admin_stores_js", .{
        .root_source_file = stores,
    });

    // The block editor, built for the admin: its modules import the runtime files below.
    const editor = builder.dependency("publr_editor", .{});
    module.addAnonymousImport("editor_files", .{
        .root_source_file = editor.namedLazyPath("admin").path(builder, "files.zig"),
    });

    inline for (@import("../src/ui/client_files.zig").names) |name| {
        module.addAnonymousImport(name, .{
            .root_source_file = builder.path("../publr-js/dist/" ++ name ++ ".js"),
        });
    }
}

/// Core's own source, fingerprinted: part of what a built site is stamped with, so a Publr
/// whose rendering changed builds every page again, though no app changed.
fn engine_stamp(builder: *std.Build) []const u8 {
    std.debug.assert(builder.root.sub_path.len == 0);

    const io = builder.graph.io;
    var dir = repository.dir(builder).openDir(io, "src", .{
        .iterate = true,
    }) catch
        @panic("src/ is missing");
    defer dir.close(io);

    var walker = dir.walk(builder.allocator) catch @panic("OOM");
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;

    repository.read_under(builder, "src", .folder);

    while (walker.next(io) catch @panic("walking src/")) |entry| {
        if (entry.kind == .directory) {
            repository.read_under(builder, builder.pathJoin(&.{ "src", entry.path }), .folder);
        }

        if (entry.kind == .file) {
            repository.read_under(builder, builder.pathJoin(&.{ "src", entry.path }), .file);
            paths.append(builder.allocator, builder.dupe(entry.path)) catch @panic("OOM");
        }
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);

    var hash = std.hash.Fnv1a_64.init();

    repository.read_under(builder, "vendor/quickjs/VERSION", .file);

    const javascript_version = repository.dir(builder).readFileAlloc(
        io,
        "vendor/quickjs/VERSION",
        builder.allocator,
        .limited(4096),
    ) catch
        @panic("reading JavaScript engine version");
    hash.update(javascript_version);

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
    optimize: std.builtin.Optimize,
    from: Sources,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(from.apps_max > 0);

    const jit_host = builder.dependency("publr_jit", .{
        .target = builder.graph.host,
    });
    const options = builder.addOptions();

    options.addOption(u32, "apps_max", from.apps_max);
    options.addOption(bool, "minify", optimize != .debug);
    options.addOption([]const u8, "engine_stamp", engine_stamp(builder));
    options.addOption([]const u8, "public_dir", from.public_dir);

    module.addImport("apps_options", options.createModule());
    module.addAnonymousImport("apps_preflight_css", .{
        .root_source_file = jit_host.path("src/preflight.css"),
    });
    apps.add(
        builder,
        module,
        generated.runtime,
        generated.request,
        generated.tool,
        from.apps_dir,
        from.apps_max,
    );
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

    module.addImport("p", library);

    return module;
}

/// `publr`, what plugins and app middleware import: `src/publr.zig`, forwarding the public
/// names of `p` (the library, `src/p.zig`), reaching nothing else. One per library, as a
/// file belongs to one module; the library keeps it under `publr_sdk` for the build to find
/// (`publr` is the admin's script there), and core never imports it.
fn add_public(builder: *std.Build, library: *std.Build.Module) void {
    std.debug.assert(library.root_source_file != null);
    std.debug.assert(library.import_table.get("publr_sdk") == null);

    const public = builder.createModule(.{
        .root_source_file = builder.path("src/publr.zig"),
        .target = library.resolved_target,
        .optimize = library.optimize,
    });

    public.addImport("p", library);
    library.addImport("publr_sdk", public);
}

pub fn public_of(library: *std.Build.Module) *std.Build.Module {
    std.debug.assert(library.root_source_file != null);

    const public = library.import_table.get("publr_sdk") orelse @panic("publr not added");

    std.debug.assert(public != library);

    return public;
}
