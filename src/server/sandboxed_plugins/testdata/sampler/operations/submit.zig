//! Writes a review and submits it: the type's own flow, moved by name.
//!
//! Example:
//!   in: { "text": "Looks good" }
//!   out: { "status": "in_review" }
const publr = @import("publr");
const std = @import("std");

const Reviews = @import("../records/reviews.zig");

pub const In = struct {
    /// The review's text
    text: []const u8,
};

pub const Out = struct {
    /// Where the review is once submitted
    status: []const u8,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.text.len <= 4096);

    const id = try Reviews.record.create(ctx, .{
        .text = in.text,
    });
    const written = try Reviews.record.get(ctx, id, .{});
    const moved = try Reviews.record.transition(ctx, written, .submit);
    const held = try Reviews.record.get(ctx, id, .{});

    std.debug.assert(moved == .done);

    return .{
        .status = @tagName(held.status),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "submit",
    .kind = .write,
    .run = run,
});
