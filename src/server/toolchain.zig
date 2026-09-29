//! The Zig compiler the binary carries (`publr_zig`), for building sandboxed plugins where
//! no Zig is installed. `init` and `serve` write it out once per machine, into Publr's cache
//! folder; a compile runs it as a child process, so a crash or a runaway compile ends that
//! process, never Publr. A binary built with `-Dcompiler=false` carries none.
const std = @import("std");
const options = @import("toolchain_options");
const report = @import("../lib/report.zig");
const publr_zig = if (options.compiler) @import("publr_zig") else void;
const sdk_archive = if (options.compiler) @embedFile("sdk_archive") else "";

pub const carried = options.compiler;
/// How a `wasm32` module is built with it (see `publr_zig.wasm_flags`).
pub const wasm_flags = if (carried) publr_zig.wasm_flags else [_][]const u8{};

pub const Toolchain = struct {
    compiler: []const u8,
    compiler_rt: []const u8,
    /// Publr's SDK as plugins are built against it: `src/`, `stubs/`, `guest.zig`.
    sdk: []const u8,
};

/// Where the toolchain goes: `PUBLR_CACHE_DIR` (an image may carry it there, written out
/// already), else `$XDG_CACHE_HOME/publr`, else `$HOME/.cache/publr`, as Zig keeps its own
/// cache on macOS and Linux. Null when the environment names none of them.
pub fn cache_dir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    const own = nonempty(environ.get("PUBLR_CACHE_DIR"));
    const xdg = nonempty(environ.get("XDG_CACHE_HOME"));
    const home = nonempty(environ.get("HOME"));

    if (own) |dir| {
        return dir;
    }

    if (xdg) |dir| {
        return try std.fs.path.join(arena, &.{ dir, "publr" });
    }

    if (home) |dir| {
        return try std.fs.path.join(arena, &.{ dir, ".cache", "publr" });
    }

    std.debug.assert(own == null and xdg == null);

    return null;
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;

    return if (text.len == 0) null else text;
}

/// The toolchain, written out first if it is not there yet: `error.NoCompiler` in a binary
/// built without it, `error.NoCacheDir` when there is nowhere to write it.
pub fn unpack(init: std.process.Init) anyerror!Toolchain {
    const toolchain = if (carried) try unpack_carried(init) else return error.NoCompiler;

    std.debug.assert(toolchain.compiler.len > 0);
    std.debug.assert(toolchain.compiler_rt.len > 0);

    return toolchain;
}

fn unpack_carried(init: std.process.Init) !Toolchain {
    const arena = init.arena.allocator();
    const parent = try cache_dir(arena, init.environ_map) orelse return error.NoCacheDir;

    std.debug.assert(parent.len > 0);

    const unpacked = try publr_zig.unpack(init.io, arena, parent);
    const sdk = try publr_zig.write_out(init.io, arena, parent, "publr-sdk", sdk_archive);

    std.debug.assert(unpacked.compiler.len > parent.len);
    std.debug.assert(sdk.len > parent.len);

    return .{ .compiler = unpacked.compiler, .compiler_rt = unpacked.compiler_rt, .sdk = sdk };
}

/// At `init` and `serve`: have the toolchain ready before anything compiles. A failure is
/// a warning, never a reason for the CMS not to run; a compile tries again and reports why.
pub fn prepare(init: std.process.Init) void {
    if (!carried) {
        return;
    }

    if (unpack(init)) |toolchain| {
        std.debug.assert(toolchain.compiler.len > 0);
        std.debug.assert(toolchain.sdk.len > 0);
    } else |err| {
        report.warn_reason(
            @errorName(err),
            "publr: the compiler for plugins could not be written out; set PUBLR_CACHE_DIR " ++
                "to a writable folder. Everything else works.",
            .{},
        );
    }
}

/// `publr zig <args>`: the compiler, with the arguments as given; its exit code is the
/// command's. It builds `.wasm` only: it carries no LLVM.
pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const toolchain = unpack(init) catch |err| {
        report.err_reason(@errorName(err), "publr zig: {s}", .{switch (err) {
            error.NoCompiler => "this binary was built without the compiler (-Dcompiler=false)",
            error.NoCacheDir => "no folder to write it to; set PUBLR_CACHE_DIR or HOME",
            else => "the compiler could not be written out",
        }});
        return 1;
    };
    const argv = try init.arena.allocator().alloc([]const u8, args.len + 1);

    argv[0] = toolchain.compiler;
    @memcpy(argv[1..], args);

    std.debug.assert(argv[0].len > 0);
    std.debug.assert(argv.len == args.len + 1);

    var child = try std.process.spawn(init.io, .{ .argv = argv });

    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => 1,
    };
}
