//! Say hello to anyone.
//!
//! Anyone may call it, signed in or not.
//!
//! Example:
//!   in: {}
//!   out: { "text": "hello, world" }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {
    /// Who to greet
    who: []const u8 = "world",
};

pub const Out = struct {
    /// The greeting
    text: []const u8,
};

/// A name of 1 to 64 characters.
fn check(in: In, problems: *publr.Problems(In)) void {
    if (in.who.len == 0 or in.who.len > 64) {
        problems.add(.who, "A name is 1 to 64 characters.");
    }
}

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.who.len > 0);
    std.debug.assert(in.who.len <= 64);

    return .{
        .text = try ctx.print("hello, {s}", .{in.who}),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "hello",
    .kind = .read,
    .untrusted_callers = true,
    .validate = check,
    .run = run,
});
