const std = @import("std");
const publr = @import("publr");
const command = @import("parity/command.zig");
const shape = publr.sdk.testing.shape;
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

    // Each operation's name is compared with each skip at comptime, a byte at a time.
    @setEvalBranchQuota(SDK.operations.len * (skips.len + 2) * 64 * 2);

    inline for (SDK.operations) |Operation| {
        // Building a plugin needs the compiler, which the fixture binary does not carry;
        // smoke builds one with a binary that does.
        const builds = comptime std.mem.startsWith(u8, Operation.name, "plugin.build");

        const asks = comptime skipped(Operation.name);

        if ((builds and !publr.toolchain.carried) or asks) {
            continue;
        }

        try check(init, binary, work_dir, Operation);

        checked += 1;
    }

    std.debug.print("parity: ok ({d} operations)\n", .{checked});

    return 0;
}

/// The operations whose examples cannot run here. Asking a model starts an agent beside a server,
/// which the examples run without (smoke asks one of a running server); a fetch goes out to the
/// network, and only a plugin may send one; an import downloads; choosing, testing and setting up a
/// provider, and turning speech into text, need a provider plugin, which the seeded project does
/// not have; an update needs a running server and the network; a stream needs an agent; a removal
/// list is made by a device; a trash entry by a removal; a browser call is asked by an agent and
/// answered by a workspace page; a health case kept or unlinked needs a broken reference, which the
/// seeded project has none of; choosing between translations, or listing what one leaves
/// untranslated, needs plugins translating the admin, and it has none; installing from the
/// marketplace needs the plugins' built modules, which the fixture catalog does not carry;
/// overriding who may call needs a plugin's operation made with `publr.operation.define`, which the
/// fixture compiles in none of; and the seeded project's plugins queue no jobs for `job list` to
/// show nor fail one for `job run_again`, repeat none for `job schedule` to move, and declare no
/// webhooks for `webhook list` and `webhook run_again`; `project put` and `mod changed` answer only
/// a plugin's call; asking the marketplace answers a new id each time, and `job answer` reads only
/// an id someone was given; a plugin's field group values read and written are the sampler's own
/// group, which the seeded project has none of.
const skips = [_][]const u8{
    "ai.ask",
    "ai.reply",
    "http.fetch",
    "ai.choose",
    "ai.test",
    "ai.set_up",
    "ai.transcribe",
    "update.check",
    "update.apply",
    "update.rollback",
    "media.import",
    "http.stream",
    "http.read",
    "ai.progress",
    "removal.list",
    "removal.get",
    "removal.confirm",
    "removal.decline",
    "trash.restore",
    "trash.remove",
    "ai.browsed",
    "ai.browser_answer",
    "media.import_many",
    "apps.edit",
    "health.keep",
    "health.unlink",
    "health.choose_translation",
    "health.missing_translations",
    "plugin.install",
    "operation.authorize",
    "job.list",
    "job.run_again",
    "job.schedule",
    "webhook.list",
    "webhook.run_again",
    "project.put",
    "plugin.find",
    "job.answer",
    "custom_fields.values",
    "custom_fields.save_values",
    "mod.changed",
};

fn skipped(comptime name: []const u8) bool {
    comptime std.debug.assert(name.len > 0);

    for (skips) |skip| {
        if (std.mem.eql(u8, skip, name)) {
            return true;
        }
    }

    return false;
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

    const redeems = comptime std.mem.eql(u8, Operation.name, "sign_on.redeem") or
        std.mem.eql(u8, Operation.name, "device.redeem");
    const arguments = if (redeems)
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

    var ctx = publr.sdk.Ctx.init(
        &application.connection,
        init.io,
        arena_state.allocator(),
        &application.auth,
        .system,
        .{
            .now_ms = publr.sdk.context.wall_clock_ms(init.io),
        },
    );

    ctx.sandboxed_plugins = application.sandboxed();
    ctx.files = application.files_of();

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
        .cwd = .{
            .path = dir,
        },
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
