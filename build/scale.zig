const std = @import("std");
const repository = @import("repository.zig");
const core = @import("core.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");

/// The plugins a shop is made of, as the scale check installs them.
pub const shop = [_][]const u8{
    "currencies",
    "orders",
    "products",
    "inventory",
    "payments",
    "bank_transfer",
    "cash_on_delivery",
    "shipping",
    "discounts",
    "customers",
    "checkout",
    "tax",
    "tax_pl",
};

/// Where the check and its budgets live, under the plugins' folder: the plugins it measures
/// are not Publr's, so neither are the numbers they are held to.
const script_sub = "checkout/e2e/budgets.sh";

/// Where the visitor's site is served: one port a run, so the two never meet.
const port_installed = "18471";
const port_compiled = "18472";

/// `zig build scale`: one big order taken through every step at 20, 200 and 2,000 lines
/// (or the sizes after `--`), each step's cost as Publr counts it held to its budget, twice:
/// the shop's plugins built as modules and installed in a Publr with none of them compiled
/// in, then all of them compiled into another. Both Publrs are built here for it, whatever
/// `publr.zon` compiles in. Declared only when the folder under `-Dplugins` (or the
/// preset's) holds the shop and the check.
pub fn add_step(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    built: sandboxed_plugins.SandboxedPlugins,
) void {
    std.debug.assert(from.plugins_dir.len > 0);
    std.debug.assert(built.names.len == built.files.len);

    const script = builder.pathJoin(&.{ from.plugins_dir, script_sub });

    repository.dir(builder).access(builder.graph.io, script, .{}) catch return;

    for (shop) |name| {
        if (!holds(built.names, name)) {
            return;
        }
    }

    const modules = builder.addWriteFiles();

    for (shop) |name| {
        _ = modules.addCopyFile(built.file_of(name), builder.fmt("{s}.wasm", .{name}));
    }

    const installed = add_run(builder, script, port_installed, add_publr(
        builder,
        target,
        optimize,
        from,
        "publr-scale-installed",
        &.{},
    ));
    const compiled = add_run(builder, script, port_compiled, add_publr(
        builder,
        target,
        optimize,
        from,
        "publr-scale-compiled",
        &shop,
    ));

    installed.addDirectoryArg(modules.getDirectory());
    installed.addPassthruArgs();
    compiled.addArg("-");
    compiled.addPassthruArgs();
    // One after the other: each run's figures are its own.
    compiled.step.dependOn(&installed.step);

    builder.step(
        "scale",
        "Hold each step of a big order to its budget, installed and compiled in",
    ).dependOn(&compiled.step);
}

/// The check run on `publr`; what follows the binary is the caller's to add.
fn add_run(
    builder: *std.Build,
    script: []const u8,
    port: []const u8,
    publr: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    std.debug.assert(script.len > 0);
    std.debug.assert(port.len > 0);

    const run = builder.addSystemCommand(&.{ "sh", repository.path(builder, script) });

    run.addArtifactArg(publr);
    run.setEnvironmentVariable("PORT", port);
    run.has_side_effects = true;

    return run;
}

/// Publr with, of the shop's plugins, `native` compiled in and no other.
fn add_publr(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    from: core.Sources,
    name: []const u8,
    native: []const []const u8,
) *std.Build.Step.Compile {
    std.debug.assert(name.len > 0);
    std.debug.assert(native.len <= shop.len);

    var chosen = from;

    chosen.native = .{
        .names = native,
    };

    return builder.addExecutable(.{
        .name = name,
        .root_module = core.add_entry(
            builder,
            "src/main.zig",
            core.add_module(builder, target, optimize, chosen),
        ),
    });
}

fn holds(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}
