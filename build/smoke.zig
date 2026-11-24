const std = @import("std");
const repository = @import("repository.zig");

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
    std.debug.assert(builder.root.sub_path.len == 0);

    // The answers of `/api/<operation>`, read as every client of the API reads them.
    const api = builder.dependency("publr_api", .{
        .target = builder.graph.host,
    });
    const smoke = builder.addExecutable(.{
        .name = "smoke",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/smoke.zig"),
            .target = builder.graph.host,
            .optimize = .debug,
            .imports = &.{.{
                .name = "publr_api",
                .module = api.module("publr_api"),
            }},
        }),
    });

    const run = builder.addRunArtifact(smoke);

    run.addArtifactArg(exe);
    run.addArtifactArg(bare);
    run.addArg(repository.path(builder, ".zig-cache/smoke"));
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
pub fn version(builder: *std.Build) []const u8 {
    std.debug.assert(builder.root.sub_path.len == 0);

    const io = builder.graph.io;
    const gpa = builder.allocator;
    const limit: std.Io.Limit = .limited(1 << 16);
    const handle = repository.dir(builder);
    const text = handle.readFileAllocOptions(io, "build.zig.zon", gpa, limit, .of(u8), 0) catch
        @panic("build.zig.zon is unreadable");
    const Manifest = struct {
        version: []const u8,
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const options: std.zon.parse.Options = .{
        .gpa = gpa,
        .arena = gpa,
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    };
    const manifest = std.zon.parse.fromSlice(Manifest, options) catch
        @panic("build.zig.zon has no .version");

    std.debug.assert(manifest.version.len > 0);

    return manifest.version;
}
