const std = @import("std");
const browser = @import("browser.zig");
const core = @import("core.zig");
const smoke = @import("smoke.zig");
const parity = @import("parity.zig");
const hook = @import("hook.zig");
const tidy = @import("tidy.zig");
const wasm = @import("wasm.zig");
const tests = @import("tests.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");
const two_mode = @import("two_mode.zig");

pub const Parts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    exe: *std.Build.Step.Compile,
    checks: tests.Tests,
    fixture_plugins: sandboxed_plugins.SandboxedPlugins,
    fmt: *std.Build.Step,
};

/// `check`: formatting and tidy alone, in seconds, on every push.
/// `verify`: core's tests, formatting and tidy, one compile of the core, for every change.
/// `verify-full`: every gate check, each of which builds Publr its own way, before a commit.
/// CI runs the same checks one named step at a time, so the first failure ends the run.
pub fn add(builder: *std.Build, parts: Parts) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(parts.fixture_plugins.names.len > 0);

    const tidy_check = tidy.add_check(builder);
    const slim = builder.step("verify", "Core's tests, formatting and tidy: the quick check");
    const full = builder.step("verify-full", "Run every gate check");

    const check = builder.step("check", "Formatting and tidy, without building Publr");

    check.dependOn(parts.fmt);
    check.dependOn(tidy_check);
    slim.dependOn(parts.checks.core);
    slim.dependOn(parts.fmt);
    slim.dependOn(tidy_check);
    const wasm_step = wasm.add_check(builder, parts.from);

    full.dependOn(parts.checks.step);
    full.dependOn(wasm_step);
    builder.step("wasm", "Build Publr for the browser's WebAssembly").dependOn(wasm_step);
    full.dependOn(parts.fmt);
    full.dependOn(tidy_check);

    const both_ways = two_mode.add_check(
        builder,
        parts.target,
        parts.optimize,
        parts.from,
        parts.fixture_plugins,
    );

    const smoke_step = smoke.add_check(
        builder,
        parts.checks.fixture_exe,
        parts.exe,
        parts.fixture_plugins.file_of("greeter"),
        both_ways.native,
        parts.fixture_plugins.file_of("postcard"),
    );

    full.dependOn(both_ways.step);
    full.dependOn(smoke_step);
    builder.step("smoke", "Drive the built Publr through every entry point").dependOn(smoke_step);

    const parity_step = parity.add_check(builder, parts.checks, parts.fixture_plugins);
    const browser_step = browser.add_step(builder, parts.from);

    full.dependOn(parity_step);
    full.dependOn(@import("upgrade.zig").add(builder, parts.exe));
    full.dependOn(browser_step);
    builder.step("parity", "Run every printed example").dependOn(parity_step);

    if (hook.add_check(builder, parts.checks.fixture_exe, browser_step)) |local_hook| {
        full.dependOn(local_hook);
    }
}
