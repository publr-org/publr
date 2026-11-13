//! `publr seed --type <type> --file <path> [--publish]`: a file of documents made into records,
//! in calls of `record create_many` (250 at a time, fewer when they are large), on this site
//! or the one `--site` names. The file is a JSON array of objects, or one object a line.
const std = @import("std");
const create_many = @import("../operations/record/create_many.zig");

const file_bytes_max: u64 = 1 << 30;
/// A batch's documents together, kept well under what a request carries (1 MiB).
const batch_bytes_max: u32 = 512 << 10;

const usage =
    \\usage: publr seed --type <type> --file <path> [--publish]
    \\
    \\Makes a record of the type from every document in the file: a JSON array of objects, or
    \\one object a line. Sent in batches of up to 250 (`record create_many`); each batch is all
    \\or nothing, and a refused one stops the seed, saying which document.
    \\
;

/// Runs one command's words where the seed goes: this site, or the one `--site` names.
pub const Runner = struct {
    context: *const anyopaque,
    run: *const Run,
};

pub const Run = fn (
    context: *const anyopaque,
    words: []const []const u8,
    out: *std.Io.Writer,
) anyerror!u8;

const Asked = struct {
    type: []const u8 = "",
    file: []const u8 = "",
    publish: bool = false,
};

/// Where the batches go, and who sends them (`--as-admin`, `--as <who>`), put before each.
pub const Target = struct {
    runner: Runner,
    caller: []const []const u8 = &.{},
};

pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    args: []const []const u8,
    target: Target,
) !u8 {
    std.debug.assert(args.len <= 128);

    const asked = parse(args) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const arena = init.arena.allocator();
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, asked.file, arena, limit) catch |err| {
        std.debug.print("publr seed: {s}: {t}\n", .{ asked.file, err });
        return 1;
    };
    const documents = try documents_of(arena, text) orelse {
        std.debug.print("publr seed: {s} is not a JSON array of objects, nor one object a " ++
            "line\n", .{
            asked.file,
        });
        return 1;
    };

    return send(init, out, asked, documents, target);
}

fn parse(args: []const []const u8) ?Asked {
    std.debug.assert(args.len <= 128);

    var asked: Asked = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const valued = index + 1 < args.len;

        if (std.mem.eql(u8, arg, "--type") and valued) {
            index += 1;
            asked.type = args[index];
        } else if (std.mem.eql(u8, arg, "--file") and valued) {
            index += 1;
            asked.file = args[index];
        } else if (std.mem.eql(u8, arg, "--publish")) {
            asked.publish = true;
        } else {
            return null;
        }
    }

    return if (asked.type.len > 0 and asked.file.len > 0) asked else null;
}

/// Each document as its own JSON text; null when the text is neither shape.
fn documents_of(arena: std.mem.Allocator, text: []const u8) !?[]const []const u8 {
    std.debug.assert(text.len <= file_bytes_max);

    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    if (trimmed.len == 0) {
        return null;
    }

    if (trimmed[0] == '[') {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch {
            return null;
        };

        if (parsed != .array) {
            return null;
        }

        const documents = try arena.alloc([]const u8, parsed.array.items.len);

        for (parsed.array.items, documents) |item, *document| {
            if (item != .object) {
                return null;
            }

            document.* = try std.json.Stringify.valueAlloc(arena, item, .{});
        }

        return documents;
    }

    var documents: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, trimmed, '\n');

    while (lines.next()) |line| {
        const document = std.mem.trim(u8, line, " \t\r");

        if (document.len == 0) {
            continue;
        }

        if (document[0] != '{') {
            return null;
        }

        try documents.append(arena, document);
    }

    return documents.items;
}

fn send(
    init: std.process.Init,
    out: *std.Io.Writer,
    asked: Asked,
    documents: []const []const u8,
    target: Target,
) !u8 {
    std.debug.assert(asked.type.len > 0);

    var start: u32 = 0;
    var batches: u32 = 0;

    while (start < documents.len) : (batches += 1) {
        var state = std.heap.ArenaAllocator.init(init.gpa);
        defer state.deinit();

        const arena = state.allocator();
        const end = batch_end(documents, start);
        var array: std.Io.Writer.Allocating = .init(arena);

        try array.writer.writeByte('[');

        for (documents[start..end], 0..) |document, index| {
            if (index > 0) {
                try array.writer.writeByte(',');
            }

            try array.writer.writeAll(document);
        }

        try array.writer.writeByte(']');

        const command = [_][]const u8{
            "record",      "create_many",   "--type",    asked.type,
            "--documents", array.written(), "--publish", if (asked.publish) "true" else "false",
        };
        const words = try std.mem.concat(arena, []const u8, &.{ target.caller, &command });
        var answer: std.Io.Writer.Allocating = .init(arena);
        const code = try target.runner.run(target.runner.context, words, &answer.writer);

        if (code != 0) {
            std.debug.print("publr seed: the batch from document {d} was refused:\n{s}", .{
                start,
                answer.written(),
            });
            return code;
        }

        start = end;
        try out.print("Seeded {d} of {d}\n", .{ start, documents.len });
        try out.flush();
    }

    std.debug.assert(batches > 0 or documents.len == 0);

    return 0;
}

/// Where a batch from `start` ends: 250 documents, or fewer when they pass `batch_bytes_max`,
/// never none.
fn batch_end(documents: []const []const u8, start: u32) u32 {
    std.debug.assert(start < documents.len);

    var end = start;
    var bytes: u64 = 0;

    while (end < documents.len and end - start < create_many.documents_max) : (end += 1) {
        bytes += documents[end].len + 1;

        if (bytes > batch_bytes_max and end > start) {
            break;
        }
    }

    return end;
}

test "a seed file is an array, or one object a line, and goes in batches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const array = (try documents_of(arena, "[{\"title\":\"A\"},{\"title\":\"B\"}]")).?;
    const lines = (try documents_of(arena, "{\"title\":\"A\"}\n\n{\"title\":\"B\"}\n")).?;

    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(try documents_of(arena, "[1,2]") == null);
    try std.testing.expect(try documents_of(arena, "title: A") == null);

    const many = try arena.alloc([]const u8, 600);

    @memset(many, "{\"title\":\"x\"}");
    try std.testing.expectEqual(@as(u32, 250), batch_end(many, 0));
    try std.testing.expectEqual(@as(u32, 600), batch_end(many, 500));
    try std.testing.expect(parse(&.{ "--type", "post" }) == null);
    const publishing = [_][]const u8{ "--type", "post", "--file", "a.json", "--publish" };

    try std.testing.expect(parse(&publishing).?.publish);
}
