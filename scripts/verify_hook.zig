//! `verify-full`'s local hook (`docs/contributing/build.md`).
//!
//!   verify_hook <publr binary> <browser dir> <work dir>
//!       Runs `$PUBLR_VERIFY_HOOK` with these arguments and exits as it does; exits 0 when the
//!       variable is unset or empty.
//!
//! The variable is read here, as the step runs: Zig keeps what `build.zig` decided between
//! runs whatever the environment says, so read there it would stay as it was first seen.

const std = @import("std");

const variable = "PUBLR_VERIFY_HOOK";
const arguments_count: u32 = 3;

pub fn main(init: std.process.Init) !u8 {
    std.debug.assert(variable.len > 0);

    const hook = init.environ_map.get(variable) orelse return 0;

    if (hook.len == 0) {
        return 0;
    }

    const arena = init.arena.allocator();
    var iterator = try init.minimal.args.iterateAllocator(arena);
    var argv: [arguments_count + 1][]const u8 = undefined;
    var given: u32 = 0;

    _ = iterator.next();
    argv[0] = hook;

    while (iterator.next()) |argument| {
        if (given == arguments_count) {
            return usage();
        }

        argv[given + 1] = argument;
        given += 1;
    }

    if (given != arguments_count) {
        return usage();
    }

    return run(init, &argv);
}

fn run(init: std.process.Init, argv: []const []const u8) !u8 {
    std.debug.assert(argv.len == arguments_count + 1);
    std.debug.assert(argv[0].len > 0);

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
    });
    const term = try child.wait(init.io);

    return switch (term) {
        .exited => |code| code,
        else => blk: {
            std.debug.print("verify_hook: {s} stopped: {any}\n", .{ argv[0], term });
            break :blk 1;
        },
    };
}

fn usage() u8 {
    std.debug.assert(arguments_count > 0);

    std.debug.print("usage: verify_hook <publr binary> <browser dir> <work dir>\n", .{});
    return 2;
}
