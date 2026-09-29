const std = @import("std");
const browser = @import("build/browser.zig");
const core = @import("build/core.zig");
const vendors = @import("build/vendors.zig");
const smoke = @import("build/smoke.zig");
const parity = @import("build/parity.zig");
const hook = @import("build/hook.zig");
const tidy = @import("build/tidy.zig");
const wasm = @import("build/wasm.zig");
const apps = @import("build/apps.zig");
const tests = @import("build/tests.zig");
const sandboxed_plugins = @import("build/sandboxed_plugins.zig");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
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

    const verify_step = builder.step("verify", "Run every gate check");

    verify_step.dependOn(checks.step);
    verify_step.dependOn(wasm.add_check(builder, from));
    verify_step.dependOn(&fmt_check.step);
    verify_step.dependOn(tidy.add_check(builder));
    verify_step.dependOn(smoke.add_check(
        builder,
        checks.fixture_exe,
        exe,
        fixture_plugins.file_of("greeter"),
    ));

    const parity_step = parity.add_check(builder, exe, library, fixture_plugins);

    verify_step.dependOn(parity_step);

    builder.step("run", "Run publr").dependOn(&run_cmd.step);
    builder.step("parity", "Run every printed example").dependOn(parity_step);

    const browser_step = browser.add_step(builder, from);

    verify_step.dependOn(browser_step);

    if (hook.add_check(builder, checks.fixture_exe, browser_step)) |local_hook| {
        verify_step.dependOn(local_hook);
    }

    sandboxed_plugins.add_step(builder, exe, from.sandboxed_plugins_dir);
    vendors.add_import_step(builder);
    vendors.add_cache_check_step(builder);
}
