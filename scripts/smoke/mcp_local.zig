//! `publr mcp` in a folder linked to no site, with no sign-ins kept: it answers the
//! handshake, lists the tools by name with `link`, and a tool call says the folder is not
//! linked yet. `publr setup` without a tool says how to use it.
const std = @import("std");
const smoke = @import("../smoke.zig");

const messages =
    \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"smoke"}}}
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{}}}
    \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    \\
;
const expected = [_][]const u8{
    "\"listChanged\":true",
    "\"name\":\"link\"",
    "is not linked to a Publr site yet",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}",
};

pub fn expect_mcp_local(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const arena = init.arena.allocator();
    // Outside every site: the work folder is one, and so may be the folders above it.
    const temporary = init.environ_map.get("TMPDIR") orelse "/tmp";
    const unlinked = try std.fs.path.join(arena, &.{ temporary, "publr-smoke-mcp" });
    const inside = try std.fmt.allocPrint(arena, "{s}/mcp-local", .{work_dir});

    try std.Io.Dir.cwd().deleteTree(init.io, unlinked);
    try std.Io.Dir.cwd().createDirPath(init.io, unlinked);
    try std.Io.Dir.cwd().createDirPath(init.io, inside);
    defer std.Io.Dir.cwd().deleteTree(init.io, unlinked) catch |err| {
        std.debug.print("smoke: mcp: {s}: {t}\n", .{ unlinked, err });
    };

    const output = try exchange(init, binary, unlinked);

    for (expected) |needle| {
        if (std.mem.indexOf(u8, output, needle) == null) {
            std.debug.print("smoke: mcp: missing {s} in {s}\n", .{ needle, output });
            return error.SmokeFailed;
        }
    }

    // A folder inside a site works on that site, here one nothing serves.
    const in_site = try exchange(init, binary, inside);

    if (std.mem.indexOf(u8, in_site, "nothing serves it") == null) {
        std.debug.print("smoke: mcp: a site's folder: {s}\n", .{in_site});
        return error.SmokeFailed;
    }

    const unknown = [_][]const u8{ "setup", "windows-phone" };

    try smoke.expect_failure(init, binary, inside, &unknown, "usage: publr setup cursor");
}

/// `messages` to `publr mcp` in `folder`, with no sign-ins kept, and everything it answered.
fn exchange(init: std.process.Init, binary: []const u8, folder: []const u8) ![]const u8 {
    std.debug.assert(folder.len > 0);

    const arena = init.arena.allocator();
    var environ = try init.environ_map.clone(arena);

    try environ.put("PUBLR_CREDENTIALS", try std.fmt.allocPrint(arena, "{s}/none", .{folder}));

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "mcp", "--folder", folder },
        .cwd = .{
            .path = folder,
        },
        .environ_map = &environ,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(init.io);

    try child.stdin.?.writeStreamingAll(init.io, messages);
    child.stdin.?.close(init.io);
    child.stdin = null;

    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(init.io, &buffer);

    return reader.interface.allocRemaining(arena, .limited(1 << 20));
}
