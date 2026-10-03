const std = @import("std");
const core = @import("core.zig");
const scripts = @import("scripts.zig");
const parity = @import("parity.zig");
const native_plugins = @import("native_plugins.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");

/// Core's own tests and smoke run against these apps; an installed Publr carries none.
pub const fixture_apps_dir = "fixtures/apps";

pub const Tests = struct {
    step: *std.Build.Step,
    /// Core's own tests alone: what the slim `verify` runs.
    core: *std.Build.Step,
    /// Publr with the fixture apps compiled in, for the smoke and parity.
    fixture_exe: *std.Build.Step.Compile,
    /// Its library, which parity lists the operations of.
    fixture: *std.Build.Module,
};

/// `test` (core against the fixture apps, the scripts, the printed examples and the
/// plugins), `test-native-plugins` and `test-exe`.
pub fn add(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    library: *std.Build.Module,
    fixture_plugins: sandboxed_plugins.SandboxedPlugins,
) Tests {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    var fixture_from = core.with_apps(from, fixture_apps_dir);

    // Smoke drives this binary as one built without the compiler, and the tests need none.
    fixture_from.compiler = false;
    // Whatever the project compiles in (`plugins/`, `publr.zon`) never reaches the checks:
    // core is tested with none, the test plugins being installed where a check wants them.
    fixture_from.plugins_dir = sandboxed_plugins.fixture_dir;
    fixture_from.native = .{ .names = &.{} };

    const fixture = core.add_module(builder, target, optimize, fixture_from);
    const fixture_exe = builder.addExecutable(.{
        .name = "publr-fixture",
        .root_module = core.add_entry(builder, "src/main.zig", fixture),
    });
    const tests = builder.addTest(.{ .root_module = fixture });

    for (fixture_plugins.names, fixture_plugins.files) |name, file| {
        const import_name = builder.fmt("sandboxed_plugin_{s}", .{name});

        fixture.addAnonymousImport(import_name, .{ .root_source_file = file });
    }

    const test_step = builder.step("test", "Run all tests");
    const test_exe_step = builder.step("test-exe", "Build the test binary for a debugger");
    const plugins_step = builder.step("test-native-plugins", "Run the native plugins' tests");

    test_exe_step.dependOn(&builder.addInstallArtifact(tests, .{
        .dest_sub_path = "publr-tests",
    }).step);
    const core_run = builder.addRunArtifact(tests);

    test_step.dependOn(&core_run.step);
    test_step.dependOn(plugins_step);
    scripts.add_tests(builder, test_step);
    native_plugins.add_tests(builder, library, plugins_step);
    parity.add_tests(builder, fixture, test_step, fixture_plugins);

    return .{
        .step = test_step,
        .core = &core_run.step,
        .fixture_exe = fixture_exe,
        .fixture = fixture,
    };
}
