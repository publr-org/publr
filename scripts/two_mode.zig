//! The two-mode check: every fixture plugin installed in the sandbox of one Publr and
//! compiled into another, the same calls made of both, as the same people, and every
//! answer compared: exit, output and failure. Whatever a sandboxed plugin can do, the same
//! source compiled in must do the same way.
const std = @import("std");
const scenario = @import("two_mode/scenario.zig");
const coverage = @import("two_mode/coverage.zig");

const output_bytes_max: u32 = 64 << 10;
const plugins_max: u32 = 16;

pub const Mode = enum { sandboxed, native };

/// What one call answered, with what changes between runs (ids, times) masked.
pub const Answer = struct { exit: u8, stdout: []const u8, stderr: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    comptime coverage.check();

    const arena = init.arena.allocator();
    var iterator = try init.minimal.args.iterateAllocator(arena);

    _ = iterator.next();

    const sandboxed = try real(init, iterator.next() orelse return error.MissingBinary);
    const native = try real(init, iterator.next() orelse return error.MissingBinary);
    const work_dir = iterator.next() orelse return error.MissingWorkDir;
    var modules_storage: [plugins_max][]const u8 = undefined;
    var modules_len: u32 = 0;

    while (iterator.next()) |module| {
        if (modules_len == plugins_max) {
            return error.TooManyPlugins;
        }

        modules_storage[modules_len] = try real(init, module);
        modules_len += 1;
    }

    std.debug.assert(modules_len > 0);

    const modules = modules_storage[0..modules_len];
    const sandboxed_answers = try run_mode(init, .sandboxed, sandboxed, work_dir, modules);
    const native_answers = try run_mode(init, .native, native, work_dir, &.{});
    const differences = try report(arena, sandboxed_answers, native_answers);

    if (differences > 0) {
        std.debug.print("two-mode: {d} of {d} calls answered differently\n", .{
            differences,
            scenario.steps.len,
        });

        return 1;
    }

    std.debug.print("two-mode: ok ({d} calls, both ways)\n", .{scenario.steps.len});

    return 0;
}

fn real(init: std.process.Init, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);

    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(init.io, path, init.arena.allocator());

    std.debug.assert(std.fs.path.isAbsolute(resolved));

    return resolved;
}

/// A fresh project, the same people in it, the plugins installed when sandboxed, then every
/// step's answer.
fn run_mode(
    init: std.process.Init,
    mode: Mode,
    binary: []const u8,
    work_dir: []const u8,
    modules: []const []const u8,
) ![]const Answer {
    std.debug.assert(mode == .sandboxed or modules.len == 0);

    const arena = init.arena.allocator();
    const dir = try std.fs.path.join(arena, &.{ work_dir, @tagName(mode) });

    try std.Io.Dir.cwd().deleteTree(init.io, dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);

    for (scenario.setup) |step| {
        _ = try expect_ok(init, binary, dir, step);
    }

    for (modules) |module| {
        try install(init, binary, dir, module);
    }

    const answers = try arena.alloc(Answer, scenario.steps.len);

    for (scenario.steps, answers) |step, *answer| {
        answer.* = try call(init, binary, dir, step);
    }

    return answers;
}

/// Added, enabled and granted everything it asks for: what compiled in it has by building.
fn install(init: std.process.Init, binary: []const u8, dir: []const u8, module: []const u8) !void {
    std.debug.assert(std.fs.path.isAbsolute(module));

    const arena = init.arena.allocator();
    const add = [_][]const u8{ "--as-admin", "plugin", "add", "--file", module };
    const added = try expect_ok(init, binary, dir, &add);
    const Added = struct { name: []const u8 };
    const name = (try std.json.parseFromSliceLeaky(Added, arena, added, .{
        .ignore_unknown_fields = true,
    })).name;
    const enabled = try expect_ok(init, binary, dir, &.{
        "--as-admin", "plugin", "enable", "--name", name, "--content_access", "all",
    });
    const Request = struct { key: []const u8, state: []const u8 };
    const Enabled = struct { requests: []const Request };
    const parsed = try std.json.parseFromSliceLeaky(Enabled, arena, enabled, .{
        .ignore_unknown_fields = true,
    });

    for (parsed.requests) |request| {
        if (!std.mem.eql(u8, request.state, "granted")) {
            _ = try expect_ok(init, binary, dir, &.{
                "--as-admin", "plugin", "grant", "--name", name, "--key", request.key,
            });
        }
    }
}

fn expect_ok(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    args: []const []const u8,
) ![]const u8 {
    std.debug.assert(args.len > 0);

    const result = try run(init, binary, dir, args);
    const ok = result.term == .exited and result.term.exited == 0;

    if (!ok) {
        std.debug.print("two-mode: {s} {s}: {s}{s}\n", .{
            args[0],
            args[1],
            result.stdout,
            result.stderr,
        });

        return error.SetupFailed;
    }

    return result.stdout;
}

fn call(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    args: []const []const u8,
) !Answer {
    std.debug.assert(args.len > 0);

    const arena = init.arena.allocator();
    const result = try run(init, binary, dir, args);
    const exit: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };

    return .{
        .exit = exit,
        .stdout = try masked(arena, result.stdout),
        .stderr = try masked(arena, result.stderr),
    };
}

fn run(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    std.debug.assert(args.len < 24);
    std.debug.assert(binary.len > 0);

    var argv: [25][]const u8 = undefined;

    argv[0] = binary;

    for (args, 0..) |arg, index| {
        argv[index + 1] = arg;
    }

    return std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
}

/// Every run of ten or more hex digits with a digit in it (an id, a time) becomes `#`.
pub fn masked(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len <= output_bytes_max);

    var out: std.ArrayList(u8) = .empty;
    var index: u32 = 0;

    while (index < text.len) {
        var end = index;
        var digits = false;

        while (end < text.len and std.ascii.isHex(text[end])) : (end += 1) {
            digits = digits or std.ascii.isDigit(text[end]);
        }

        if (end - index >= 10 and digits) {
            try out.append(arena, '#');
            index = @intCast(end);
        } else if (end > index) {
            try out.appendSlice(arena, text[index..end]);
            index = @intCast(end);
        } else {
            try out.append(arena, text[index]);
            index += 1;
        }
    }

    std.debug.assert(out.items.len <= text.len);

    return out.items;
}

fn report(arena: std.mem.Allocator, sandboxed: []const Answer, native: []const Answer) !u32 {
    std.debug.assert(sandboxed.len == native.len);
    std.debug.assert(sandboxed.len == scenario.steps.len);

    var differences: u32 = 0;

    for (scenario.steps, sandboxed, native) |step, left, right| {
        const same = left.exit == right.exit and std.mem.eql(u8, left.stdout, right.stdout) and
            std.mem.eql(u8, left.stderr, right.stderr);

        if (!same) {
            differences += 1;
            std.debug.print("two-mode: publr {s}\n", .{try std.mem.join(arena, " ", step)});
            std.debug.print("  sandboxed, exit {d}:\n{s}{s}\n", .{
                left.exit,
                left.stdout,
                left.stderr,
            });
            std.debug.print("  native, exit {d}:\n{s}{s}\n", .{
                right.exit,
                right.stdout,
                right.stderr,
            });
        }
    }

    return differences;
}

test "ids and times are masked, words are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "{\"id\": \"9f3a0c1b2d4e5f60718293a4\", \"at\": 1790000000000, " ++
        "\"fade\": \"deadbeef\"}";
    const want = "{\"id\": \"#\", \"at\": #, \"fade\": \"deadbeef\"}";

    try std.testing.expectEqualStrings(want, try masked(arena, text));
}
