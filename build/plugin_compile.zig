//! A sandboxed plugin built for Publr's own build (its test plugins, `zig build
//! sandboxed-plugins`), as the `publr` command builds one: Publr's `plugin prepare` gives the
//! SDK and the compiler's arguments, the Zig running this build compiles them for wasm32,
//! `plugin check --file` makes the module whole. Publr carries no compiler of its own.
//!
//! `plugin_compile <publr> <zig> <cache> <name> <dir> <out> [--with <x.wasm>]... [--llvm]`
//!
//! `--llvm` compiles with LLVM, optimising for speed, for the modules Publr ships: an installed
//! plugin runs metered in an interpreter, and LLVM's code takes a few times fewer instructions.
//! Without it, Zig's own backend, as a person's build has it.
const std = @import("std");

/// The same as the `publr` command's (`../lib/zig`'s `wasm_flags`), but this Zig brings its
/// own compiler_rt.
const wasm_flags = [_][]const u8{ "-fno-llvm", "-fno-lld", "-fno-ubsan-rt", "-fno-entry" };
/// LLVM's: it and its linker, the rest the same.
const llvm_flags = [_][]const u8{ "-fno-ubsan-rt", "-fno-entry" };
const output_bytes_max: u32 = 16 << 20;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 7) {
        std.debug.print("usage: plugin_compile <publr> <zig> <cache> <name> <dir> <out> " ++
            "[--with <x.wasm>]...\n", .{});
        return 2;
    }

    // The build passes paths from where it runs; each command here runs in its own folder.
    const here = try std.process.currentPathAlloc(init.io, arena);
    const publr = try std.fs.path.resolve(arena, &.{ here, args[1] });
    const zig = try std.fs.path.resolve(arena, &.{ here, args[2] });
    const cache = try std.fs.path.resolve(arena, &.{ here, args[3] });
    const name = args[4];
    const dir = try std.fs.path.resolve(arena, &.{ here, args[5] });
    const out = try std.fs.path.resolve(arena, &.{ here, args[6] });
    const llvm = std.mem.eql(u8, args[args.len - 1], "--llvm");
    const with = try resolved(arena, here, args[7 .. args.len - @intFromBool(llvm)]);

    std.debug.assert(std.fs.path.isAbsolute(out));
    std.debug.assert(name.len > 0);

    const work = try std.fmt.allocPrint(arena, "{s}.work", .{out});
    const cwd = std.Io.Dir.cwd();

    try cwd.deleteTree(init.io, work);
    try cwd.createDirPath(init.io, work);

    var prepare: std.ArrayList([]const u8) = .empty;
    const prepared = try std.fs.path.join(arena, &.{ work, "prepared" });

    try prepare.appendSlice(arena, &.{ publr, "plugin", "prepare", "--name", name });
    try prepare.appendSlice(arena, &.{ "--dir", dir, "--out", prepared });
    try prepare.appendSlice(arena, with);

    const plan_text = try run(init, work, prepare.items) orelse return 1;
    const Plan = struct {
        args: []const []const u8,
        module: []const u8,
        views: ?[]const u8 = null,
        dir: []const u8,
    };
    const plan = try std.json.parseFromSliceLeaky(Plan, arena, plan_text, .{
        .ignore_unknown_fields = true,
    });
    var compile: std.ArrayList([]const u8) = .empty;

    try compile.append(arena, zig);
    try compile.appendSlice(arena, if (llvm) try for_speed(arena, plan.args) else plan.args);
    try compile.appendSlice(arena, if (llvm) &llvm_flags else &wasm_flags);
    try compile.appendSlice(arena, &.{ "--cache-dir", cache, "--global-cache-dir", cache });

    _ = try run(init, work, compile.items) orelse return 1;

    var check: std.ArrayList([]const u8) = .empty;

    try check.appendSlice(arena, &.{ publr, "plugin", "check", "--file", plan.module });
    try check.appendSlice(arena, &.{ "--dir", plan.dir, "--no-examples" });

    if (plan.views) |views| {
        try check.appendSlice(arena, &.{ "--views", views });
    }

    try check.appendSlice(arena, with);
    _ = try run(init, work, check.items) orelse return 1;

    try cwd.copyFile(plan.module, cwd, out, init.io, .{});
    try cwd.deleteTree(init.io, work);

    return 0;
}

/// The compiler's arguments with each module optimised for speed instead of size, stripped of
/// debug information as a small build is.
fn for_speed(arena: std.mem.Allocator, given: []const []const u8) ![]const []const u8 {
    var changed: std.ArrayList([]const u8) = .empty;

    for (given) |word| {
        if (std.mem.eql(u8, word, "-Osmall")) {
            try changed.appendSlice(arena, &.{ "-OReleaseFast", "-fstrip" });
        } else {
            try changed.append(arena, word);
        }
    }

    std.debug.assert(changed.items.len >= given.len);

    return changed.items;
}

/// `--with <x.wasm>` words, the files made absolute.
fn resolved(
    arena: std.mem.Allocator,
    here: []const u8,
    words: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(std.fs.path.isAbsolute(here));

    var all: std.ArrayList([]const u8) = .empty;

    for (words) |word| {
        const flag = std.mem.startsWith(u8, word, "--");
        const given = if (flag) word else try std.fs.path.resolve(arena, &.{ here, word });

        try all.append(arena, given);
    }

    std.debug.assert(all.items.len == words.len);

    return all.items;
}

/// The command's output; null, with its messages printed, when it failed.
fn run(init: std.process.Init, folder: []const u8, argv: []const []const u8) !?[]const u8 {
    std.debug.assert(argv.len > 0);

    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv,
        .cwd = .{
            .path = folder,
        },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (!ok) {
        std.debug.print("{s}: failed\n{s}{s}", .{ argv[0], result.stdout, result.stderr });
        return null;
    }

    return result.stdout;
}
