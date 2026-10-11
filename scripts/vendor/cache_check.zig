const std = @import("std");

const summary_bytes_max: u32 = 1 << 20;
const vendor_line = "compile lib publr_vendors";

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    if (args.len < 2) {
        return error.MissingArguments;
    }

    const zig_exe = args[0];
    const build_root = args[1];

    std.debug.assert(zig_exe.len > 0);
    std.debug.assert(build_root.len > 0);

    _ = try run_build(init, zig_exe, build_root);

    const summary = try run_build(init, zig_exe, build_root);
    const counts = count_vendor_lines(summary, true);

    std.debug.assert(counts.vendor_lines >= 2);

    if (counts.uncached != 0) {
        return 1;
    }

    const total = counts.vendor_lines;
    std.debug.print("vendor cache check: {d} vendor libraries, all cached\n", .{total});

    return 0;
}

pub const Counts = struct {
    vendor_lines: u32 = 0,
    uncached: u32 = 0,
};

pub fn count_vendor_lines(summary: []const u8, report: bool) Counts {
    std.debug.assert(summary.len <= summary_bytes_max);
    std.debug.assert(vendor_line.len > 0);

    var lines = std.mem.splitScalar(u8, summary, '\n');
    var counts: Counts = .{};

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, vendor_line) == null) {
            continue;
        }

        counts.vendor_lines += 1;

        const cached = std.mem.indexOf(u8, line, "cached") != null;
        const reused = std.mem.indexOf(u8, line, "reused") != null;

        if (!cached and !reused) {
            counts.uncached += 1;

            if (report) {
                std.debug.print("vendor library recompiled on a no-op build:\n{s}\n", .{line});
            }
        }
    }

    return counts;
}

fn run_build(init: std.process.Init, zig_exe: []const u8, build_root: []const u8) ![]u8 {
    std.debug.assert(zig_exe.len > 0);
    std.debug.assert(build_root.len > 0);

    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ zig_exe, "build", "verify", "--summary", "all" },
        .cwd = .{
            .path = build_root,
        },
        .stdout_limit = .limited(summary_bytes_max),
        .stderr_limit = .limited(summary_bytes_max),
    });

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}\n", .{result.stderr});
        return error.BuildFailed;
    }

    return result.stderr;
}

test "counts vendor library lines and flags the ones that were not cached" {
    const summary =
        \\+- compile lib publr_vendors ReleaseFast native cached 12ms
        \\+- compile lib publr_vendors ReleaseFast wasm32-wasi reused
        \\+- compile lib publr_vendors ReleaseFast x86_64-linux 3s
        \\+- compile exe publr Debug native cached
    ;
    const counts = count_vendor_lines(summary, false);

    try std.testing.expectEqual(@as(u32, 3), counts.vendor_lines);
    try std.testing.expectEqual(@as(u32, 1), counts.uncached);
    try std.testing.expectEqual(@as(u32, 0), count_vendor_lines("", false).vendor_lines);
}
