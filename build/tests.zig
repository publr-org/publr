const std = @import("std");
const core = @import("core.zig");
const scripts = @import("scripts.zig");
const parity = @import("parity.zig");
const plugins = @import("plugins.zig");

/// Core's own tests and smoke run against these apps; an installed Publr carries none.
pub const fixture_apps_dir = "fixtures/apps";

pub const Tests = struct {
    step: *std.Build.Step,
    /// Publr with the fixture apps compiled in, for the smoke.
    fixture_exe: *std.Build.Step.Compile,
};

/// `test` (core against the fixture apps, the scripts, the printed examples and the
/// plugins), `test-plugins` and `test-exe`.
pub fn add(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    library: *std.Build.Module,
) Tests {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    const fixture_from = core.with_apps(from, fixture_apps_dir);
    const fixture = core.add_module(builder, target, optimize, fixture_from);
    const fixture_exe = builder.addExecutable(.{
        .name = "publr-fixture",
        .root_module = core.add_entry(builder, "src/main.zig", fixture),
    });
    const tests = builder.addTest(.{ .root_module = fixture });
    const test_step = builder.step("test", "Run all tests");
    const test_exe_step = builder.step("test-exe", "Build the test binary for a debugger");
    const plugins_step = builder.step("test-plugins", "Run the compiled-in plugins' tests");

    test_exe_step.dependOn(&builder.addInstallArtifact(tests, .{
        .dest_sub_path = "publr-tests",
    }).step);
    test_step.dependOn(&builder.addRunArtifact(tests).step);
    test_step.dependOn(plugins_step);
    scripts.add_tests(builder, test_step);
    plugins.add_tests(builder, library, from.plugins_dir, plugins_step);
    parity.add_tests(builder, library, test_step);

    return .{ .step = test_step, .fixture_exe = fixture_exe };
}
