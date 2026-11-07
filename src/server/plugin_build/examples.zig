//! `plugin build` runs every `Example:` of the plugin's operations as a test, against an
//! empty site with the plugin: a database of its own beside the build, the module added and
//! enabled, each example called by an administrator. It passes when the answer has the shape
//! its `out:` shows, or when the call is refused for what an empty site lacks (nothing found,
//! credentials it never issued, the plugin's own failure, someone else's, a service down); a
//! refusal of the example's own input fails the build. The plugins it names in `depends_on`
//! and `compatible_with` go on that site first, from the built plugins it has (`--with`, the
//! site's installed ones); when one it depends on is not among them, its examples are left
//! to the site, and the build says so.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const report = @import("../../lib/report.zig");
const operator = @import("../operator.zig");
const shape = @import("../../sdk/shape.zig");
const Manifest = @import("../../model/sandboxed_plugin.zig").Manifest;

/// A built plugin the examples' site may need: its name and its module's path.
pub const Module = struct {
    name: []const u8,
    path: []const u8,
};

/// Whether every example passed; each that did not is reported. `modules` are the built
/// plugins the plugin's own may need beside it.
pub fn run(
    init: std.process.Init,
    built: []const u8,
    manifest_json: []const u8,
    modules: []const Module,
) !bool {
    std.debug.assert(built.len > 0);
    std.debug.assert(manifest_json.len > 0);

    const arena = init.arena.allocator();
    const manifest = try std.json.parseFromSliceLeaky(Manifest, arena, manifest_json, .{
        .ignore_unknown_fields = true,
    });
    const dir = try std.fmt.allocPrint(arena, "{s}.examples", .{built});
    const db_path = try std.fs.path.joinZ(arena, &.{ dir, "publr.db" });

    try std.Io.Dir.cwd().deleteTree(init.io, dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, dir) catch |err| {
        report.err("{s}: its examples' site stays at {s}: {t}", .{ manifest.name, dir, err });
    };

    var commands: operator.Commands = .{
        .init = init,
        .db_path = db_path,
    };
    defer commands.deinit();

    if (absent(manifest.depends_on, modules)) |owner| {
        report.info("{s}: its examples are left to the site: {s} is not here to run them " ++
            "beside; pass --with <{s}.wasm> to run them now\n", .{ manifest.name, owner, owner });
        return true;
    }

    const needed = [_][]const []const u8{ manifest.depends_on, manifest.compatible_with };

    for (needed) |names| {
        for (names) |name| {
            const module = found(name, modules) orelse continue;

            if (!try added(&commands, module.path, module.name)) {
                report.err("{s}: its examples did not run: {s} did not install beside it", .{
                    manifest.name,
                    name,
                });
                return false;
            }
        }
    }

    if (!try added(&commands, built, manifest.name)) {
        report.err("{s}: its examples did not run: it did not install", .{manifest.name});
        return false;
    }

    const application = commands.local.?;
    var failed: u32 = 0;

    for (manifest.operations) |declared| {
        if (declared.example.len == 0) {
            continue;
        }

        var ctx = sdk.Ctx.init(
            &application.connection,
            init.io,
            arena,
            &application.auth,
            .{
                .user = .{
                    .id = "u_example",
                    .roles = &.{"admin"},
                },
            },
            .{
                .now_ms = sdk.context.wall_clock_ms(init.io),
            },
        );

        ctx.sandboxed_plugins = application.sandboxed();
        ctx.plugin_states = &application.plugin_states;
        ctx.files = application.files_of();

        if (!try passes(&ctx, declared.name, declared.example, declared.example_out)) {
            failed += 1;
        }
    }

    return failed == 0;
}

/// The plugin `path` added to the examples' site and enabled.
fn added(commands: *operator.Commands, path: []const u8, name: []const u8) !bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(name.len > 0);

    var discarded: std.Io.Writer.Allocating = .init(commands.init.arena.allocator());
    const add = [_][]const u8{ "--as-admin", "plugin", "add", "--file", path };
    const enable = [_][]const u8{ "--as-admin", "plugin", "enable", "--names", name };

    return try commands.run(&add, &discarded.writer) == 0 and
        try commands.run(&enable, &discarded.writer) == 0;
}

/// The first plugin of `depends_on` that is neither built in nor among `modules`.
fn absent(depends_on: []const []const u8, modules: []const Module) ?[]const u8 {
    std.debug.assert(depends_on.len < 1 << 10);

    for (depends_on) |name| {
        if (found(name, modules) == null and !built_in(name)) {
            return name;
        }
    }

    return null;
}

/// Whether this binary has `name` built in: on every site, the examples' own included.
fn built_in(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return true;
        }
    }

    return false;
}

fn found(name: []const u8, modules: []const Module) ?Module {
    std.debug.assert(name.len > 0);

    for (modules) |module| {
        if (std.mem.eql(u8, module.name, name)) {
            return module;
        }
    }

    return null;
}

fn passes(ctx: *sdk.Ctx, name: []const u8, example: []const u8, documented: []const u8) !bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(example.len > 0);

    const answer = registry.SDK.call_json(ctx, name, example) catch |err| {
        const lacking = switch (err) {
            error.NotFound, error.Denied, error.BadCredentials, error.Conflict => true,
            error.Unavailable, error.Failed => true,
            error.Invalid => ctx.problems.len == 0,
            else => false,
        };

        if (!lacking) {
            report.err("example of {s}: refused, {t}", .{ name, err });
        }

        return lacking;
    };
    const wanted = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, documented, .{});
    const got = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, answer, .{});

    shape.same_json(wanted, got) catch {
        report.err("example of {s}: answered {s}, not the shape of its `out:`", .{ name, answer });
        return false;
    };

    return true;
}
