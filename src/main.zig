const std = @import("std");
const builtin = @import("builtin");
const publr = @import("publr");

const server = publr.server;
const cli = publr.cli;
const registry = publr.registry;
const report = publr.report;
const sdk = publr.sdk;
const version = publr.version;

const db_path_default = "data/publr.db";
const args_max: u32 = 128;

pub fn main(init: std.process.Init) u8 {
    std.debug.assert(args_max == cli.args_max);
    return run(init) catch |err| {
        report.err("publr: {s}", .{@errorName(err)});
        return switch (err) {
            error.TooManyArguments, error.InvalidArguments => 2,
            else => 1,
        };
    };
}

fn run(init: std.process.Init) !u8 {
    var stdout_buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch |err| std.debug.print("stdout: {t}\n", .{err});

    var args_storage: [args_max][]const u8 = undefined;
    const args = try collect_args(init, &args_storage);

    std.debug.assert(args.len <= args_max);
    std.debug.assert(db_path_default.len > 0);

    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) {
        try out.print("publr {s}\n", .{version});
        return 0;
    }

    var db_path: [:0]const u8 = db_path_default;
    var rest = args;

    if (builtin.os.tag != .wasi) {
        const command = try before_command(init, rest, db_path);

        rest = command.args;
        db_path = command.db_path;
    }

    if (rest.len >= 1 and std.mem.eql(u8, rest[0], "--db")) {
        if (rest.len < 2 or rest[1].len == 0) return error.InvalidArguments;
        db_path = try init.arena.allocator().dupeZ(u8, rest[1]);
        rest = rest[2..];
    }

    // Everything goes to the Publr named, its help and its plugins' commands too; signing in
    // and out of it are this machine's.
    if (try site_of(init, &rest)) |address| {
        if (rest.len > 0 and !is_account(rest[0])) {
            return try publr.remote.forward(init, address, rest, out);
        }
    }

    if (try tool(init, out, db_path, rest)) |code| {
        return code;
    }

    const help = rest.len == 1 and
        (std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h"));

    if (rest.len == 0 or help) {
        try cli.CLI(registry.SDK).print_help(out);
        return if (rest.len == 0) 2 else 0;
    }

    const code = run_command(init, db_path, rest, out) catch |err| {
        report.err("publr: {s}", .{@errorName(err)});
        return 1;
    };

    // A new project has the compiler for its plugins ready, as it has its database.
    if (code == 0 and is_init(rest) and builtin.os.tag != .wasi) {
        publr.toolchain.prepare(init);
    }

    return code;
}

fn has_flag(args: []const []const u8, flag: []const u8) bool {
    std.debug.assert(flag.len > 0);
    std.debug.assert(args.len <= args_max);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) {
            return true;
        }
    }

    return false;
}

/// `login`, `logout` or `whoami`: about this machine's devices, never sent elsewhere.
fn is_account(command: []const u8) bool {
    std.debug.assert(command.len <= cli.value_len_max);

    return std.mem.eql(u8, command, "login") or std.mem.eql(u8, command, "logout") or
        std.mem.eql(u8, command, "whoami");
}

/// The Publr elsewhere a command goes to: `--site <address>` (taken off the words), else
/// `PUBLR_SITE`; null to run it here.
fn site_of(init: std.process.Init, rest: *[]const []const u8) !?[]const u8 {
    const named = rest.len >= 2 and std.mem.eql(u8, rest.*[0], "--site");
    const site = if (named) rest.*[1] else init.environ_map.get("PUBLR_SITE") orelse return null;

    if (named) {
        rest.* = rest.*[2..];
    }

    if (site.len == 0 or builtin.os.tag == .wasi) {
        return error.InvalidArguments;
    }

    std.debug.assert(site.len > 0);

    return site;
}

/// The command as the plugins' pre-command hooks leave it.
fn before_command(
    init: std.process.Init,
    args: []const []const u8,
    db_path: [:0]const u8,
) !publr.plugin_hooks.Command {
    std.debug.assert(db_path.len > 0);

    var command: publr.plugin_hooks.Command = .{
        .io = init.io,
        .arena = init.arena.allocator(),
        .args = args,
        .db_path = db_path,
    };

    try publr.plugin_hooks.before_command(&command);

    std.debug.assert(command.args.len <= args.len);

    return command;
}

