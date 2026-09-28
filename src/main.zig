const std = @import("std");
const builtin = @import("builtin");
const publr = @import("publr");

const app = publr.app;
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

    if (rest.len >= 1 and std.mem.eql(u8, rest[0], "--db")) {
        if (rest.len < 2 or rest[1].len == 0) return error.InvalidArguments;
        db_path = try init.arena.allocator().dupeZ(u8, rest[1]);
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

    var application: app.App = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    const arena_bytes = try init.gpa.alloc(u8, app.request_arena_bytes);
    defer init.gpa.free(arena_bytes);

    var fixed = std.heap.FixedBufferAllocator.init(arena_bytes);

    return cli.CLI(registry.SDK).run(.{
        .db = &application.connection,
        .io = init.io,
        .arena = fixed.allocator(),
        .auth = &application.auth,
        .now_ms = sdk.context.wall_clock_ms(init.io),
        .password_env = init.environ_map.get("PUBLR_PASSWORD"),
    }, rest, out) catch |err| {
        report.err("publr: {s}", .{@errorName(err)});
        return 1;
    };
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

/// The commands that are not operations: `serve`, `build` and `check-theme`. Null for
/// anything else, which the CLI answers.
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

    // In the browser there is no server and no build: the modules are `void` there.
    if (builtin.os.tag == .wasi) {
        if (serve or build) {
            return error.Unsupported;
        }
    } else {
        if (serve) {
            return try publr.serve.run(init, db_path, rest[1..]);
        }

        if (build) {
            return try publr.build.run(init, db_path, rest[1..]);
        }
    }

    if (rest.len == 1 and std.mem.eql(u8, rest[0], "check-theme")) {
        return try check_theme(init, out);
    }

    return null;
}

/// `publr check-theme`: 0 when the embedded theme compiles, else 1 and the reason, the way
/// `serve` would report it at start.
fn check_theme(init: std.process.Init, out: *std.Io.Writer) !u8 {
    std.debug.assert(args_max > 0);

    const problem = try publr.public_site.check_theme(init.gpa, init.arena.allocator());

    if (problem) |reason| {
        report.err("[theme] {s}", .{reason});
        return 1;
    }

    try out.print("theme {s}: compiles\n", .{publr.public_site.theme_name});
    return 0;
}
