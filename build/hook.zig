const std = @import("std");
const repository = @import("repository.zig");

/// The local hook's step (`scripts/verify_hook.zig`), always in `verify-full`: the script
/// reads `PUBLR_VERIFY_HOOK` as it runs and does nothing when it is unset.
pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    browser_step: *std.Build.Step,
) *std.Build.Step {
    std.debug.assert(builder.root.sub_path.len == 0);
    std.debug.assert(exe.kind == .exe);

    const script = builder.addExecutable(.{
        .name = "verify_hook",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/verify_hook.zig"),
            .target = builder.graph.host,
            .optimize = .debug,
        }),
    });
    const run = builder.addRunArtifact(script);

    run.addArtifactArg(exe);
    run.addArg(repository.path(builder, "zig-out/browser"));
    run.addArg(repository.path(builder, ".zig-cache/verify-hook"));
    run.setCwd(builder.path("."));
    run.has_side_effects = true;
    run.step.dependOn(browser_step);

    std.debug.assert(run.argv.items.len == 4);

    return &run.step;
}
