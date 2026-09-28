//! The admin stylesheet: the JIT (a path dependency) over the classes the generated
//! views use, themed by `ui/styles/theme.zon` over `ui/styles/base.css`'s palette, with the JIT's
//! preflight ahead of everything. Embedded into the app as `styles_css` and served
//! at `/admin/styles.css`. Minified except in Debug builds.
const std = @import("std");

pub fn add(
    builder: *std.Build,
    module: *std.Build.Module,
    classes: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
) void {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.build_root.path != null);

    const jit = builder.dependency("publr_jit", .{ .target = builder.graph.host });
    const run = builder.addRunArtifact(jit.artifact("jit"));

    run.addPrefixedFileArg("--theme=", builder.path("ui/styles/theme.zon"));
    run.addPrefixedFileArg("--prepend=", jit.path("src/preflight.css"));
    run.addPrefixedFileArg("--prepend=", builder.path("ui/styles/base.css"));

    if (optimize == .Debug) {
        run.addArg("--no-minify");
    }

    run.addFileArg(classes);
    // The compiler's collector cannot see classes inside template-literal props or wire
    // payloads; a hand-kept second manifest names those.
    run.addFileArg(builder.path("ui/styles/extra-classes.txt"));

    const css = run.captureStdOut(.{});

    module.addAnonymousImport("styles_css", .{ .root_source_file = css });
}
