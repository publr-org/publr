//! Measures a text, its length passed through `sampler.length` for plugins to modify.
//!
//! Sampler's own modifier on `sampler.*` doubles it, so modifying reaches the plugin's own
//! values in either build. Changes nothing.
//!
//! Example:
//!   in: { "text": "abc" }
//!   out: { "length": 6 }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {
    /// The text to measure
    text: []const u8,
};

pub const Out = struct {
    /// Its length, as every modifier of `sampler.length` left it
    length: u32,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.text.len <= 1 << 16);

    const length: u32 = @intCast(in.text.len);

    return .{
        .length = try ctx.mod("sampler.length", length),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "measure",
    .kind = .read,
    .run = run,
});
