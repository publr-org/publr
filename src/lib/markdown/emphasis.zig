//! Runs of `*`, `_` and `~~` paired into emphasis, strong emphasis and strikethrough, the
//! way CommonMark's delimiter stack does it: each closer takes the nearest opener of its
//! kind; what is between them and unpaired stays text. A link's text is a wall: nothing
//! pairs across it. A failed search raises that marker's floor, so each search is bounded.

const std = @import("std");
const token_module = @import("token.zig");

const Token = token_module.Token;
const Tag = token_module.Tag;

const markers = "*_~";

const Stack = struct {
    items: std.ArrayList(u32) = .empty,
    /// Per marker in `markers`: below this, no opener of it is worth looking at.
    floors: [markers.len]u32 = @splat(0),
    /// Where a link's text started; nothing below pairs with what is inside it.
    wall: u32 = 0,

    fn floor(stack: *const Stack, marker: u8) u32 {
        const index = std.mem.indexOfScalar(u8, markers, marker).?;

        std.debug.assert(index < markers.len);

        return @max(stack.floors[index], stack.wall);
    }

    fn raise(stack: *Stack, marker: u8) void {
        const index = std.mem.indexOfScalar(u8, markers, marker).?;

        std.debug.assert(stack.items.items.len >= stack.wall);

        stack.floors[index] = @intCast(stack.items.items.len);
    }

    fn truncate(stack: *Stack, len: u32) void {
        std.debug.assert(len <= stack.items.items.len);

        stack.items.shrinkRetainingCapacity(len);

        for (&stack.floors) |*floor_value| {
            floor_value.* = @min(floor_value.*, len);
        }

        stack.wall = @min(stack.wall, len);
    }
};

pub fn pair(arena: std.mem.Allocator, tokens: []Token) std.mem.Allocator.Error!void {
    std.debug.assert(tokens.len <= std.math.maxInt(u32));

    var stack: Stack = .{};

    for (tokens, 0..) |*token, index| {
        switch (token.kind) {
            .link_open => {
                stack.wall = @intCast(stack.items.items.len);
            },
            .link_close => {
                stack.truncate(stack.wall);
                stack.wall = 0;
            },
            .delimiter => {
                if (token.can_close) {
                    close(tokens, &stack, token);
                }

                if (token.can_open and token.remaining > 0) {
                    try stack.items.append(arena, @intCast(index));
                }
            },
            else => {},
        }
    }

    std.debug.assert(stack.items.items.len <= tokens.len);
}

/// Pairs `closer` with the openers below it until it is used up or none is left.
fn close(tokens: []Token, stack: *Stack, closer: *Token) void {
    std.debug.assert(closer.kind == .delimiter);
    std.debug.assert(closer.can_close);

    while (closer.remaining > 0) {
        const found = opener_of(tokens, stack, closer) orelse {
            stack.raise(closer.marker);
            return;
        };
        const opener = &tokens[stack.items.items[found]];
        const used: u32 = if (closer.marker == '~') 2 else if (opener.remaining >= 2 and
            closer.remaining >= 2) 2 else 1;
        const tag: Tag = if (closer.marker == '~') .del else if (used == 2) .strong else .em;

        opener.open(tag);
        closer.close(tag);
        opener.remaining -= used;
        closer.remaining -= used;

        const kept: u32 = if (opener.remaining > 0) found + 1 else found;

        stack.truncate(kept);
    }
}

/// The nearest opener of the closer's kind on the stack, above the floor, with room for
/// one more tag on both runs.
fn opener_of(tokens: []const Token, stack: *const Stack, closer: *const Token) ?u32 {
    std.debug.assert(closer.remaining > 0);

    if (closer.closes_len == token_module.tags_per_run_max) {
        return null;
    }

    const floor = stack.floor(closer.marker);
    var index: u32 = @intCast(stack.items.items.len);

    while (index > floor) {
        index -= 1;

        const opener = &tokens[stack.items.items[index]];
        const fits = opener.opens_len < token_module.tags_per_run_max;

        if (opener.marker == closer.marker and opener.remaining > 0 and fits) {
            return index;
        }
    }

    std.debug.assert(index == floor or index < stack.items.items.len);

    return null;
}

fn run(start: u32, marker: u8, len: u32, can_open: bool, can_close: bool) Token {
    return .{
        .kind = .delimiter,
        .start = start,
        .end = start + len,
        .marker = marker,
        .can_open = can_open,
        .can_close = can_close,
        .remaining = len,
    };
}

test "a closer takes the nearest opener; three stars are strong inside emphasis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tokens = [_]Token{
        run(0, '*', 3, true, false),
        run(5, '*', 3, false, true),
    };

    try pair(arena_state.allocator(), &tokens);

    try std.testing.expectEqual(@as(u32, 2), tokens[0].opens_len);
    try std.testing.expectEqual(Tag.em, tokens[0].opens[0]);
    try std.testing.expectEqual(Tag.strong, tokens[0].opens[1]);
    try std.testing.expectEqual(Tag.strong, tokens[1].closes[0]);
    try std.testing.expectEqual(Tag.em, tokens[1].closes[1]);
    try std.testing.expectEqual(@as(u32, 0), tokens[1].remaining);
}

test "unpaired runs stay text, kinds never mix, and a link's text is a wall" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tokens = [_]Token{
        run(0, '*', 1, true, false),
        run(2, '_', 1, false, true),
        .{
            .kind = .link_open,
            .start = 4,
            .end = 5,
        },
        run(6, '*', 1, false, true),
        .{
            .kind = .link_close,
            .start = 8,
            .end = 12,
        },
        run(13, '~', 2, true, false),
    };

    try pair(arena_state.allocator(), &tokens);

    try std.testing.expectEqual(@as(u32, 0), tokens[0].opens_len);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].remaining);
    try std.testing.expectEqual(@as(u32, 0), tokens[1].closes_len);
    try std.testing.expectEqual(@as(u32, 0), tokens[3].closes_len);
    try std.testing.expectEqual(@as(u32, 2), tokens[5].remaining);
}
