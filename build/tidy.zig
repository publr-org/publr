const std = @import("std");

pub fn add_check(builder: *std.Build) *std.Build.Step {
    std.debug.assert(builder.root.sub_path.len == 0);

    const tidy = builder.addExecutable(.{
        .name = "tidy",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/tidy.zig"),
            .target = builder.graph.host,
            .optimize = .debug,
        }),
    });

    const run = builder.addRunArtifact(tidy);

    run.addArgs(&.{ "build.zig", "README.md", "build", "src", "scripts", "docs" });
    run.setCwd(builder.path("."));
    run.has_side_effects = true;

    std.debug.assert(run.argv.items.len > 1);

    return &run.step;
}
