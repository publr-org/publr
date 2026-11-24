//! The pages of a plugin's memory nobody holds. Linear memory only grows and a plugin has a
//! ceiling on it, so free pages are kept as runs in one list, lowest first, joined with their
//! neighbours when given back and split when fewer are asked. Pages are named by their number
//! from where memory starts.

const std = @import("std");

pub const page_bytes: u32 = 64 << 10;

/// A run of free pages: this sits at its start.
const Run = struct {
    next: ?*Run,
    pages: u32,
};

/// `Memory` is where the pages are: `base_address()`, `pages()` it holds now, and
/// `grow(more)`, which adds pages at its end or answers false.
pub fn Runs(comptime Memory: type) type {
    return struct {
        memory: Memory,
        /// Free runs, lowest page first, no two touching.
        first: ?*Run = null,

        const Self = @This();

        /// `pages` pages, from the smallest free run that holds them, else from new memory
        /// (the highest free run grown, when memory ends where it does). Null when memory
        /// is full.
        pub fn take(runs: *Self, pages: u32) ?u32 {
            std.debug.assert(pages > 0);

            var best: ?*?*Run = null;
            var last: ?*?*Run = null;
            var link: *?*Run = &runs.first;

            while (link.*) |run| {
                runs.assert_apart(run);

                if (run.pages >= pages) {
                    if (best == null or run.pages < best.?.*.?.pages) {
                        best = link;
                    }
                }

                last = link;
                link = &run.next;
            }

            if (best) |found| {
                return runs.cut(found, pages);
            }

            if (last) |highest| {
                const run = highest.*.?;

                if (runs.page_of(run) + run.pages == runs.memory.pages()) {
                    if (!runs.memory.grow(pages - run.pages)) {
                        return null;
                    }

                    highest.* = null;

                    return runs.page_of(run);
                }
            }

            const page = runs.memory.pages();

            return if (runs.memory.grow(pages)) page else null;
        }

        /// `pages` pages from `page` on given back: joined with the free runs they touch.
        pub fn give(runs: *Self, page: u32, pages: u32) void {
            std.debug.assert(pages > 0);
            std.debug.assert(page + pages <= runs.memory.pages());

            var before: ?*Run = null;
            var after: ?*Run = runs.first;

            while (after) |run| {
                if (runs.page_of(run) > page) {
                    break;
                }

                before = run;
                after = run.next;
            }

            const run = runs.run_at(page);

            run.* = .{
                .next = after,
                .pages = pages,
            };

            if (after) |next| {
                std.debug.assert(page + pages <= runs.page_of(next));

                if (page + pages == runs.page_of(next)) {
                    run.pages += next.pages;
                    run.next = next.next;
                }
            }

            const previous = before orelse {
                runs.first = run;

                return;
            };
            const previous_end = runs.page_of(previous) + previous.pages;

            std.debug.assert(previous_end <= page);

            if (previous_end == page) {
                previous.pages += run.pages;
                previous.next = run.next;
            } else {
                previous.next = run;
            }
        }

        /// `more` pages added from page `end` on: taken from the free run that starts there,
        /// or from new memory when memory ends there. False when something else holds them.
        pub fn extend(runs: *Self, end: u32, more: u32) bool {
            std.debug.assert(more > 0);
            std.debug.assert(end <= runs.memory.pages());

            if (end == runs.memory.pages()) {
                return runs.memory.grow(more);
            }

            var link: *?*Run = &runs.first;

            while (link.*) |run| {
                if (runs.page_of(run) > end) {
                    return false;
                }

                if (runs.page_of(run) == end) {
                    break;
                }

                link = &run.next;
            }

            const run = link.* orelse return false;

            if (run.pages >= more) {
                _ = runs.cut(link, more);

                return true;
            }

            // The rest may be new memory, when the run is the last thing in it.
            if (end + run.pages != runs.memory.pages()) {
                return false;
            }

            if (!runs.memory.grow(more - run.pages)) {
                return false;
            }

            link.* = run.next;

            return true;
        }

        /// How many pages are free, for a check.
        pub fn free_pages(runs: *const Self) u32 {
            var pages: u32 = 0;
            var next = runs.first;

            while (next) |run| {
                runs.assert_apart(run);

                pages += run.pages;
                next = run.next;
            }

            return pages;
        }

        /// Where page `page` starts.
        pub fn address(runs: *const Self, page: u32) u64 {
            std.debug.assert(page > 0);
            std.debug.assert(page <= runs.memory.pages());

            return runs.memory.base_address() + @as(u64, page) * page_bytes;
        }

        /// The page starting at `at`.
        pub fn page_at(runs: *const Self, at: u64) u32 {
            const offset = at - runs.memory.base_address();

            std.debug.assert(offset % page_bytes == 0);
            std.debug.assert(offset > 0);

            return @intCast(offset / page_bytes);
        }

        /// The first `pages` pages of the run at `link` taken out of the list; their page.
        fn cut(runs: *Self, link: *?*Run, pages: u32) u32 {
            const run = link.*.?;
            const page = runs.page_of(run);

            std.debug.assert(pages > 0);
            std.debug.assert(run.pages >= pages);

            if (run.pages == pages) {
                link.* = run.next;
            } else {
                const rest = runs.run_at(page + pages);

                rest.* = .{
                    .next = run.next,
                    .pages = run.pages - pages,
                };
                link.* = rest;
            }

            return page;
        }

        fn run_at(runs: *const Self, page: u32) *Run {
            return @ptrFromInt(@as(usize, @intCast(runs.address(page))));
        }

        fn page_of(runs: *const Self, run: *const Run) u32 {
            return runs.page_at(@intFromPtr(run));
        }

        /// A run ends inside memory, and before the next one starts: never touching it.
        fn assert_apart(runs: *const Self, run: *const Run) void {
            const end = runs.page_of(run) + run.pages;

            std.debug.assert(run.pages > 0);
            std.debug.assert(end <= runs.memory.pages());

            if (run.next) |next| {
                std.debug.assert(end < runs.page_of(next));
            }
        }
    };
}

