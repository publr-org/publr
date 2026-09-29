const std = @import("std");
const core = @import("core.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");

pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    library: *std.Build.Module,
    fixture_plugins: sandboxed_plugins.SandboxedPlugins,
) *std.Build.Step {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    const parity = builder.addExecutable(.{
        .name = "parity",
        .root_module = entry(builder, library, fixture_plugins),
    });

    const run = builder.addRunArtifact(parity);

    run.addArtifactArg(exe);
    run.addArg(builder.pathFromRoot(".zig-cache/parity"));
    run.has_side_effects = true;

    std.debug.assert(run.argv.items.len == 3);

    return &run.step;
}

pub fn add_tests(
    builder: *std.Build,
    library: *std.Build.Module,
    test_step: *std.Build.Step,
    fixture_plugins: sandboxed_plugins.SandboxedPlugins,
) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    const tests = builder.addTest(.{ .root_module = entry(builder, library, fixture_plugins) });

    test_step.dependOn(&builder.addRunArtifact(tests).step);
}

/// The parity tool, with the fixture plugins its world installs.
fn entry(
    builder: *std.Build,
    library: *std.Build.Module,
    fixture_plugins: sandboxed_plugins.SandboxedPlugins,
) *std.Build.Module {
    std.debug.assert(fixture_plugins.names.len == fixture_plugins.files.len);

    const module = core.add_entry(builder, "scripts/parity.zig", library);

    for (fixture_plugins.names, fixture_plugins.files) |name, file| {
        module.addAnonymousImport(builder.fmt("sandboxed_plugin_{s}", .{name}), .{
            .root_source_file = file,
        });
    }

    return module;
}
