//! A test site's clock: the site's time moved ahead of (or back to) the wall clock, so
//! time-driven work can be tried end to end ("it is now 11 January": a payment request goes
//! overdue, a monthly job runs, VAT falls due on a due date). A plugin's `ctx.now()`
//! (compiled in and installed), queued work's `.due` moments and the queue worker all read
//! the site's time. Only on a test site: one that is not hosted, not a copy (`PUBLR_COPY`)
//! and, while `serve` runs, served over plain http, the switch `serve` already reads as
//! development (`model/outside.zig` `rule_of`). Everywhere else the clock is the wall clock
//! and moving it is refused. Sign-ins and sessions keep the wall clock.
const std = @import("std");
const sdk = @import("../sdk.zig");
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
    pub const name = "project.clock";
    pub const description = "The site's time, and whether a test clock moved it";
    pub const details =
        \\Administrators only. The time `ctx.now()`, queued work and the queue worker read:
        \\the wall clock, or on a test site the time `project.set_clock` set. Changes
        \\nothing.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        now_ms: i64,
        moved: bool,
        test_site: bool,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .now_ms = 1799625600000,
        .moved = false,
        .test_site = true,
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .now_ms = "The site's time now, in ms",
        .moved = "Whether a test clock moved it from the wall clock",
        .test_site = "Whether its clock may be moved here",
    };

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
    pub const name = "project.set_clock";
    pub const description = "Move a test site's clock: to a time, ahead, or back";
    pub const details =
        \\Administrators only, on a test site only: one on this computer, not hosted, not a
        \\copy, and served over plain http while `serve` runs; refused elsewhere. `at_ms` sets
        \\the site's time (ms since 1970), `ahead_ms` moves it on by that many ms, `reset`
        \\puts it back on the wall clock; from then on it runs as the wall clock does. A
        \\plugin's `ctx.now()`, queued work's `.due` moments and the queue worker read it, so
        \\what falls due by then runs. Sign-ins keep the wall clock.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        at_ms: ?i64 = null,
        ahead_ms: ?i64 = null,
        reset: bool = false,
    };
    pub const Out = struct {
        now_ms: i64,
    };
    pub const example: In = .{
        .at_ms = 1799625600000,
    };
    pub const example_out: Out = .{
        .now_ms = 1799625600000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .at_ms = "The site's time from now on, in ms since 1970",
        .ahead_ms = "Or: how many ms to move it on from the site's time now",
        .reset = "Or: back to the wall clock",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .now_ms = "The site's time now, in ms",
    };

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
