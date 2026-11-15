const std = @import("std");
const repository = @import("repository.zig");

const variable = "PUBLR_VERIFY_HOOK";

pub fn add_check(
    builder: *std.Build,
    exe: *std.Build.Step.Compile,
    browser_step: *std.Build.Step,
) ?*std.Build.Step {
    std.debug.assert(builder.root.sub_path.len == 0);
    std.debug.assert(variable.len > 0);

    const hook = builder.graph.environ_map.get(variable) orelse return null;

    if (hook.len == 0) {
        return null;
    }

    const run = builder.addSystemCommand(&.{hook});

    run.addArtifactArg(exe);
    run.addArg(repository.path(builder, "zig-out/browser"));
    run.addArg(repository.path(builder, ".zig-cache/verify-hook"));
    run.setCwd(builder.path("."));
    run.has_side_effects = true;
    run.step.dependOn(browser_step);

    std.debug.assert(run.argv.items.len == 4);

    return &run.step;
}
