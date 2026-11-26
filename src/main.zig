const std = @import("std");
const builtin = @import("builtin");
const core = @import("p");

const server = core.server;
const cli = core.cli;
const registry = core.registry;
const report = core.report;
const sdk = core.sdk;
const version = core.version;

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
        db_path = try init.arena.allocator().dupeSentinel(u8, rest[1], 0);
        rest = rest[2..];
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

    return run_command(init, db_path, rest, out) catch |err| {
        report.err("publr: {s}", .{@errorName(err)});
        return 1;
    };
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

/// The command as the plugins' pre-command hooks leave it.
fn before_command(
    init: std.process.Init,
    args: []const []const u8,
    db_path: [:0]const u8,
) !core.plugin_hooks.Command {
    std.debug.assert(db_path.len > 0);

    var command: core.plugin_hooks.Command = .{
        .io = init.io,
        .arena = init.arena.allocator(),
        .args = args,
        .db_path = db_path,
    };

    try core.plugin_hooks.before_command(&command);

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

        return cli.CLI(registry.SDK).run(
            &application.connection,
            init.io,
            fixed.allocator(),
            &application.auth,
            args,
            out,
            .{
                .now_ms = sdk.context.wall_clock_ms(init.io),
                .password_env = init.environ_map.get("PUBLR_PASSWORD"),
                .sandboxed_plugins = application.sandboxed(),
                .files = application.files_of(),
                .translations = application.languages.view(),
            },
        );
    }

    var commands: core.operator.Commands = .{
        .init = init,
        .db_path = db_path,
    };
    defer commands.deinit();

    return commands.run(args, out);
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

/// The commands that are not operations: `serve`, `build`, `agents`, `agent`, `seed`,
/// `apps load`, `plugin check`, `plugin sdk`, `plugin prepare`, `site`, `db`, `backups`,
/// `restore`, the processes `serve` starts beside it, `check-apps` and `check-plugins`. Null
/// for anything else, which the CLI answers.
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
    const agents = rest.len == 1 and std.mem.eql(u8, rest[0], "agents");
    const agent = std.mem.eql(u8, rest[0], "agent");
    // As the local operator; `apps.load` is the operation a device or `--as` reaches.
    const apps_load = rest.len > 1 and std.mem.eql(u8, rest[0], "apps") and
        std.mem.eql(u8, rest[1], "load") and !has_flag(rest, "--help");
    const plugin_check = rest.len > 1 and std.mem.eql(u8, rest[0], "plugin") and
        std.mem.eql(u8, rest[1], "check") and !has_flag(rest, "--help");
    const plugin_sdk = rest.len > 1 and std.mem.eql(u8, rest[0], "plugin") and
        std.mem.eql(u8, rest[1], "sdk") and !has_flag(rest, "--help");
    const plugin_prepare = rest.len > 1 and std.mem.eql(u8, rest[0], "plugin") and
        std.mem.eql(u8, rest[1], "prepare") and !has_flag(rest, "--help");

    // In the browser there is no server, no build and no SDK to write out: the modules are
    // `void` there.
    if (builtin.os.tag == .wasi) {
        const plugins = plugin_check or plugin_sdk or plugin_prepare;

        if (serve or build or plugins or agents or agent or apps_load) {
            return error.Unsupported;
        }
    } else {
        if (agents) {
            return try core.agents.run(init, out, db_path);
        }

        if (agent) {
            return try core.agent.run(init, db_path, rest[1..]);
        }

        if (seed_at(rest)) |at| {
            const here: Here = .{
                .init = init,
                .db_path = db_path,
            };

            return try core.seed.run(init, out, rest[at + 1 ..], .{
                .runner = here.runner(),
                .caller = rest[0..at],
            });
        }

        if (apps_load) {
            return try core.apps_load.run(init, db_path, rest[2..]);
        }

        if (plugin_check and has_flag(rest, "--file")) {
            return try core.plugin_build.check_file(init, db_path, rest[2..]);
        }

        if (plugin_check) {
            return try core.plugin_check.run(init, rest[2..]);
        }

        if (plugin_sdk) {
            return try core.plugin_sdk.write_sdk(init, out, rest[2..]);
        }

        if (plugin_prepare) {
            return try core.plugin_build.prepare(init, out, db_path, rest[2..]);
        }

        if (serve) {
            return try core.serve.run(init, db_path, rest[1..]);
        }

        if (std.mem.eql(u8, rest[0], core.clone_pack.command)) {
            return try core.clone_pack.run(init, out, db_path, rest[1..]);
        }

        if (std.mem.eql(u8, rest[0], "queue-run")) {
            return try core.queue_worker.run(init, db_path, rest[1..]);
        }

        if (std.mem.eql(u8, rest[0], "update-run")) {
            return try core.update.run(init, db_path, rest[1..]);
        }

        if (core.bundle.handles(rest) and !has_flag(rest, "--help")) {
            return try core.bundle.run(init, out, db_path, rest);
        }

        if (core.database.handles(rest) and !has_flag(rest, "--help")) {
            return try core.database.run(init, out, db_path, rest);
        }

        if (build) {
            return try core.build.run(init, db_path, rest[1..]);
        }
    }

    if (rest.len == 1 and std.mem.eql(u8, rest[0], "check-apps")) {
        return try check_apps(init, out);
    }

    if (rest.len == 1 and std.mem.eql(u8, rest[0], "check-plugins")) {
        return check_plugins();
    }

    return null;
}

/// `publr check-plugins`: a note for each compiled-in plugin's remote another compiled-in
/// plugin switches off, and why; always 0, as the build it runs after passes.
fn check_plugins() u8 {
    const off = core.registry.remotes_off;

    std.debug.assert(off.len <= 64 * 64);

    for (off) |remote| {
        report.info("note: {s}: {s} is switched off: {s}\n", .{
            remote.plugin,
            remote.name,
            remote.why,
        });
    }

    return 0;
}

/// `publr check-apps`: 0 when every compiled-in app compiles, else 1 and the reason, the
/// way `serve` would report it at start.
fn check_apps(init: std.process.Init, out: *std.Io.Writer) !u8 {
    std.debug.assert(args_max > 0);

    const problem = try core.apps.check_apps(init.gpa, init.arena.allocator(), init.io);

    if (problem) |reason| {
        report.err("{s}", .{reason});
        return 1;
    }

    try out.print("{d} apps: compile\n", .{core.apps.spec.all.len});
    return 0;
}

/// `publr seed`'s batches run as typed commands on this site.
const Here = struct {
    init: std.process.Init,
    db_path: [:0]const u8,

    fn runner(here: *const Here) core.seed.Runner {
        return .{
            .context = here,
            .run = &run_here,
        };
    }

    fn run_here(context: *const anyopaque, words: []const []const u8, out: *std.Io.Writer) !u8 {
        const here: *const Here = @ptrCast(@alignCast(context));

        std.debug.assert(words.len > 0);

        return run_command(here.init, here.db_path, words, out);
    }
};

/// Where `seed` is in the words: first, or after who runs it (`--as-admin`, `--as <who>`),
/// which every batch it sends then carries.
fn seed_at(words: []const []const u8) ?u32 {
    std.debug.assert(words.len <= args_max);

    const at: u32 = if (words.len > 1 and std.mem.eql(u8, words[0], "--as-admin"))
        1
    else if (words.len > 2 and std.mem.eql(u8, words[0], "--as"))
        2
    else
        0;

    if (words.len > at and std.mem.eql(u8, words[at], "seed")) {
        return at;
    }

    return null;
}
