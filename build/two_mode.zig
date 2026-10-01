const std = @import("std");
const core = @import("core.zig");
const tests = @import("tests.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");

/// The fixture plugins the check runs both ways; `greeter_next` is greeter's next version,
/// the same plugin, so it is never compiled in beside it.
pub const plugins = [_][]const u8{ "greeter", "farewell", "sampler" };
/// Compiled into the native build only: what the smoke drives there, never compared.
const native_only = [_][]const u8{"recorder"};

/// `two-mode`: every fixture plugin installed in the sandbox of one Publr and compiled
/// into another, both built from the same sources otherwise, the same calls made of both,
/// the answers compared.
pub fn add_check(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    fixture_plugins: sandboxed_plugins.SandboxedPlugins,
) Check {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(fixture_plugins.names.len == fixture_plugins.files.len);

    const sandboxed = add_publr(builder, target, optimize, from, "publr-sandboxed", &.{});
    const native = add_publr(builder, target, optimize, from, "publr-native", &(plugins ++
        native_only));
    const runner = builder.addExecutable(.{
        .name = "two-mode",
        .root_module = core.add_entry(builder, "scripts/two_mode.zig", native.library),
    });
    const run = builder.addRunArtifact(runner);

    run.addArtifactArg(sandboxed.exe);
    run.addArtifactArg(native.exe);
    run.addArg(builder.pathFromRoot(".zig-cache/two-mode"));

    for (plugins) |name| {
        run.addFileArg(fixture_plugins.file_of(name));
    }

    run.has_side_effects = true;

    const step = builder.step("two-mode", "Run every fixture plugin sandboxed and compiled in");

    step.dependOn(&run.step);

    return .{ .step = step, .native = native.exe };
}

/// The check's step, and the Publr with the fixture plugins compiled in, which the smoke
/// drives through the admin.
pub const Check = struct { step: *std.Build.Step, native: *std.Build.Step.Compile };

const Built = struct { library: *std.Build.Module, exe: *std.Build.Step.Compile };

/// Publr with the fixture apps and, of the fixture plugins, `native` compiled in.
fn add_publr(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    name: []const u8,
    native: []const []const u8,
) Built {
    std.debug.assert(name.len > 0);
    std.debug.assert(native.len <= plugins.len + native_only.len);

    var chosen = core.with_apps(from, tests.fixture_apps_dir);

    chosen.plugins_dir = sandboxed_plugins.fixture_dir;
    chosen.native = .{ .names = native };
    chosen.compiler = false;

    const library = core.add_module(builder, target, optimize, chosen);
    const exe = builder.addExecutable(.{
        .name = name,
        .root_module = core.add_entry(builder, "src/main.zig", library),
    });

    return .{ .library = library, .exe = exe };
}
