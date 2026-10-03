const std = @import("std");
const verify = @import("build/verify.zig");
const core = @import("build/core.zig");
const vendors = @import("build/vendors.zig");
const apps = @import("build/apps.zig");
const tests = @import("build/tests.zig");
const sandboxed_plugins = @import("build/sandboxed_plugins.zig");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    @import("build/javascript.zig").tests(builder, target, optimize);
    const from = core.sources(builder);

    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(builder.args == null or builder.args.?.len > 0);

    const library = core.add_module(builder, target, optimize, from);
    const exe = builder.addExecutable(.{
        .name = "publr",
        .root_module = core.add_entry(builder, "src/main.zig", library),
    });
    const run_cmd = builder.addRunArtifact(exe);
    const fixture_plugins = sandboxed_plugins.add(builder, exe, sandboxed_plugins.fixture_dir);
    const checks = tests.add(builder, target, optimize, from, library, fixture_plugins);
    const fmt_check = builder.addFmt(.{
        .paths = &.{ "build.zig", "build", "src", "scripts" },
        .check = true,
    });

    // Exported for the workspace's benchmarks, which depend on this repository by path.
    builder.modules.put(builder.graph.arena, "publr", library) catch @panic("OOM");
    builder.installArtifact(exe);
    apps.add_check(builder, exe, target);

    run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| {
        run_cmd.addArgs(args);
    }

    builder.step("run", "Run publr").dependOn(&run_cmd.step);
    verify.add(builder, .{
        .target = target,
        .optimize = optimize,
        .from = from,
        .exe = exe,
        .checks = checks,
        .fixture_plugins = fixture_plugins,
        .fmt = &fmt_check.step,
    });

    sandboxed_plugins.add_step(builder, exe, from.plugins_dir, from.native);
    vendors.add_import_step(builder);
    vendors.add_cache_check_step(builder);
}
