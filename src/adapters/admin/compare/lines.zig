//! A file beside another version of it, line by line: what one version changed marked in its
//! box, long runs neither changed folded to the lines around the changes, and the change
//! said in a few words above it.
const std = @import("std");
const diff = @import("../../../model/diff.zig");
const Segment = @import("field.zig").Segment;

/// Lines kept on each side of a change; a longer unchanged run folds to a count.
const context_lines: u32 = 3;

/// `after` with what it changed against `before` marked, unchanged runs folded.
pub fn marked(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const Segment {
    std.debug.assert(before.len <= std.math.maxInt(u32));
    std.debug.assert(after.len <= std.math.maxInt(u32));

    const segments = try diff.lines(arena, before, after);
    var found: std.ArrayList(Segment) = .empty;

    if (segments.len == 1 and segments[0].mark == .same) {
        return plain(arena, after);
    }

    for (segments, 0..) |segment, index| {
        if (segment.mark != .same) {
            try found.append(arena, .{
                .text = segment.text,
                .mark = @tagName(segment.mark),
            });

            continue;
        }

        try fold(arena, &found, segment.text, index == 0, index + 1 == segments.len);
    }

    std.debug.assert(found.items.len >= segments.len);

    return found.items;
}

/// What `after` changed against `before`, in words: `3 lines added, 1 removed`; none when
/// nothing did.
pub fn summary(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const Segment {
    std.debug.assert(before.len <= std.math.maxInt(u32));
    std.debug.assert(after.len <= std.math.maxInt(u32));

    var added: u32 = 0;
    var removed: u32 = 0;

    for (try diff.lines(arena, before, after)) |segment| {
        switch (segment.mark) {
            .same => {},
            .added => added += line_count(segment.text),
            .removed => removed += line_count(segment.text),
        }
    }

    var found: std.ArrayList(Segment) = .empty;

    if (added > 0) {
        try found.append(arena, .{
            .text = try counted(arena, added, "added"),
            .mark = "added",
        });
    }

    if (removed > 0) {
        try found.append(arena, .{
            .text = if (added > 0)
                try std.fmt.allocPrint(arena, ", {d} removed", .{removed})
            else
                try counted(arena, removed, "removed"),
            .mark = "removed",
        });
    }

    return found.items;
}

fn counted(arena: std.mem.Allocator, count: u32, what: []const u8) ![]const u8 {
    std.debug.assert(count > 0);
    std.debug.assert(what.len > 0);

    const noun = if (count == 1) "line" else "lines";

    return std.fmt.allocPrint(arena, "{d} {s} {s}", .{ count, noun, what });
}

fn plain(arena: std.mem.Allocator, text: []const u8) ![]const Segment {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    return arena.dupe(Segment, &.{.{
        .text = text,
        .mark = "same",
    }});
}

/// An unchanged run: the lines next to a change kept, the rest said as a count.
fn fold(
    arena: std.mem.Allocator,
    found: *std.ArrayList(Segment),
    text: []const u8,
    first: bool,
    last: bool,
) !void {
    std.debug.assert(text.len > 0);

    const count = line_count(text);
    const head: u32 = if (first) 0 else context_lines;
    const tail: u32 = if (last) 0 else context_lines;

    if (count <= head + tail + 1) {
        try found.append(arena, .{
            .text = text,
            .mark = "same",
        });

        return;
    }

    const folded = count - head - tail;
    const head_end = offset_of_line(text, head);
    const tail_start = offset_of_line(text, count - tail);

    std.debug.assert(head_end <= tail_start);

    if (head > 0) {
        try found.append(arena, .{
            .text = text[0..head_end],
            .mark = "same",
        });
    }

    try found.append(arena, .{
        .text = try std.fmt.allocPrint(arena, "{d} unchanged lines{s}", .{
            folded,
            if (last) "" else "\n",
        }),
        .mark = "skipped",
    });

    if (tail > 0) {
        try found.append(arena, .{
            .text = text[tail_start..],
            .mark = "same",
        });
    }
}

fn line_count(text: []const u8) u32 {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    const breaks: u32 = @intCast(std.mem.count(u8, text, "\n"));
    const open = text.len > 0 and text[text.len - 1] != '\n';

    return breaks + @intFromBool(open);
}

/// Where line `index` starts (counted from 0); the text's length past its last line.
fn offset_of_line(text: []const u8, index: u32) u32 {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    var offset: usize = 0;
    var line: u32 = 0;

    while (line < index) : (line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, text, offset, '\n');

        offset = if (newline) |at| at + 1 else return @intCast(text.len);
    }

    return @intCast(offset);
}

fn joined(arena: std.mem.Allocator, segments: []const Segment) ![]const u8 {
    std.debug.assert(segments.len <= std.math.maxInt(u32));

    var text: std.ArrayList(u8) = .empty;

    for (segments) |segment| {
        try text.print(arena, "[{s}:{s}]", .{ segment.mark, segment.text });
    }

    return text.items;
}

test "a file's box marks its changed lines and folds a long run between them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";
    const after = "1\n2\n3\n4\n5\n6\n7\n8\n9\nten\n";

    try std.testing.expectEqualStrings(
        "[skipped:6 unchanged lines\n][same:7\n8\n9\n][removed:10\n][added:ten\n]",
        try joined(arena, try marked(arena, before, after)),
    );
    const unchanged = try joined(arena, try marked(arena, "a\n", "a\n"));

    try std.testing.expectEqualStrings("[same:a\n]", unchanged);
    try std.testing.expectEqualStrings(
        "[same:a\n][added:b\n]",
        try joined(arena, try marked(arena, "a\n", "a\nb\n")),
    );
}

test "a change is said in words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "[added:3 lines added][removed:, 1 removed]",
        try joined(arena, try summary(arena, "a\nb\n", "a\nc\nd\ne\n")),
    );
    try std.testing.expectEqualStrings(
        "[removed:1 line removed]",
        try joined(arena, try summary(arena, "a\nb\n", "a\n")),
    );
    try std.testing.expectEqual(0, (try summary(arena, "a\n", "a\n")).len);
}
