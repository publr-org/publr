const std = @import("std");

/// The smoke drives `exe` (with apps to serve) through every entry point, and `bare` (with
/// none) through what a project without apps answers; `plugin` is the module it installs,
/// and the fixture plugins' sources are what `plugin build` builds; `native` has them
/// compiled in, for the admin's plugin slots; `installable` a module it has not, to add.
pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    bare: *std.Build.Step.Compile,
    sandboxed_plugin: std.Build.LazyPath,
    native: *std.Build.Step.Compile,
    installable: std.Build.LazyPath,
) *std.Build.Step {
    std.debug.assert(builder.build_root.path != null);

    const smoke = builder.addExecutable(.{
        .name = "smoke",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/smoke.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = builder.addRunArtifact(smoke);

    run.addArtifactArg(exe);
    run.addArtifactArg(bare);
    run.addArg(builder.pathFromRoot(".zig-cache/smoke"));
    run.addFileArg(sandboxed_plugin);
    run.addDirectoryArg(builder.path(@import("sandboxed_plugins.zig").fixture_dir));
    run.addArtifactArg(native);
    run.addFileArg(installable);
    run.addArg(version(builder));
    run.has_side_effects = true;

    std.debug.assert(run.argv.items.len == 9);

    return &run.step;
}

/// The version `build.zig.zon` says, which `--version` and `/api/health` answer.
fn version(builder: *std.Build) []const u8 {
    std.debug.assert(builder.build_root.path != null);

    const io = builder.graph.io;
    const gpa = builder.allocator;
    const limit: std.Io.Limit = .limited(1 << 16);
    const handle = builder.build_root.handle;
    const text = handle.readFileAllocOptions(io, "build.zig.zon", gpa, limit, .of(u8), 0) catch
        @panic("build.zig.zon is unreadable");
    const Manifest = struct { version: []const u8 };
    const options: std.zon.parse.Options = .{ .ignore_unknown_fields = true };
    const manifest = std.zon.parse.fromSliceAlloc(Manifest, gpa, text, null, options) catch
        @panic("build.zig.zon has no .version");

    std.debug.assert(manifest.version.len > 0);

    return manifest.version;
}