/// Ordinary memory standing in for a plugin's, for tests: its first page is held, as a
/// plugin's own data is, and it grows up to a ceiling.
pub const TestMemory = struct {
    state: *State,

    pub const pages_max: u32 = 24;

    pub const State = struct {
        buffer: []align(page_bytes) u8,
        pages: u32 = 1,

        pub fn init(gpa: std.mem.Allocator) !State {
            const alignment: std.mem.Alignment = comptime .fromByteUnits(page_bytes);

            return .{
                .buffer = try gpa.alignedAlloc(u8, alignment, pages_max * page_bytes),
            };
        }

        pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
            gpa.free(state.buffer);
        }
    };

    pub fn base_address(memory: TestMemory) u64 {
        return @intFromPtr(memory.state.buffer.ptr);
    }

    pub fn pages(memory: TestMemory) u32 {
        return memory.state.pages;
    }

    pub fn grow(memory: TestMemory, more: u32) bool {
        std.debug.assert(memory.state.pages <= pages_max);

        if (more > pages_max - memory.state.pages) {
            return false;
        }

        memory.state.pages += more;

        return true;
    }
};

test "pages are taken from new memory, given back, and taken again from the smallest run" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };

    try std.testing.expectEqual(@as(?u32, 1), runs.take(3));
    try std.testing.expectEqual(@as(?u32, 4), runs.take(1));
    try std.testing.expectEqual(@as(?u32, 5), runs.take(2));
    try std.testing.expectEqual(@as(?u32, 7), runs.take(1));
    try std.testing.expectEqual(@as(u32, 8), state.pages);
    try std.testing.expectEqual(@as(u32, 0), runs.free_pages());

    runs.give(1, 3);
    runs.give(5, 2);
    try std.testing.expectEqual(@as(u32, 5), runs.free_pages());

    // Two fit in both runs: the smaller one is taken whole, the larger is left to split.
    try std.testing.expectEqual(@as(?u32, 5), runs.take(2));
    try std.testing.expectEqual(@as(?u32, 1), runs.take(1));
    try std.testing.expectEqual(@as(?u32, 2), runs.take(2));
    try std.testing.expectEqual(@as(u32, 0), runs.free_pages());
    try std.testing.expectEqual(@as(u32, 8), state.pages);
}

test "runs given back join their neighbours on both sides" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };

    try std.testing.expectEqual(@as(?u32, 1), runs.take(6));
    try std.testing.expectEqual(@as(?u32, 7), runs.take(1));

    runs.give(1, 2);
    runs.give(5, 2);
    try std.testing.expect(runs.first.?.next != null);

    runs.give(3, 2);
    try std.testing.expectEqual(@as(u32, 6), runs.first.?.pages);
    try std.testing.expectEqual(@as(?*Run, null), runs.first.?.next);
    try std.testing.expectEqual(@as(?u32, 1), runs.take(6));
}

test "the highest free run grows into new memory; a full memory answers null" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };

    try std.testing.expectEqual(@as(?u32, 1), runs.take(2));
    try std.testing.expectEqual(@as(?u32, 3), runs.take(2));
    runs.give(3, 2);

    // Five are asked and two are free at the end of memory: three are added, not five.
    try std.testing.expectEqual(@as(?u32, 3), runs.take(5));
    try std.testing.expectEqual(@as(u32, 8), state.pages);
    try std.testing.expectEqual(@as(?u32, null), runs.take(TestMemory.pages_max));
    try std.testing.expectEqual(@as(u32, 8), state.pages);

    runs.give(3, 5);
    try std.testing.expectEqual(@as(?u32, null), runs.take(TestMemory.pages_max));
    try std.testing.expectEqual(@as(u32, 5), runs.free_pages());
    try std.testing.expectEqual(@as(?u32, 3), runs.take(TestMemory.pages_max - 3));
    try std.testing.expectEqual(TestMemory.pages_max, state.pages);
}

test "extend takes the pages after a run: a free run there, new memory, or neither" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };

    try std.testing.expectEqual(@as(?u32, 1), runs.take(1));
    try std.testing.expectEqual(@as(?u32, 2), runs.take(3));
    try std.testing.expectEqual(@as(?u32, 5), runs.take(1));

    // Held by another: refused. Freed: taken, split when it holds more than asked.
    try std.testing.expect(!runs.extend(2, 1));
    runs.give(2, 3);
    try std.testing.expect(runs.extend(2, 1));
    try std.testing.expectEqual(@as(u32, 2), runs.free_pages());
    try std.testing.expect(runs.extend(3, 2));
    try std.testing.expect(!runs.extend(5, 1));

    // At the end of memory: new pages, and a free run there with the rest added to it.
    try std.testing.expect(runs.extend(6, 2));
    try std.testing.expectEqual(@as(u32, 8), state.pages);
    runs.give(7, 1);
    try std.testing.expect(runs.extend(7, 3));
    try std.testing.expectEqual(@as(u32, 10), state.pages);
    try std.testing.expectEqual(@as(u32, 0), runs.free_pages());
    try std.testing.expect(!runs.extend(10, TestMemory.pages_max));
}
