//! Waves back at anyone signed in.
//!
//! Untrusted callers may reach it, and its ready answer lets in only people signed in.
//!
//! Example:
//!   in: { "who": "Ada" }
//!   out: { "wave": "Hi, Ada" }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {
    /// Who waves back
    who: []const u8 = "you",
};

pub const Out = struct {
    /// The wave
    wave: []const u8,
};

/// A name of 1 to 40 characters.
fn check(in: In, problems: *publr.Problems(In)) void {
    if (in.who.len == 0 or in.who.len > 40) {
        problems.add(.who, "A name is 1 to 40 characters.");
    }
}

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.who.len > 0);
    std.debug.assert(in.who.len <= 40);

    // A ready answer lets administrators through wherever they call from; only someone signed
    // in is waved at by name.
    const by_name = ctx.caller().signed_in();

    return .{
        .wave = if (by_name) try ctx.print("Hi, {s}", .{in.who}) else "Hi",
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "wave",
    .kind = .read,
    .untrusted_callers = true,
    .authorize = publr.authorize.user_is_signed_in,
    .validate = check,
    .limit = .{
        .per_minute = 30,
    },
    .run = run,
});
