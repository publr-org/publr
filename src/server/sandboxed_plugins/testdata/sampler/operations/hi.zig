//! Say hi: hello's old name, kept while callers move to hello.
//!
//! Anyone may call it, signed in or not; every caller is told it is on its way out.
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

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.who.len > 0);
    std.debug.assert(in.who.len <= 64);

    return .{
        .text = try ctx.print("hello, {s}", .{in.who}),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "hi",
    .kind = .read,
    .untrusted_callers = true,
    .deprecated = .{
        .since = "0.1.0",
        .instead = "sampler.hello",
    },
    .run = run,
});
