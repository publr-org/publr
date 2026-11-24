//! One piece of a compiled-in plugin's work (`../plugin_memory.zig`): an operation, a hook,
//! a modifier, a job or a scope, in an arena of its own over the plugins' memory.
const std = @import("std");
const Ctx = @import("../context.zig").Ctx;
const operation = @import("../operation.zig");
const plugin_memory = @import("../plugin_memory.zig");

const Arena = plugin_memory.Arena;
const Memory = plugin_memory.Memory;
const page_bytes = plugin_memory.page_bytes;
const is_work = plugin_memory.is_work;
const walks_native = @import("../plugin/walks/native.zig");

/// One piece of a compiled-in plugin's work in memory of its own: `ctx.arena` is that
/// memory from `begin` to `leave`, and `end` gives all of it back. Where the process set no
/// plugin memory aside the work stays in its caller's memory and nothing is given back.
/// It stays where it is made from `begin` to `end`.
pub const Work = struct {
    ctx: *Ctx,
    memory: ?*Memory,
    arena: Arena,
    /// The caller's memory: where what the work answers is copied.
    outer: std.mem.Allocator,
    lasting: ?std.mem.Allocator,
    inside: bool,
    /// Walks open when the work began: those opened inside it are given back with it.
    walks_mark: u32,

    pub fn begin(work: *Work, ctx: *Ctx) void {
        std.debug.assert(ctx.now_ms >= 0);

        work.* = .{
            .ctx = ctx,
            .memory = ctx.plugins_set_aside,
            .arena = undefined,
            .outer = ctx.arena,
            .lasting = ctx.lasting,
            .inside = false,
            .walks_mark = ctx.walks.len,
        };

        const memory = work.memory orelse return;

        work.arena = .{
            .runs = &memory.runs,
        };
        work.inside = true;
        memory.open += 1;
        memory.begun += 1;
        ctx.lasting = work.lasting orelse work.outer;
        ctx.arena = work.arena.allocator();

        std.debug.assert(is_work(ctx.arena));
    }

    /// Work that stays in its caller's memory: nothing of its own to give back but the walks
    /// opened inside it.
    pub fn stay(work: *Work, ctx: *Ctx) void {
        std.debug.assert(ctx.now_ms >= 0);

        work.* = .{
            .ctx = ctx,
            .memory = null,
            .arena = undefined,
            .outer = ctx.arena,
            .lasting = ctx.lasting,
            .inside = false,
            .walks_mark = ctx.walks.len,
        };

        std.debug.assert(!work.own());
    }

    /// Whether the work has memory of its own.
    pub fn own(work: *const Work) bool {
        std.debug.assert(work.memory != null or !work.inside);

        return work.memory != null;
    }

    /// The caller's memory is `ctx.arena` again; what the work holds stays until `end`.
    pub fn leave(work: *Work) void {
        if (!work.inside) {
            return;
        }

        walks_native.leave_above(work.ctx, work.walks_mark);

        // Work nests: what began inside this has ended.
        std.debug.assert(work.ctx.arena.ptr == @as(*anyopaque, @ptrCast(&work.arena)));

        work.inside = false;
        work.ctx.arena = work.outer;
        work.ctx.lasting = work.lasting;
    }

    /// Everything the work holds given back. A refusal's words (`ctx.failure`,
    /// `ctx.problems`) made in it are copied to the caller's memory first.
    pub fn end(work: *Work) void {
        work.leave();
        walks_native.end_above(work.ctx, work.walks_mark);
        // Ended once: walks opened after this never go with it.
        work.walks_mark = std.math.maxInt(u32);

        const memory = work.memory orelse return;

        std.debug.assert(memory.open > 0);

        carry_failure(work, memory);
        work.arena.poison();
        work.arena.deinit();
        memory.open -= 1;
        work.memory = null;
    }

    /// Whether `text` lies in what this work holds.
    fn holds(work: *const Work, memory: *const Memory, text: []const u8) bool {
        const address: u64 = @intFromPtr(text.ptr);

        std.debug.assert(work.memory == memory);

        if (text.len == 0 or !memory.holds(address)) {
            return false;
        }

        var block = work.arena.blocks;

        while (block) |held| : (block = held.next) {
            const start: u64 = @intFromPtr(held);

            if (address >= start and address < start + @as(u64, held.pages) * page_bytes) {
                return true;
            }
        }

        var node = work.arena.large.held;

        while (node) |held| : (node = held.next) {
            const start = memory.runs.address(held.page);

            if (address >= start and address < start + @as(u64, held.pages) * page_bytes) {
                return true;
            }
        }

        return false;
    }

    fn kept(
        work: *const Work,
        memory: *const Memory,
        text: []const u8,
    ) error{OutOfMemory}![]const u8 {
        return if (work.holds(memory, text)) work.outer.dupe(u8, text) else text;
    }

    fn carry_failure(work: *const Work, memory: *const Memory) void {
        const ctx = work.ctx;

        std.debug.assert(!work.inside);

        if (ctx.failure) |*failure| {
            const name = work.kept(memory, failure.name);
            const message = work.kept(memory, failure.message);

            if (name) |name_kept| {
                failure.name = name_kept;
            } else |_| {
                ctx.failure = null;
            }

            if (ctx.failure) |*standing| {
                standing.message = message catch "";
            }
        }

        if (ctx.problems.len > 0) {
            ctx.problems = work.problems_kept(memory, ctx.problems) catch &.{};
        }
    }

    fn problems_kept(
        work: *const Work,
        memory: *const Memory,
        problems: []const operation.Problem,
    ) error{OutOfMemory}![]const operation.Problem {
        std.debug.assert(problems.len > 0);

        var moved = work.holds(memory, std.mem.sliceAsBytes(problems));

        for (problems) |problem| {
            moved = moved or work.holds(memory, problem.field) or
                work.holds(memory, problem.message);
        }

        if (!moved) {
            return problems;
        }

        const copied = try work.outer.alloc(operation.Problem, problems.len);

        for (problems, copied) |problem, *target| {
            target.* = .{
                .field = try work.outer.dupe(u8, problem.field),
                .message = try work.outer.dupe(u8, problem.message),
            };
        }

        return copied;
    }
};

