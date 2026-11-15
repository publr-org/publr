//! The embedded ECMAScript engine. Builds offline from pinned C sources.
const std = @import("std");

pub fn add(builder: *std.Build, module: *std.Build.Module) void {
    std.debug.assert(module.resolved_target != null);
    std.debug.assert(module.root_source_file != null);
    const target = module.resolved_target.?;
    const library = builder.addLibrary(.{
        .name = "publr_javascript",
        .linkage = .static,
        .root_module = builder.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    library.root_module.addCSourceFile(.{
        .file = builder.path("vendor/quickjs/quickjs-amalgam.c"),
        .flags = &.{"-D_GNU_SOURCE"},
    });
    library.root_module.addIncludePath(builder.path("vendor/quickjs"));
    library.root_module.addCSourceFile(.{
        .file = builder.path("src/template/javascript/values.c"),
    });
    module.linkLibrary(library);

    const api = builder.addTranslateC(.{
        .root_source_file = builder.path("src/template/javascript/values.h"),
        .target = target,
        .optimize = module.optimize orelse .debug,
    });

    api.addIncludePath(builder.path("vendor/quickjs"));
    module.addImport("javascript_api", api.createModule());
}

pub fn tests(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) void {
    std.debug.assert(builder.root.sub_path.len == 0);
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/template.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    add(builder, module);
    const parser = builder.dependency("pjsx", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("pjsx_syntax", builder.createModule(.{
        .root_source_file = parser.path("src/syntax.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const artifact = builder.addTest(.{
        .root_module = module,
    });
    const run = builder.addRunArtifact(artifact);
    builder.step(
        "test-templates",
        "Check native and JavaScript template rendering",
    ).dependOn(&run.step);
}
