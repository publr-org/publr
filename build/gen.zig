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
    /// The render runtime the generated views import; the theme's components share it.
    runtime: *std.Build.Module,
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

    const pjsx_host = builder.dependency("pjsx", .{ .target = builder.graph.host });
    const tool = builder.addExecutable(.{
        .name = "pjsx_gen",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/pjsx_gen.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "pjsx", .module = pjsx_host.module("pjsx") }},
        }),
    });
    const run = builder.addRunArtifact(tool);
    const components = builder.pathFromRoot(components_dir);
    const icons = builder.pathFromRoot(icons_dir);

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

    const runtime = add_runtime(builder, pjsx_host, target, optimize);
    const views = builder.createModule(.{
        .root_source_file = out.path(builder, "views.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "runtime", .module = runtime }},
    });

    std.debug.assert(views.root_source_file != null);

    return .{
        .views = views,
        .classes = out.path(builder, "classes.txt"),
        .stores = out.path(builder, "stores.js"),
        .runtime = runtime,
        .tool = tool,
    };
}

fn add_runtime(
    builder: *std.Build,
    pjsx_host: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    std.debug.assert(builder.build_root.path != null);

    const jit = builder.dependency("publr_jit", .{ .target = target, .optimize = optimize });
    const class_merge = builder.createModule(.{
        .root_source_file = builder.path("src/ui/class_merge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "publr_jit", .module = jit.module("publr_jit") }},
    });
    class_merge.addAnonymousImport("ui_theme", .{
        .root_source_file = builder.path("ui/styles/theme.zon"),
    });

    const runtime = builder.createModule(.{
        .root_source_file = pjsx_host.path("src/runtime/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "class_merge", .module = class_merge }},
    });

    std.debug.assert(runtime.root_source_file != null);

    return runtime;
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
    var handle = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch {
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

            run.addFileInput(.{ .cwd_relative = path });
        }
    }
}
