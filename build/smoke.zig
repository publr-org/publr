const std = @import("std");

/// The smoke drives `exe` (with apps to serve) through every entry point, and `bare` (with
/// none) through what a project without apps answers.
pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    bare: *std.Build.Step.Compile,
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
    run.has_side_effects = true;

    std.debug.assert(run.argv.items.len == 4);

    return &run.step;
}
