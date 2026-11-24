//! Which referral the visitor first came with: the `ref` query parameter sampler asks core
//! to keep for each visitor who brings one (`.request`).
//!
//! Example:
//!   in: {}
//!   out: { "ref": "" }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {};

pub const Out = struct {
    /// The referral the visitor first brought; empty when none
    ref: []const u8,
};

fn run(ctx: *publr.Ctx, _: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    const read = try ctx.call(publr.operations.request.Read, .{});

    for (read.first.values) |value| {
        if (std.mem.eql(u8, value.name, "ref")) {
            return .{
                .ref = value.value,
            };
        }
    }

    return .{
        .ref = "",
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "referral",
    .kind = .read,
    .run = run,
});
