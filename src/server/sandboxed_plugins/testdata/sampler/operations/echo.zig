//! Answer every field back.
//!
//! Every shape a field may take, answered back as it arrived. Administrators may call it; it
//! never fails.
//!
//! Example:
//!   in: { "text": "a", "count": 2, "ratio": 0.5, "flag": true }
//!   out: { "text": "a", "count": 2, "ratio": 0.5, "flag": true }
const publr = @import("publr");
const std = @import("std");

pub const Point = struct {
    /// How far across
    across: i64,
    /// How far down
    down: i64,
};

pub const Mood = enum { calm, loud };

pub const In = struct {
    /// Some text
    text: []const u8 = "",
    /// A whole number
    count: i64 = 0,
    /// A number
    ratio: f64 = 0,
    /// Yes or no
    flag: bool = false,
    /// A list of words
    tags: []const []const u8 = &.{},
    /// One of a few
    mood: Mood = .calm,
    /// A number, or nothing
    maybe: ?i64 = null,
    /// A list of points
    points: []const Point = &.{},
};

pub const Out = In;

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);
    std.debug.assert(in.tags.len <= 1024);

    return in;
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "echo",
    .kind = .read,
    .run = run,
});