const testing = std.testing;

const Fixture = struct {
    buffer: plugin_memory.Buffer,
    memory: Memory,
    connection: @import("../../lib/db.zig").Db = undefined,
    auth: @import("../../lib/auth.zig").State = undefined,

    fn init(fixture: *Fixture) !void {
        const bytes = 16 * page_bytes;

        fixture.buffer = try testing.allocator.alignedAlloc(u8, plugin_memory.alignment, bytes);
        fixture.memory.init(fixture.buffer);
    }

    fn deinit(fixture: *Fixture) void {
        testing.allocator.free(fixture.buffer);
    }

    fn ctx(fixture: *Fixture, arena: std.mem.Allocator) Ctx {
        var made = Ctx.init(&fixture.connection, testing.io, arena, &fixture.auth, .system, .{});

        made.plugins_set_aside = &fixture.memory;

        return made;
    }
};

test "a piece of work holds its own memory and gives every page back" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ctx = fixture.ctx(arena_state.allocator());
    var item: u32 = 0;

    // Sixteen pages hold a hundred pieces of work of six pages each, one at a time.
    while (item < 100) : (item += 1) {
        var work: Work = undefined;

        work.begin(&ctx);
        defer work.end();

        try testing.expect(work.own());
        try testing.expect(is_work(ctx.arena));
        try testing.expect(ctx.lasting.?.ptr == arena_state.allocator().ptr);
        @memset(try ctx.arena.alloc(u8, 5 * page_bytes), @truncate(item));
        @memset(try ctx.arena.alloc(u8, 100), 1);
    }

    try testing.expect(!is_work(ctx.arena));
    try testing.expect(ctx.lasting == null);
    try testing.expectEqual(@as(u32, 0), fixture.memory.open);
    try testing.expectEqual(@as(u64, 6 * page_bytes), fixture.memory.peak_bytes());

    fixture.memory.fresh();
    try testing.expectEqual(@as(u64, 0), fixture.memory.peak_bytes());
}

test "work nests, and after `leave` the caller's memory is used while the work's stays" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ctx = fixture.ctx(arena_state.allocator());
    var outer: Work = undefined;
    var inner: Work = undefined;

    outer.begin(&ctx);

    const mine = try ctx.arena.dupe(u8, "outer");

    inner.begin(&ctx);

    const step = try ctx.arena.dupe(u8, "inner");

    inner.leave();

    // Taken after the step was left: the outer work's, which outlives the step.
    const later = try ctx.arena.dupe(u8, step);

    try testing.expect(ctx.arena.ptr == @as(*anyopaque, @ptrCast(&outer.arena)));
    try testing.expectEqualStrings("inner", step);
    inner.end();
    try testing.expectEqualStrings("inner", later);
    try testing.expectEqualStrings("outer", mine);
    outer.end();

    try testing.expectEqual(@as(u32, 0), fixture.memory.open);
    try testing.expectEqual(fixture.memory.held.pages, fixture.memory.runs.free_pages());
}

test "a refusal's words made in the work outlive it; a full memory refuses the request" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var ctx = fixture.ctx(arena_state.allocator());
    var work: Work = undefined;

    work.begin(&ctx);
    try testing.expectError(error.OutOfMemory, ctx.arena.alloc(u8, 17 * page_bytes));

    const problems = try ctx.arena.alloc(operation.Problem, 1);

    problems[0] = .{
        .field = "title",
        .message = try ctx.arena.dupe(u8, "Say what it is"),
    };
    ctx.problems = problems;
    ctx.failure = .{
        .name = "NotEnoughStock",
        .status = 409,
        .message = try ctx.arena.dupe(u8, "Only 2 left"),
    };
    work.end();

    try testing.expectEqualStrings("Only 2 left", ctx.failure.?.message);
    try testing.expectEqualStrings("NotEnoughStock", ctx.failure.?.name);
    try testing.expectEqualStrings("Say what it is", ctx.problems[0].message);
    try testing.expectEqualStrings("title", ctx.problems[0].field);
}

test "with no memory set aside the work stays in its caller's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var connection: @import("../../lib/db.zig").Db = undefined;
    var auth: @import("../../lib/auth.zig").State = undefined;
    var ctx = Ctx.init(&connection, testing.io, arena_state.allocator(), &auth, .system, .{});
    var work: Work = undefined;

    work.begin(&ctx);
    try testing.expect(!work.own());
    try testing.expect(ctx.arena.ptr == arena_state.allocator().ptr);
    work.leave();
    work.end();
    try testing.expect(ctx.lasting == null);
}
