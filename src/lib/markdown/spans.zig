//! The pairs inline text is read by, found in one pass each before it is read: code spans
//! (a run of backticks and the next run of the same length) and brackets (`[` and the `]`
//! closing it, outside code). Linear, so no input makes the reading quadratic.

const std = @import("std");

pub const Code = struct {
    open: u32,
    /// The backticks on each side.
    len: u32,
    /// Where the closing run starts.
    close: u32,
};

pub const Bracket = struct {
    open: u32,
    close: u32,
};

pub const Spans = struct {
    /// By `open`, ascending.
    code: []const Code,
    /// By `open`, ascending.
    brackets: []const Bracket,
};

const Run = struct {
    at: u32,
    len: u32,
};

pub fn find(arena: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!Spans {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    const code = try code_spans(arena, input);
    const brackets = try bracket_pairs(arena, input, code);

    std.debug.assert(brackets.len <= input.len / 2);

    return .{
        .code = code,
        .brackets = brackets,
    };
}

fn backtick_runs(arena: std.mem.Allocator, input: []const u8) ![]const Run {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    var runs: std.ArrayList(Run) = .empty;
    var index: u32 = 0;

    while (index < input.len) {
        if (input[index] == '\\' and index + 1 < input.len) {
            index += 2;
            continue;
        }

        if (input[index] != '`') {
            index += 1;
            continue;
        }

        const start = index;

        while (index < input.len and input[index] == '`') {
            index += 1;
        }

        try runs.append(arena, .{
            .at = start,
            .len = index - start,
        });
    }

    std.debug.assert(index >= input.len);

    return runs.items;
}

/// Each run pairs with the next run of its length after it; a cursor per length only moves
/// forward, so every run is looked at a bounded number of times.
fn code_spans(arena: std.mem.Allocator, input: []const u8) ![]const Code {
    const runs = try backtick_runs(arena, input);

    std.debug.assert(runs.len <= input.len);

    var by_len: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;

    for (runs, 0..) |run, index| {
        const entry = try by_len.getOrPut(arena, run.len);

        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }

        try entry.value_ptr.append(arena, @intCast(index));
    }

    var cursors: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var spans: std.ArrayList(Code) = .empty;
    var consumed_end: u32 = 0;

    for (runs, 0..) |run, index| {
        if (run.at < consumed_end) {
            continue;
        }

        const same = by_len.get(run.len).?.items;
        const cursor = try cursors.getOrPut(arena, run.len);

        if (!cursor.found_existing) {
            cursor.value_ptr.* = 0;
        }

        while (cursor.value_ptr.* < same.len and same[cursor.value_ptr.*] <= index) {
            cursor.value_ptr.* += 1;
        }

        if (cursor.value_ptr.* == same.len) {
            continue;
        }

        const closer = runs[same[cursor.value_ptr.*]];

        try spans.append(arena, .{
            .open = run.at,
            .len = run.len,
            .close = closer.at,
        });
        consumed_end = closer.at + closer.len;
    }

    return spans.items;
}

fn bracket_pairs(arena: std.mem.Allocator, input: []const u8, code: []const Code) ![]const Bracket {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    var open: std.ArrayList(u32) = .empty;
    var pairs: std.ArrayList(Bracket) = .empty;
    var next_code: u32 = 0;
    var index: u32 = 0;

    while (index < input.len) {
        if (next_code < code.len and code[next_code].open == index) {
            index = code[next_code].close + code[next_code].len;
            next_code += 1;
            continue;
        }

        const char = input[index];

        if (char == '\\') {
            index += 2;
            continue;
        }

        if (char == '[') {
            try open.append(arena, index);
        } else if (char == ']' and open.items.len > 0) {
            try pairs.append(arena, .{
                .open = open.pop().?,
                .close = index,
            });
        }

        index += 1;
    }

    std.mem.sort(Bracket, pairs.items, {}, bracket_less_than);

    std.debug.assert(open.items.len + pairs.items.len * 2 <= input.len);

    return pairs.items;
}

fn bracket_less_than(_: void, left: Bracket, right: Bracket) bool {
    return left.open < right.open;
}

test "code spans pair runs of the same length and skip what they hold" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try find(arena, "a ``b ` c`` d `e` \\`f` `` g");

    try std.testing.expectEqual(@as(usize, 2), found.code.len);
    try std.testing.expectEqual(@as(u32, 2), found.code[0].open);
    try std.testing.expectEqual(@as(u32, 2), found.code[0].len);
    try std.testing.expectEqual(@as(u32, 9), found.code[0].close);
    try std.testing.expectEqual(@as(u32, 14), found.code[1].open);

    const lonely = try find(arena, "``` a ` b ``");
    try std.testing.expectEqual(@as(usize, 0), lonely.code.len);
}

test "brackets pair inside out, but not inside code or when escaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try find(arena, "[a [b] `]` \\] c] ]");

    try std.testing.expectEqual(@as(usize, 2), found.brackets.len);
    try std.testing.expectEqual(@as(u32, 0), found.brackets[0].open);
    try std.testing.expectEqual(@as(u32, 15), found.brackets[0].close);
    try std.testing.expectEqual(@as(u32, 3), found.brackets[1].open);
    try std.testing.expectEqual(@as(u32, 5), found.brackets[1].close);
}