/// A command, run by the server when one runs for this database (`server/operator.zig`),
/// else here.
fn run_command(
    init: std.process.Init,
    db_path: [:0]const u8,
    args: []const []const u8,
    out: *std.Io.Writer,
) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(db_path.len > 0);

    if (builtin.os.tag == .wasi) {
        var application: server.Server = undefined;
        try application.init(init, db_path);
        defer application.deinit();

        const arena_bytes = try init.gpa.alloc(u8, server.request_arena_bytes);
        defer init.gpa.free(arena_bytes);

        var fixed = std.heap.FixedBufferAllocator.init(arena_bytes);

        return cli.CLI(registry.SDK).run(.{
            .db = &application.connection,
            .io = init.io,
            .arena = fixed.allocator(),
            .auth = &application.auth,
            .now_ms = sdk.context.wall_clock_ms(init.io),
            .password_env = init.environ_map.get("PUBLR_PASSWORD"),
            .sandboxed_plugins = application.sandboxed(),
            .files = application.files_of(),
        }, args, out);
    }

    var commands: publr.operator.Commands = .{ .init = init, .db_path = db_path };
    defer commands.deinit();

    return commands.run(args, out);
}

/// `init`, or the operation it stands for, `project init`, after any global flags.
fn is_init(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len <= args_max);

    var index: u32 = 0;

    while (index < args.len and std.mem.startsWith(u8, args[index], "--")) {
        index += if (std.mem.eql(u8, args[index], "--as")) 2 else 1;
    }

    const command = args[@min(index, args.len)..];
    const operation = command.len > 1 and std.mem.eql(u8, command[0], "project") and
        std.mem.eql(u8, command[1], "init");

    return (command.len > 0 and std.mem.eql(u8, command[0], "init")) or operation;
}

fn collect_args(init: std.process.Init, storage: *[args_max][]const u8) ![]const []const u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());
    var count: u32 = 0;

    _ = iterator.next();

    while (iterator.next()) |arg| : (count += 1) {
        if (count == args_max) {
            return error.TooManyArguments;
        }
        storage[count] = arg;
    }

    std.debug.assert(count <= args_max);
    std.debug.assert(storage.len == args_max);

    return storage[0..count];
}

/// The commands that are not operations: `serve`, `build`, `zig`, `login`, `logout`, `whoami`,
/// `skill`, `new` and `check-apps`. Null for anything else, which the CLI answers.
fn tool(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    rest: []const []const u8,
) !?u8 {
    std.debug.assert(db_path.len > 0);

    if (rest.len == 0) {
        return null;
    }

    const serve = std.mem.eql(u8, rest[0], "serve");
    const build = std.mem.eql(u8, rest[0], "build");
    const zig = std.mem.eql(u8, rest[0], "zig");
    const agents = rest.len == 1 and std.mem.eql(u8, rest[0], "agents");
    const skill = std.mem.eql(u8, rest[0], "skill");
    const new_site = std.mem.eql(u8, rest[0], "new");
    // As the local operator; `apps.load` is the operation a device or `--as` reaches.
    const apps_load = rest.len > 1 and std.mem.eql(u8, rest[0], "apps") and
        std.mem.eql(u8, rest[1], "load") and !has_flag(rest, "--help");
    // With `--files`, the sources come in the command: the operation, not the build here.
    const plugin_build = rest.len > 1 and std.mem.eql(u8, rest[0], "plugin") and
        std.mem.eql(u8, rest[1], "build") and !has_flag(rest, "--files") and
        !has_flag(rest, "--help");
    const login = is_account(rest[0]);

    // In the browser there is no server, no build and no compiler: the modules are `void`
    // there.
    if (builtin.os.tag == .wasi) {
        if (serve or build or zig or plugin_build or agents or apps_load or login or skill or
            new_site)
        {
            return error.Unsupported;
        }
    } else {
        if (zig) {
            return try publr.toolchain.run(init, rest[1..]);
        }

        if (agents) {
            return try publr.agents.run(init, out, db_path);
        }

        if (login) {
            return try publr.login.run(init, out, rest);
        }

        if (skill) {
            return try publr.skill.run(init, out, rest[1..]);
        }

        if (new_site) {
            return try publr.new_site.run(init, out, rest[1..]);
        }

        if (apps_load) {
            return try publr.apps_load.run(init, db_path, rest[2..]);
        }

        if (plugin_build) {
            return try publr.plugin_build.run(init, db_path, rest[2..]);
        }

        if (serve) {
            return try publr.serve.run(init, db_path, rest[1..]);
        }

        if (build) {
            return try publr.build.run(init, db_path, rest[1..]);
        }
    }

    if (rest.len == 1 and std.mem.eql(u8, rest[0], "check-apps")) {
        return try check_apps(init, out);
    }

    return null;
}

/// `publr check-apps`: 0 when every compiled-in app compiles, else 1 and the reason, the
/// way `serve` would report it at start.
fn check_apps(init: std.process.Init, out: *std.Io.Writer) !u8 {
    std.debug.assert(args_max > 0);

    const problem = try publr.apps.check_apps(init.gpa, init.arena.allocator());

    if (problem) |reason| {
        report.err("{s}", .{reason});
        return 1;
    }

    try out.print("{d} apps: compile\n", .{publr.apps.spec.all.len});
    return 0;
}
