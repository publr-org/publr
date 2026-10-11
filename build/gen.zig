//! The admin UI build: `ui/**/*.ptsx` (layouts, pages, components) and the
//! design-system components they import, lowered to Zig by the PJSX compiler (a
//! path dependency) through `scripts/pjsx_gen.zig`, into the build cache. Nothing
//! generated is committed. The generated views import `runtime` (the compiler's
//! render runtime) whose one seam, `class_merge`, is `src/ui/class_merge.zig` over
//! the JIT.
const std = @import("std");
const diagnostic = @import("diagnostic.zig");

const components_dir = "../ui/src/components";
const icons_dir = "../icons/icons";

pub const Generated = struct {
    views: *std.Build.Module,
    /// The class manifest for the JIT.
    classes: std.Build.LazyPath,
    /// The client half of the views that keep state in the browser.
    stores: std.Build.LazyPath,
    /// The views' compiled expressions as bytecode, for their first values.
    expressions: std.Build.LazyPath,
    /// The render runtime the generated views import; the theme's components share it.
    runtime: *std.Build.Module,
    /// The runtime's class merge (`src/ui/class_merge.zig`), which imports the admin's
    /// class book once the sheet's build has written it.
    class_merge: *std.Build.Module,
    /// What a view reads as `Publr.request`, filled by the admin per page.
    request: *std.Build.Module,
    tool: *std.Build.Step.Compile,
};

/// `plugin_ui` is the compiled-in plugins' `ui/` folders, relative to this repository.
pub fn add(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    plugin_ui: []const []const u8,
) Generated {
    std.debug.assert(builder.build_root.path != null);

    const pjsx_host = builder.dependency("pjsx", .{
        .target = builder.graph.host,
    });
    const tool = builder.addExecutable(.{
        .name = "pjsx_gen",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/pjsx_gen.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "pjsx",
                    .module = pjsx_host.module("pjsx"),
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
    const run = builder.addRunArtifact(tool);
    const components = builder.pathFromRoot(components_dir);
    const icons = builder.pathFromRoot(icons_dir);

    run.addArg("--engine");
    run.addDirectoryArg(builder.path("ui"));
    run.addArg(components);
    run.addArg(icons);
    const out = run.addOutputDirectoryArg("gen");

    for (plugin_ui) |dir| {
        run.addDirectoryArg(builder.path(dir));
        declare_inputs(builder, run, builder.build_root.path.?, dir, ".ptsx");
        declare_inputs(builder, run, builder.build_root.path.?, dir, ".txt");
    }

    // A directory argument is hashed by path: every file that feeds the run is declared
    // so an edit anywhere re-runs it.
    declare_inputs(builder, run, builder.build_root.path.?, "ui", ".ptsx");
    run.addFileInput(builder.path("ui/icons.txt"));
    declare_inputs(builder, run, components, "", ".ptsx");
    declare_inputs(builder, run, icons, "", ".svg");

    const parts = add_runtime(builder, pjsx_host, target, optimize);
    const runtime = parts.runtime;
    const request = builder.createModule(.{
        .root_source_file = builder.path("ui/request.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "runtime",
            .module = runtime,
        }},
    });
    const views = builder.createModule(.{
        .root_source_file = out.path(builder, "views.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "runtime",
                .module = runtime,
            },
            .{
                .name = "request",
                .module = request,
            },
        },
    });

    std.debug.assert(views.root_source_file != null);

    return .{
        .views = views,
        .classes = out.path(builder, "classes.txt"),
        .stores = out.path(builder, "stores.js"),
        .expressions = bytecode(builder, out.path(builder, "expressions.js")),
        .runtime = runtime,
        .class_merge = parts.class_merge,
        .request = request,
        .tool = tool,
    };
}

/// `expressions.js` compiled to QuickJS bytecode by a host tool.
pub fn bytecode(builder: *std.Build, source: std.Build.LazyPath) std.Build.LazyPath {
    std.debug.assert(builder.build_root.path != null);

    const vm = builder.createModule(.{
        .root_source_file = builder.path("src/template/javascript/vm.zig"),
        .target = builder.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    @import("javascript.zig").add(builder, vm);

    const tool = builder.addExecutable(.{
        .name = "expressions_bytecode",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/expressions_bytecode.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "vm",
                .module = vm,
            }},
        }),
    });
    const run = builder.addRunArtifact(tool);

    run.addFileArg(source);

    return run.addOutputFileArg("expressions.bin");
}

const Runtime = struct {
    runtime: *std.Build.Module,
    class_merge: *std.Build.Module,
};

fn add_runtime(
    builder: *std.Build,
    pjsx_host: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Runtime {
    std.debug.assert(builder.build_root.path != null);

    const jit = builder.dependency("publr_jit", .{
        .target = target,
        .optimize = optimize,
    });
    const class_merge = builder.createModule(.{
        .root_source_file = builder.path("src/ui/class_merge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "publr_jit",
            .module = jit.module("publr_jit"),
        }},
    });
    class_merge.addAnonymousImport("ui_theme", .{
        .root_source_file = builder.path("ui/styles/theme.zon"),
    });

    const runtime = builder.createModule(.{
        .root_source_file = pjsx_host.path("src/template_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "class_merge",
            .module = class_merge,
        }},
    });

    std.debug.assert(runtime.root_source_file != null);

    return .{
        .runtime = runtime,
        .class_merge = class_merge,
    };
}

/// Every file with `extension` under `root/dir`, declared as an input of `run`.
fn declare_inputs(
    builder: *std.Build,
    run: *std.Build.Step.Run,
    root: []const u8,
    dir: []const u8,
    extension: []const u8,
) void {
    std.debug.assert(root.len > 0);
    std.debug.assert(extension.len > 1);

    const io = builder.graph.io;
    const base = if (dir.len > 0) builder.pathJoin(&.{ root, dir }) else root;
    var handle = std.Io.Dir.cwd().openDir(io, base, .{
        .iterate = true,
    }) catch {
        diagnostic.fail("pjsx_gen inputs: cannot open {s}", .{base});
    };
    defer handle.close(io);
    var walker = handle.walk(builder.allocator) catch diagnostic.fail(
        "build input: out of memory",
        .{},
    );
    defer walker.deinit();

    while (walker.next(io) catch diagnostic.fail("cannot walk the build inputs", .{})) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, extension)) {
            const path = builder.pathJoin(&.{ base, builder.dupe(entry.path) });

            run.addFileInput(.{
                .cwd_relative = path,
            });
        }
    }
}
