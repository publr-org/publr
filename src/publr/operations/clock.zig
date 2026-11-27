//! A test site's clock: the site's time moved ahead of (or back to) the wall clock, so
//! time-driven work can be tried end to end ("it is now 11 January": a payment request goes
//! overdue, a monthly job runs, VAT falls due on a due date). A plugin's `ctx.now()`
//! (compiled in and installed), queued work's `.due` moments and the queue worker all read
//! the site's time. Only on a test site: one that is not hosted, not a copy (`PUBLR_COPY`)
//! and, while `serve` runs, served over plain http, the switch `serve` already reads as
//! development. Everywhere else the clock is the wall clock and moving it is refused.
//! Sign-ins and sessions keep the wall clock.
const operation = @import("../operation.zig");

pub const Clock = struct {
    pub const name = "project.clock";
    pub const description = "The site's time, and whether a test clock moved it";
    pub const details =
        \\Administrators only. The time `ctx.now()`, queued work and the queue worker read:
        \\the wall clock, or on a test site the time `project.set_clock` set. Changes
        \\nothing.
    ;
    pub const kind: operation.Kind = .read;
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
    pub const output_docs: operation.Docs(Out) = .{
        .now_ms = "The site's time now, in ms",
        .moved = "Whether a test clock moved it from the wall clock",
        .test_site = "Whether its clock may be moved here",
    };
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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .at_ms = "The site's time from now on, in ms since 1970",
        .ahead_ms = "Or: how many ms to move it on from the site's time now",
        .reset = "Or: back to the wall clock",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .now_ms = "The site's time now, in ms",
    };
};
