const std = @import("std");

/// `deprecations` (`-- --before <day>`): each operation on its way out, the day it goes and
/// where it is declared, asked of the publr this build makes. `surface -- <words>`: the
/// script itself (`scripts/surface.zig`), for the Release workflow: `write`, `check`, `prompt`.
pub fn add(builder: *std.Build, exe: *std.Build.Step.Compile) void {
    std.debug.assert(builder.root.sub_path.len == 0);

    const script = builder.addExecutable(.{
        .name = "surface",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/surface.zig"),
            .target = builder.graph.host,
            .optimize = .debug,
        }),
    });

    const listed = builder.addRunArtifact(script);

    listed.addArg("list");
    listed.addArtifactArg(exe);
    listed.addArg("src");
    listed.addPassthruArgs();
    listed.has_side_effects = true;
    builder.step("deprecations", "List what Publr is removing, by day, and where it is declared")
        .dependOn(&listed.step);

    const raw = builder.addRunArtifact(script);

    raw.addPassthruArgs();
    raw.has_side_effects = true;
    builder.step("surface", "Run scripts/surface.zig with the words after --").dependOn(&raw.step);

    std.debug.assert(listed.argv.items.len >= 3);
}
