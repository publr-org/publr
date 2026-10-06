//! What changed between two texts, word by word, for people to read (a merge's conflict, a
//! version compared). Words are runs of letters and digits; any other character stands
//! alone, so punctuation and spacing changes show too. The common start and end are matched
//! first; the rest is aligned by the longest common subsequence, or shown as removed then
//! added when it is too long to align within a request's memory.
const std = @import("std");

pub const Mark = enum { same, added, removed };

pub const Segment = struct { text: []const u8, mark: Mark };

/// Above this many cells (the words left on one side times the other's), the middle is
/// shown as removed then added.
const cells_max: u32 = 160_000;
const tokens_max: u32 = 100_000;

/// `after` as segments: what both have, what `before` had and `after` dropped (removed), and
/// what `after` has new (added), in reading order.
pub fn words(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const Segment {
    std.debug.assert(before.len <= std.math.maxInt(u32));
    std.debug.assert(after.len <= std.math.maxInt(u32));

    const old_tokens = try tokens(arena, before);
    const new_tokens = try tokens(arena, after);
    const start = common_start(old_tokens, new_tokens);
    const end = common_end(old_tokens[start..], new_tokens[start..]);
    const old_middle = old_tokens[start .. old_tokens.len - end];
    const new_middle = new_tokens[start .. new_tokens.len - end];
    var out: Builder = .{ .arena = arena };

    try out.add_all(old_tokens[0..start], .same);

    if (old_middle.len * new_middle.len > cells_max) {
        try out.add_all(old_middle, .removed);
        try out.add_all(new_middle, .added);
    } else {
        try aligned(arena, &out, old_middle, new_middle);
    }

    try out.add_all(old_tokens[old_tokens.len - end ..], .same);

    return tidied(arena, out.segments.items);
}

/// Changes only a space or a mark apart read as one: the old phrase struck, then the new
/// one, instead of single words woven together around what they share.
fn tidied(arena: std.mem.Allocator, segments: []const Segment) ![]const Segment {
    std.debug.assert(segments.len <= tokens_max * 2);

    var out: std.ArrayList(Segment) = .empty;
    var index: u32 = 0;

    while (index < segments.len) {
        if (segments[index].mark == .same) {
            try out.append(arena, segments[index]);
            index += 1;

            continue;
        }

        var removed: std.ArrayList(u8) = .empty;
        var added: std.ArrayList(u8) = .empty;

        while (index < segments.len) : (index += 1) {
            const segment = segments[index];
            const bridge = segment.mark == .same and is_slight(segment.text) and
                index + 1 < segments.len and segments[index + 1].mark != .same;

            if (segment.mark == .same and !bridge) {
                break;
            }

            if (segment.mark != .added) {
                try removed.appendSlice(arena, segment.text);
            }

            if (segment.mark != .removed) {
                try added.appendSlice(arena, segment.text);
            }
        }

        if (removed.items.len > 0) {
            try out.append(arena, .{ .text = removed.items, .mark = .removed });
        }

        if (added.items.len > 0) {
            try out.append(arena, .{ .text = added.items, .mark = .added });
        }
    }

    std.debug.assert(out.items.len <= segments.len * 2);

    return out.items;
}

/// A space or a mark between two changes, no word of its own.
fn is_slight(text: []const u8) bool {
    std.debug.assert(text.len > 0);

    if (text.len > 3) {
        return false;
    }

    for (text) |char| {
        if (is_word(char)) {
            return false;
        }
    }

    return true;
}

fn common_start(old_tokens: []const []const u8, new_tokens: []const []const u8) u32 {
    std.debug.assert(old_tokens.len <= tokens_max + 1);
    std.debug.assert(new_tokens.len <= tokens_max + 1);

    const shortest = @min(old_tokens.len, new_tokens.len);
    var count: u32 = 0;

    while (count < shortest and std.mem.eql(u8, old_tokens[count], new_tokens[count])) {
        count += 1;
    }

    return count;
}

fn common_end(old_tokens: []const []const u8, new_tokens: []const []const u8) u32 {
    std.debug.assert(old_tokens.len <= tokens_max + 1);
    std.debug.assert(new_tokens.len <= tokens_max + 1);

    const shortest = @min(old_tokens.len, new_tokens.len);
    var count: u32 = 0;

    while (count < shortest and same_from_end(old_tokens, new_tokens, count)) {
        count += 1;
    }

    return count;
}

fn same_from_end(old_tokens: []const []const u8, new_tokens: []const []const u8, back: u32) bool {
    std.debug.assert(back < old_tokens.len);
    std.debug.assert(back < new_tokens.len);

    const old_token = old_tokens[old_tokens.len - 1 - back];
    const new_token = new_tokens[new_tokens.len - 1 - back];

    return std.mem.eql(u8, old_token, new_token);
}

const Builder = struct {
    arena: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,

    /// A token added, joined to the last segment when that is marked the same.
    fn add(builder: *Builder, text: []const u8, mark: Mark) !void {
        std.debug.assert(text.len > 0);
        std.debug.assert(builder.segments.items.len <= tokens_max * 2);

        const items = builder.segments.items;

        if (items.len == 0 or items[items.len - 1].mark != mark) {
            try builder.segments.append(builder.arena, .{ .text = text, .mark = mark });

            return;
        }

        const last = &items[items.len - 1];
        const adjacent = last.text.ptr + last.text.len == text.ptr;

        if (adjacent) {
            last.text = last.text.ptr[0 .. last.text.len + text.len];
        } else {
            last.text = try std.mem.concat(builder.arena, u8, &.{ last.text, text });
        }
    }

    fn add_all(builder: *Builder, list: []const []const u8, mark: Mark) !void {
        std.debug.assert(list.len <= tokens_max + 1);
        std.debug.assert(builder.segments.items.len <= tokens_max * 2);

        for (list) |token| {
            try builder.add(token, mark);
        }
    }
};

/// The middle aligned by the longest common subsequence of its tokens.
fn aligned(
    arena: std.mem.Allocator,
    out: *Builder,
    old_middle: []const []const u8,
    new_middle: []const []const u8,
) !void {
    std.debug.assert(old_middle.len * new_middle.len <= cells_max);
    std.debug.assert(out.segments.items.len <= tokens_max * 2);

    const table = try lengths(arena, old_middle, new_middle);
    const width = new_middle.len + 1;
    var old_index: usize = 0;
    var new_index: usize = 0;

    while (old_index < old_middle.len and new_index < new_middle.len) {
        const old_token = old_middle[old_index];
        const new_token = new_middle[new_index];

        if (std.mem.eql(u8, old_token, new_token)) {
            try out.add(old_token, .same);
            old_index += 1;
            new_index += 1;
        } else if (table[(old_index + 1) * width + new_index] >=
            table[old_index * width + new_index + 1])
        {
            try out.add(old_token, .removed);
            old_index += 1;
        } else {
            try out.add(new_token, .added);
            new_index += 1;
        }
    }

    try out.add_all(old_middle[old_index..], .removed);
    try out.add_all(new_middle[new_index..], .added);
}

/// For every pair of positions, how long a common subsequence the rest of both share.
fn lengths(
    arena: std.mem.Allocator,
    old_middle: []const []const u8,
    new_middle: []const []const u8,
) ![]const u32 {
    std.debug.assert(old_middle.len * new_middle.len <= cells_max);
    std.debug.assert(old_middle.len <= tokens_max and new_middle.len <= tokens_max);

    const width = new_middle.len + 1;
    const table = try arena.alloc(u32, (old_middle.len + 1) * width);

    @memset(table, 0);

    var old_index = old_middle.len;

    while (old_index > 0) {
        old_index -= 1;

        var new_index = new_middle.len;

        while (new_index > 0) {
            new_index -= 1;

            const here = old_index * width + new_index;

            table[here] = if (std.mem.eql(u8, old_middle[old_index], new_middle[new_index]))
                table[here + width + 1] + 1
            else
                @max(table[here + width], table[here + 1]);
        }
    }

    return table;
}

/// The text cut into words (runs of letters and digits, bytes beyond ASCII counted as
/// letters) and single other characters, each a slice of `text`.
fn tokens(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(tokens_max > 0);

    var found: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;

    while (index < text.len) {
        if (found.items.len == tokens_max) {
            try found.append(arena, text[index..]);

            break;
        }

        const start = index;

        index += 1;

        if (is_word(text[start])) {
            while (index < text.len and is_word(text[index])) {
                index += 1;
            }
        }

        try found.append(arena, text[start..index]);
    }

    return found.items;
}

fn is_word(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char >= 0x80;
}

fn shown(arena: std.mem.Allocator, segments: []const Segment) ![]const u8 {
    std.debug.assert(segments.len <= tokens_max * 2);

    var text: std.ArrayList(u8) = .empty;

    for (segments) |segment| {
        std.debug.assert(segment.text.len > 0);

        switch (segment.mark) {
            .same => try text.appendSlice(arena, segment.text),
            .added => try text.print(arena, "[+{s}]", .{segment.text}),
            .removed => try text.print(arena, "[-{s}]", .{segment.text}),
        }
    }

    return text.items;
}

test "a word changed shows removed and added beside the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][3][]const u8{
        .{ "Hello world, again", "Hello there, again", "Hello [-world][+there], again" },
        .{ "Hello world", "Hello world, again", "Hello world[+, again]" },
        .{ "Old title", "New title", "[-Old][+New] title" },
        .{ "Same", "Same", "Same" },
        .{ "", "Added", "[+Added]" },
        .{ "Gone", "", "[-Gone]" },
        .{ "a b c", "a c d", "a [-b ]c[+ d]" },
        .{
            "First line",
            "The branch rewrote this",
            "[-First line][+The branch rewrote this]",
        },
    };

    for (cases) |case| {
        const segments = try words(arena, case[0], case[1]);

        try std.testing.expectEqualStrings(case[2], try shown(arena, segments));
    }
}
