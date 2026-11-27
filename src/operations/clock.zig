const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/clock.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// The setting holding how far the site's time is from the wall clock, in ms.
pub const offset_key = "test_clock_offset";

/// The site's time on a test site: the wall clock moved by the offset set; the wall clock
/// when none is set or it cannot be read.
pub fn site_ms(connection: anytype, wall_ms: i64) i64 {
    std.debug.assert(wall_ms >= 0);

    const offset = offset_of(connection) catch 0;

    return @max(0, wall_ms + offset);
}

fn offset_of(connection: anytype) !i64 {
    std.debug.assert(offset_key.len > 0);

    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const text = try store.settings.get(connection, fixed.allocator(), offset_key) orelse return 0;

    return std.fmt.parseInt(i64, text, 10) catch 0;
}

const not_a_test_site: sdk.operation.Failure = .{
    .name = "NotATestSite",
    .status = 409,
    .message = "Only a test site's clock moves: one on this computer served over plain " ++
        "http, never production or a copy.",
};

pub const Clock = struct {
    pub const shape = public.Clock;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const moved = ctx.test_clock and try offset_of(ctx.db) != 0;

        return .{
            .now_ms = ctx.now_ms,
            .moved = moved,
            .test_site = ctx.test_clock,
        };
    }
};

pub const SetClock = struct {
    pub const shape = public.SetClock;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!ctx.test_clock) {
            return ctx.fail(not_a_test_site);
        }

        const given = @as(u8, @intFromBool(in.at_ms != null)) +
            @intFromBool(in.ahead_ms != null) + @intFromBool(in.reset);

        if (given != 1) {
            return error.Invalid;
        }

        const offset = try offset_of(ctx.db);
        const wall = ctx.now_ms - offset;
        const now: i64 = if (in.at_ms) |at|
            at
        else if (in.ahead_ms) |ahead|
            ctx.now_ms + ahead
        else
            wall;

        if (now < 0 or (in.ahead_ms != null and in.ahead_ms.? < 0)) {
            return error.Invalid;
        }

        var buffer: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{now - wall}) catch unreachable;

        if (in.reset) {
            try store.settings.delete(ctx.db, offset_key);
        } else {
            try store.settings.set(ctx.db, offset_key, text, wall);
        }

        ctx.now_ms = now;

        return .{
            .now_ms = now,
        };
    }
};

pub const operations = [_]type{ Clock, SetClock };
