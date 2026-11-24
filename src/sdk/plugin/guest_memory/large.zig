//! The requests of one arena that took pages of their own: a page or more each, exactly as
//! many pages as it needs, grown and shrunk by pages and given back when freed. Each is noted
//! in a node the arena makes room for; a freed request's node notes the next.

const std = @import("std");
const runs_module = @import("runs.zig");

pub const Node = struct {
    next: ?*Node,
    page: u32,
    pages: u32,
};

pub fn Requests(comptime Memory: type) type {
    return struct {
        held: ?*Node = null,
        spare: ?*Node = null,

        const Self = @This();
        const Runs = runs_module.Runs(Memory);

        /// A node no request is noted in, taken off the spare ones; null when there is none.
        pub fn spare_node(requests: *Self) ?*Node {
            const node = requests.spare orelse return null;

            requests.spare = node.next;

            return node;
        }

        /// `pages` pages of their own, noted in `node`; null when memory is full, the node
        /// kept for the next request.
        pub fn take(requests: *Self, runs: *Runs, node: *Node, pages: u32) ?[*]u8 {
            std.debug.assert(pages > 0);

            const page = runs.take(pages) orelse {
                node.next = requests.spare;
                requests.spare = node;

                return null;
            };

            node.* = .{
                .next = requests.held,
                .page = page,
                .pages = pages,
            };
            requests.held = node;

            return @ptrFromInt(@as(usize, @intCast(runs.address(page))));
        }

        /// The request at `memory` made `needed` pages where it lies; false when it is not
        /// one of these or the pages after it are held.
        pub fn resize(requests: *Self, runs: *Runs, memory: [*]u8, needed: u32) bool {
            const node = (requests.link_of(runs, memory) orelse return false).*.?;

            std.debug.assert(needed > 0);

            if (needed < node.pages) {
                runs.give(node.page + needed, node.pages - needed);
            }

            if (needed > node.pages) {
                if (!runs.extend(node.page + node.pages, needed - node.pages)) {
                    return false;
                }
            }

            node.pages = needed;

            return true;
        }

        /// The pages of the request at `memory` given back, its node kept for the next.
        pub fn free(requests: *Self, runs: *Runs, memory: [*]u8) void {
            const link = requests.link_of(runs, memory) orelse return;
            const node = link.*.?;

            std.debug.assert(node.pages > 0);

            runs.give(node.page, node.pages);
            link.* = node.next;
            node.next = requests.spare;
            requests.spare = node;
        }

        /// Every request's pages given back: the nodes go with the arena's own memory.
        pub fn give_all(requests: *Self, runs: *Runs) void {
            var next = requests.held;

            while (next) |node| {
                std.debug.assert(node.pages > 0);

                runs.give(node.page, node.pages);
                next = node.next;
            }

            requests.* = .{};
        }

        /// The link to the node of the request at `memory`.
        fn link_of(requests: *Self, runs: *Runs, memory: [*]u8) ?*?*Node {
            const page = runs.page_at(@intFromPtr(memory));
            var link: *?*Node = &requests.held;

            while (link.*) |node| {
                std.debug.assert(node.pages > 0);

                if (node.page == page) {
                    return link;
                }

                link = &node.next;
            }

            return null;
        }
    };
}

const TestMemory = runs_module.TestMemory;

test "a large request holds its pages exactly; freed, its node notes the next" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: runs_module.Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };
    var nodes: [2]Node = undefined;
    var requests: Requests(TestMemory) = .{};

    try std.testing.expectEqual(@as(?*Node, null), requests.spare_node());

    const first = requests.take(&runs, &nodes[0], 3).?;
    const second = requests.take(&runs, &nodes[1], 1).?;

    try std.testing.expectEqual(@as(u32, 5), state.pages);

    // The first shrinks where it lies and takes its page back, but the second holds the
    // page after that; the second ends memory, so it grows into new pages.
    try std.testing.expect(requests.resize(&runs, first, 2));
    try std.testing.expectEqual(@as(u32, 1), runs.free_pages());
    try std.testing.expect(requests.resize(&runs, first, 3));
    try std.testing.expect(!requests.resize(&runs, first, 4));
    try std.testing.expect(requests.resize(&runs, second, 4));
    try std.testing.expectEqual(@as(u32, 8), state.pages);

    requests.free(&runs, first);
    requests.free(&runs, first);
    try std.testing.expectEqual(@as(u32, 3), runs.free_pages());
    try std.testing.expectEqual(@as(?*Node, &nodes[0]), requests.spare_node());

    // Memory is full: nothing is taken and the node waits for the next request.
    const full = requests.take(&runs, &nodes[0], TestMemory.pages_max);

    try std.testing.expectEqual(@as(?[*]u8, null), full);
    try std.testing.expectEqual(@as(?*Node, &nodes[0]), requests.spare);

    requests.give_all(&runs);
    try std.testing.expectEqual(state.pages - 1, runs.free_pages());
    try std.testing.expectEqual(@as(?*Node, null), requests.held);
}
