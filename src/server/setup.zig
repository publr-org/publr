//! `publr setup <tool>`: adds Publr (`publr mcp`) to an agent's tool once, for every project,
//! in the tool's own way. Each window or session then works on the site its folder is linked
//! to. The entry names this binary by its full path: apps started from the Dock do not see
//! the shell's PATH.
const std = @import("std");
const builtin = @import("builtin");

const cursor_install = "cursor://anysphere.cursor-deeplink/mcp/install";
const config_bytes_max: u32 = 4096;
/// What opens a link in its app: Cursor's, here.
const opener: []const u8 = switch (builtin.os.tag) {
    .macos => "open",
    .linux => "xdg-open",
    else => "",
};

const usage =
    \\usage: publr setup cursor|claude|codex
    \\
    \\Adds Publr to that tool for every project: open a project's folder there and ask. The
    \\first time in a folder, the agent asks which site it is for; your browser opens on that
    \\site once, to approve this computer.
    \\
;

const Tool = enum {
    cursor,
    claude,
    codex,
};

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(args.len <= 128);

    const tool = if (args.len == 1) std.meta.stringToEnum(Tool, args[0]) else null;
    const chosen = tool orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    if (builtin.os.tag == .windows) {
        std.debug.print("publr setup: not on Windows yet; add the site from its Devices " ++
            "page\n", .{});
        return 1;
    }

    const arena = init.arena.allocator();
    const binary = try std.process.executablePathAlloc(init.io, arena);

    std.debug.assert(binary.len > 0);

    return switch (chosen) {
        .cursor => cursor(init, out, binary),
        .claude => command(init, out, .{
            .remove = &.{ "claude", "mcp", "remove", "--scope", "user", "publr" },
            .add = &.{ "claude", "mcp", "add", "--scope", "user", "publr", "--", binary, "mcp" },
            .done = "Added to Claude Code for every folder, as publr. Start claude in a " ++
                "project's folder and ask.",
        }),
        .codex => command(init, out, .{
            .remove = &.{ "codex", "mcp", "remove", "publr" },
            .add = &.{ "codex", "mcp", "add", "publr", "--", binary, "mcp" },
            .done = "Added to Codex for every project, as publr. Start codex in a " ++
                "project's folder and ask.",
        }),
    };
}

/// Cursor's own install link, so Cursor asks the person: the folder of each window is
/// passed as `--folder`.
fn cursor(init: std.process.Init, out: *std.Io.Writer, binary: []const u8) !u8 {
    std.debug.assert(binary.len > 0);

    const link = try cursor_link(init.arena.allocator(), binary);

    if (!spawn_ok(init, &.{ opener, link }, .ignore)) {
        try out.print("Could not open Cursor. Add this to ~/.cursor/mcp.json under " ++
            "\"mcpServers\":\n\"publr\": {s}\n", .{try config_of(init.arena.allocator(), binary)});
        return 1;
    }

    try out.writeAll("Cursor asks to install publr: choose Install. Then open a project's " ++
        "folder in Cursor and ask.\n");

    return 0;
}

pub fn cursor_link(arena: std.mem.Allocator, binary: []const u8) ![]const u8 {
    std.debug.assert(binary.len > 0);

    const config = try config_of(arena, binary);
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(config.len));
    var link: std.Io.Writer.Allocating = .init(arena);

    _ = encoder.encode(encoded, config);
    try link.writer.print("{s}?name=publr&config=", .{cursor_install});

    for (encoded) |character| {
        switch (character) {
            '+' => try link.writer.writeAll("%2B"),
            '/' => try link.writer.writeAll("%2F"),
            '=' => try link.writer.writeAll("%3D"),
            else => try link.writer.writeByte(character),
        }
    }

    return link.written();
}

fn config_of(arena: std.mem.Allocator, binary: []const u8) ![]const u8 {
    std.debug.assert(binary.len > 0);

    const config = try std.json.Stringify.valueAlloc(arena, .{
        .command = binary,
        .args = .{ "mcp", "--folder", "${workspaceFolder}" },
    }, .{});

    std.debug.assert(config.len <= config_bytes_max);

    return config;
}

const Steps = struct {
    remove: []const []const u8,
    add: []const []const u8,
    done: []const u8,
};

/// The tool's own `mcp add`, after its `mcp remove`, so running it again points the entry at
/// this binary and changes nothing else.
fn command(init: std.process.Init, out: *std.Io.Writer, steps: Steps) !u8 {
    std.debug.assert(steps.add.len > 0);
    std.debug.assert(steps.remove.len > 0);

    _ = spawn_ok(init, steps.remove, .ignore);

    if (!spawn_ok(init, steps.add, .inherit)) {
        std.debug.print("publr setup: `{s} mcp add` failed; is {s} installed?\n", .{
            steps.add[0],
            steps.add[0],
        });
        return 1;
    }

    try out.print("{s}\n", .{steps.done});

    return 0;
}

fn spawn_ok(
    init: std.process.Init,
    argv: []const []const u8,
    output: std.process.SpawnOptions.StdIo,
) bool {
    std.debug.assert(argv.len > 0);

    if (argv[0].len == 0) {
        return false;
    }

    var child = std.process.spawn(init.io, .{
        .argv = argv,
        .stdout = output,
        .stderr = output,
    }) catch return false;
    const term = child.wait(init.io) catch return false;

    return term == .exited and term.exited == 0;
}

test "Cursor's link carries the binary and passes each window's folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const link = try cursor_link(arena, "/Users/ada/.local/bin/publr");
    const at = std.mem.indexOf(u8, link, "config=").? + "config=".len;
    const decoder = std.base64.standard.Decoder;
    var encoded: std.ArrayList(u8) = .empty;
    var index: u32 = @intCast(at);

    while (index < link.len) : (index += 1) {
        if (link[index] == '%') {
            const byte = try std.fmt.parseInt(u8, link[index + 1 .. index + 3], 16);

            try encoded.append(arena, byte);
            index += 2;
        } else {
            try encoded.append(arena, link[index]);
        }
    }

    const decoded = try arena.alloc(u8, try decoder.calcSizeForSlice(encoded.items));

    try decoder.decode(decoded, encoded.items);
    try std.testing.expect(std.mem.startsWith(u8, link, cursor_install ++ "?name=publr&"));
    try std.testing.expect(std.mem.indexOf(u8, decoded, "/Users/ada/.local/bin/publr") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "${workspaceFolder}") != null);
}
