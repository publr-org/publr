const std = @import("std");

const entries = [_][]const u8{
    "scripts/tidy.zig",
    "scripts/vendor.zig",
    "scripts/smoke.zig",
    "scripts/upgrade.zig",
};

pub fn add_tests(builder: *std.Build, test_step: *std.Build.Step) void {
    std.debug.assert(entries.len == 4);
    std.debug.assert(builder.build_root.path != null);

    for (entries) |entry| {
        const tests = builder.addTest(.{
            .root_module = builder.createModule(.{
                .root_source_file = builder.path(entry),
                .target = builder.graph.host,
                .optimize = .Debug,
            }),
        });

        test_step.dependOn(&builder.addRunArtifact(tests).step);
    }
}
