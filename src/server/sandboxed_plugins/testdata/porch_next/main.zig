//! A porch, 0.2.0: knocking is for staff now, ringing still for visitors.
//!
//! The next version of `porch`, uploaded as its update: `porch.knock` no longer takes
//! untrusted callers, so a grant of it on the type's role is dropped.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "porch",
    .version = "0.2.0",
};

/// A porch's guests: members who sign up on the `www` app.
const user_types = [_]publr.plugin.UserType{.{
    .name = "porch_guest",
    .label = "Guest",
    .apps = &.{"www"},
    .sign_up = true,
    .roles = &.{"porch_guest"},
}};

const roles = [_]publr.plugin.Role{.{
    .name = "porch_guest",
    .label = "Guest",
    .description = "A guest at the porch",
}};

pub const CallIn = struct {};

pub const CallOut = struct {
    /// What the porch says
    said: []const u8,
};

/// Knocks at the door.
///
/// Example:
///   in: {}
///   out: { "said": "knock" }
pub const Knock = publr.operation.define(CallIn, CallOut, .{
    .name = "knock",
    .kind = .read,
    .run = knock,
});

/// Rings the bell.
///
/// Example:
///   in: {}
///   out: { "said": "ring" }
pub const Ring = publr.operation.define(CallIn, CallOut, .{
    .name = "ring",
    .kind = .read,
    .untrusted_callers = true,
    .run = ring,
});

fn knock(ctx: *publr.Ctx, in: CallIn) publr.Error!CallOut {
    _ = in;
    std.debug.assert(ctx.now().ms >= 0);

    return .{
        .said = "knock",
    };
}

fn ring(ctx: *publr.Ctx, in: CallIn) publr.Error!CallOut {
    _ = in;
    std.debug.assert(ctx.now().ms >= 0);

    return .{
        .said = "ring",
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .user_types = &user_types,
    .roles = &roles,
    .operations = &.{ Knock, Ring },
});
