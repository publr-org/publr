//! A hierarchy of nodes as a list in tree order: parents before children, siblings in
//! the order given, each node with its depth. No recursion: an explicit stack.

const std = @import("std");

pub const nodes_max: u32 = 10_000;
pub const depth_max: u32 = 16;
pub const none: u32 = std.math.maxInt(u32);

pub const Placed = struct { index: u32, depth: u32 };

pub const Error = error{ OutOfMemory, TooMany };

/// `parents[index]` is the index of the node's parent, or `none` for a root; a parent
/// that is not in the list makes the node a root. The result holds every node once.
pub fn order(arena: std.mem.Allocator, parents: []const u32) Error![]Placed {
    std.debug.assert(nodes_max > 0);
    std.debug.assert(depth_max > 0);

    if (parents.len > nodes_max) {
        return error.TooMany;
    }

    const count: u32 = @intCast(parents.len);
    const first_child = try arena.alloc(u32, count);
    const last_child = try arena.alloc(u32, count);
    const next_sibling = try arena.alloc(u32, count);
    var roots_first: u32 = none;
    var roots_last: u32 = none;

    @memset(first_child, none);
    @memset(last_child, none);
    @memset(next_sibling, none);

    for (parents, 0..) |parent, raw_index| {
        const index: u32 = @intCast(raw_index);
        const is_root = parent == none or parent >= count or parent == index;

        if (is_root) {
            append(&roots_first, &roots_last, next_sibling, index);
        } else {
            append(&first_child[parent], &last_child[parent], next_sibling, index);
        }
    }

    return walk(arena, count, roots_first, first_child, next_sibling);
}

fn append(first: *u32, last: *u32, next_sibling: []u32, index: u32) void {
    std.debug.assert(index < next_sibling.len);
    std.debug.assert((first.* == none) == (last.* == none));

    if (last.* == none) {
        first.* = index;
    } else {
        next_sibling[last.*] = index;
    }

    last.* = index;
}

/// Depth-first from the roots; a node deeper than `depth_max`, or one reached twice
/// through a cycle, is left where it is and never placed twice.
fn walk(
    arena: std.mem.Allocator,
    count: u32,
    roots_first: u32,
    first_child: []const u32,
    next_sibling: []const u32,
) Error![]Placed {
    std.debug.assert(first_child.len == count);
    std.debug.assert(next_sibling.len == count);

    const placed = try arena.alloc(Placed, count);
    const seen = try arena.alloc(bool, count);
    const stack = try arena.alloc(Placed, count + 1);
    var placed_len: u32 = 0;
    var stack_len: u32 = 0;

    @memset(seen, false);

    var root = roots_first;

    while (root != none) : (root = next_sibling[root]) {
        stack[stack_len] = .{ .index = root, .depth = 0 };
        stack_len += 1;

        while (stack_len > 0) {
            stack_len -= 1;
            const current = stack[stack_len];

            if (seen[current.index] or current.depth >= depth_max) {
                continue;
            }

            seen[current.index] = true;
            placed[placed_len] = current;
            placed_len += 1;

            try push_children(stack, &stack_len, current, first_child, next_sibling);
        }
    }

    return placed[0..placed_len];
}

/// The children go on the stack last first, so the first child comes off first.
fn push_children(
    stack: []Placed,
    stack_len: *u32,
    parent: Placed,
    first_child: []const u32,
    next_sibling: []const u32,
) Error!void {
    std.debug.assert(parent.index < first_child.len);
    std.debug.assert(stack_len.* <= stack.len);

    var reversed: [nodes_max]u32 = undefined;
    var children: u32 = 0;
    var child = first_child[parent.index];

    while (child != none) : (child = next_sibling[child]) {
        std.debug.assert(children < nodes_max);
        reversed[children] = child;
        children += 1;
    }

    while (children > 0) {
        children -= 1;

        if (stack_len.* == stack.len) {
            return error.TooMany;
        }

        stack[stack_len.*] = .{ .index = reversed[children], .depth = parent.depth + 1 };
        stack_len.* += 1;
    }
}

test "tree order: roots first, children under their parent in the given order, depths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parents = [_]u32{ none, 0, 0, 2, none, 1 };
    const placed = try order(arena, &parents);

    try std.testing.expectEqual(@as(usize, 6), placed.len);
    const expected_order = [_]u32{ 0, 1, 5, 2, 3, 4 };
    const expected_depth = [_]u32{ 0, 1, 2, 1, 2, 0 };

    for (placed, 0..) |node, position| {
        try std.testing.expectEqual(expected_order[position], node.index);
        try std.testing.expectEqual(expected_depth[position], node.depth);
    }
}

test "tree order: an unknown parent makes a root, a cycle places each node once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const orphaned = [_]u32{ 99, none };
    const placed = try order(arena, &orphaned);
    try std.testing.expectEqual(@as(usize, 2), placed.len);
    try std.testing.expectEqual(@as(u32, 0), placed[0].depth);

    const cyclic = [_]u32{ 1, 0, none };
    const looped = try order(arena, &cyclic);
    try std.testing.expectEqual(@as(usize, 1), looped.len);
    try std.testing.expectEqual(@as(u32, 2), looped[0].index);

    const empty = try order(arena, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
