//! The admin's messages for translators: `zig run --dep i18n_marks -Mroot=scripts/i18n.zig
//! -Mi18n_marks=src/model/i18n/marks.zig -- <dir>...` writes a gettext template (`.pot`) to
//! stdout of every message marked in the `.ptsx`, `.ts`, `.publr` and `.zig` files under the
//! folders given, as `src/model/i18n/marks.zig` finds them. Each message once, with every
//! place it is written.
const std = @import("std");
const marks = @import("i18n_marks");

const Message = marks.Message;
const files_max: u32 = 8192;
const file_bytes_max = marks.file_bytes_max;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    if (arguments.len < 2) {
        std.debug.print("usage: i18n [--lines] [--domain <name>] <dir>... " ++
            "[--declared <file>...]\n", .{});
        std.process.exit(2);
    }

    var messages: std.ArrayList(Message) = .empty;
    var declared = false;
    var lines = false;
    var domain: []const u8 = "publr";
    var expect_domain = false;

    // `--declared` and the files after it: declarations whose `.label`, `.description` and
    // `.noun` the admin draws by name (statuses, field kinds, the sidebar's pages).
    for (arguments[1..]) |argument| {
        if (expect_domain) {
            domain = argument;
            expect_domain = false;
            declared = false;
        } else if (std.mem.eql(u8, argument, "--lines")) {
            lines = true;
        } else if (std.mem.eql(u8, argument, "--domain")) {
            expect_domain = true;
        } else if (std.mem.eql(u8, argument, "--declared")) {
            declared = true;
        } else if (declared) {
            const limit: std.Io.Limit = .limited(file_bytes_max);
            const text = try std.Io.Dir.cwd().readFileAlloc(init.io, argument, arena, limit);

            try marks.scan_declared(arena, argument, text, domain, &messages);
        } else {
            walk(init.io, arena, argument, domain, &messages) catch |err| switch (err) {
                // A plugin without a `ui/` or with nothing marked is fine.
                error.FileNotFound => continue,
                else => return err,
            };
        }
    }

    var buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    if (lines) {
        try write_lines(&stdout.interface, messages.items);
    } else {
        try write(&stdout.interface, messages.items);
    }

    try stdout.interface.flush();

    std.debug.assert(stdout.interface.end == 0);
}

/// `domain`, tab, `context`, tab, the message, one per line, tabs and line breaks escaped:
/// what the build embeds so the admin can count what a language covers.
fn write_lines(out: *std.Io.Writer, messages: []const Message) !void {
    for (messages) |message| {
        std.debug.assert(message.places.items.len > 0);

        try escaped(out, message.domain);
        try out.writeByte('\t');
        try escaped(out, message.context);
        try out.writeByte('\t');
        try escaped(out, message.id);
        try out.writeByte('\n');
    }
}

fn escaped(out: *std.Io.Writer, text: []const u8) !void {
    std.debug.assert(text.len <= file_bytes_max);

    for (text) |char| {
        switch (char) {
            '\\' => try out.writeAll("\\\\"),
            '\t' => try out.writeAll("\\t"),
            '\n' => try out.writeAll("\\n"),
            else => try out.writeByte(char),
        }
    }
}

fn walk(
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    domain: []const u8,
    messages: *std.ArrayList(Message),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !marks.wanted(entry.path)) {
            continue;
        }

        if (paths.items.len == files_max) {
            return error.TooManyFiles;
        }

        try paths.append(arena, try std.fs.path.join(arena, &.{ root, entry.path }));
    }

    std.debug.assert(paths.items.len <= files_max);

    std.mem.sort([]const u8, paths.items, {}, less);

    for (paths.items) |path| {
        const limit: std.Io.Limit = .limited(file_bytes_max);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit);

        try marks.scan(arena, path, text, domain, messages);
    }
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn write(out: *std.Io.Writer, messages: []const Message) !void {
    try out.writeAll(
        \\msgid ""
        \\msgstr ""
        \\"MIME-Version: 1.0\n"
        \\"Content-Type: text/plain; charset=UTF-8\n"
        \\"Content-Transfer-Encoding: 8bit\n"
        \\
        \\
    );

    for (messages, 0..) |message, index| {
        std.debug.assert(message.places.items.len > 0);

        // A template holds each message once, whichever domains share it.
        if (written_before(messages[0..index], message)) {
            continue;
        }

        for (message.places.items) |place| {
            try out.print("#: {s}\n", .{place});
        }

        if (message.context.len > 0) {
            try quoted(out, "msgctxt", message.context);
        }

        try quoted(out, "msgid", message.id);

        if (message.plural.len > 0) {
            try quoted(out, "msgid_plural", message.plural);
            try out.writeAll("msgstr[0] \"\"\nmsgstr[1] \"\"\n\n");
        } else {
            try out.writeAll("msgstr \"\"\n\n");
        }
    }
}

fn written_before(earlier: []const Message, message: Message) bool {
    std.debug.assert(message.places.items.len > 0);

    for (earlier) |known| {
        const same_context = std.mem.eql(u8, known.context, message.context);

        if (same_context and std.mem.eql(u8, known.id, message.id)) {
            return true;
        }
    }

    return false;
}

fn quoted(out: *std.Io.Writer, keyword: []const u8, text: []const u8) !void {
    std.debug.assert(keyword.len > 0);

    try out.print("{s} \"", .{keyword});

    for (text) |char| {
        switch (char) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\t' => try out.writeAll("\\t"),
            else => try out.writeByte(char),
        }
    }

    try out.writeAll("\"\n");
}
