const std = @import("std");
const publr = @import("publr");
const command = @import("parity/command.zig");
const shape = @import("parity/shape.zig");
const world = @import("parity/world.zig");

const SDK = publr.registry.SDK;
const operation = publr.sdk.operation;

const output_bytes_max: u32 = 256 << 10;
const argv_max: u32 = command.args_max + 1;

/// Runs the example every `--help` prints, against a database holding what it names, and
/// checks the answer against the `example_out` printed beside it. Documentation that has
/// stopped being true fails here.
pub fn main(init: std.process.Init) !u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());

    _ = iterator.next();

    const binary_arg = iterator.next() orelse return error.MissingBinaryPath;
    const work_dir = iterator.next() orelse return error.MissingWorkDir;
    const arena = init.arena.allocator();
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, binary_arg, arena);

    std.debug.assert(std.fs.path.isAbsolute(binary));
    std.debug.assert(std.fs.path.isAbsolute(work_dir));

    try std.Io.Dir.cwd().deleteTree(init.io, work_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, work_dir);

    var checked: u32 = 0;

    inline for (SDK.operations) |Operation| {
        try check(init, binary, work_dir, Operation);

        checked += 1;
    }

    std.debug.print("parity: ok ({d} operations)\n", .{checked});

    return 0;
}

fn check(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    comptime Operation: type,
) !void {
    const arena = init.arena.allocator();
    const dir = try std.fs.path.join(arena, &.{ work_dir, comptime folder(Operation.name) });

    comptime std.debug.assert(Operation.name.len > 0);
    std.debug.assert(dir.len > work_dir.len);

    try std.Io.Dir.cwd().createDirPath(init.io, dir);

    if (comptime !std.mem.eql(u8, Operation.name, "project.init")) {
        try seed(init, dir);
    }

    const namespace = comptime operation.namespace(Operation.name);
    const verb = comptime operation.verb(Operation.name);
    const help = try capture(init, binary, dir, &.{ namespace, verb, "--help" }, Operation);

    var storage: [command.args_max][]const u8 = undefined;
    const printed = try command.parse(help, &storage);
    const answer = try run_example(init, binary, dir, printed, Operation);

    const parsed = std.json.parseFromSliceLeaky(Operation.Out, arena, answer, .{}) catch {
        return fail(Operation, "answer is not the documented output shape", answer);
    };

    shape.same(Operation.example_out, parsed) catch {
        return fail(Operation, "answer does not match its `example_out`", answer);
    };
}

/// The printed example run; a sign-on token is made fresh, as a printed one is long spent.
fn run_example(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    printed: []const []const u8,
    comptime Operation: type,
) ![]const u8 {
    std.debug.assert(printed.len > 0);
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();

    const arguments = if (comptime std.mem.eql(u8, Operation.name, "sign_on.redeem"))
        try world.fresh_sign_on(arena, printed, publr.sdk.context.wall_clock_ms(init.io))
    else
        printed;

    return capture(init, binary, dir, arguments, Operation);
}

fn seed(init: std.process.Init, dir: []const u8) !void {
    const db_path = try std.fs.path.joinZ(init.arena.allocator(), &.{ dir, "data", "publr.db" });

    std.debug.assert(std.fs.path.isAbsolute(db_path));
    std.debug.assert(db_path.len > dir.len);

    var application: publr.server.Server = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var ctx = publr.sdk.Ctx.init(.{
        .caller = .system,
        .db = &application.connection,
        .io = init.io,
        .arena = arena_state.allocator(),
        .auth = &application.auth,
        .now_ms = publr.sdk.context.wall_clock_ms(init.io),
    });

    ctx.sandboxed_plugins = application.sandboxed();

    try world.upload_plugins(init.io, dir);
    try world.fill(&ctx, dir);
}

fn capture(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    args: []const []const u8,
    comptime Operation: type,
) ![]const u8 {
    var argv: [argv_max][]const u8 = undefined;

    std.debug.assert(args.len < argv_max);
    std.debug.assert(binary.len > 0);

    argv[0] = binary;

    for (args, 0..) |arg, index| {
        argv[index + 1] = arg;
    }

    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });

    if (result.term != .exited or result.term.exited != 0) {
        report(args);

        return fail(Operation, "the printed command failed", result.stderr);
    }

    return result.stdout;
}

fn report(args: []const []const u8) void {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len < argv_max);

    std.debug.print("parity: ran: publr", .{});

    for (args) |arg| {
        std.debug.print(" {s}", .{arg});
    }

    std.debug.print("\n", .{});
}

fn fail(comptime Operation: type, reason: []const u8, detail: []const u8) error{ParityFailed} {
    comptime std.debug.assert(Operation.name.len > 0);
    std.debug.assert(reason.len > 0);

    std.debug.print("parity: {s}: {s}\n{s}\n", .{ Operation.name, reason, detail });

    return error.ParityFailed;
}

/// One directory per operation, so every example starts from a database of its own.
fn folder(comptime name: []const u8) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);
        std.debug.assert(name.len <= operation.name_len_max);

        var buffer: [name.len]u8 = undefined;

        for (name, 0..) |letter, index| {
            buffer[index] = if (letter == '.') '_' else letter;
        }

        const frozen = buffer;

        return &frozen;
    }
}

test {
    std.testing.refAllDecls(command);
    std.testing.refAllDecls(shape);
}
