//! Tracks errors, for the tests of `publr.errors.Failed` and of the sign-in refusals kept
//! outside their write.
//!
//! `break` logs an error line, refuses, or fails as asked; its `on` hooks write on the Log
//! what they heard.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "tracker",
    .version = "0.1.0",
};

pub const BreakIn = struct {
    /// `line`, `refuse` or `crash`
    how: []const u8,
};

pub const BreakOut = struct {
    /// How it broke
    how: []const u8,
};

/// Breaks in the way asked.
///
/// Fails:
/// - Nope: asked to refuse
///
/// Example:
///   in: { "how": "line" }
///   out: { "how": "line" }
pub const Break = publr.operation.define(BreakIn, BreakOut, .{
    .name = "break",
    .kind = .write,
    .run = run,
});

fn run(ctx: *publr.Ctx, in: BreakIn) publr.Error!BreakOut {
    std.debug.assert(in.how.len > 0);

    if (std.mem.eql(u8, in.how, "refuse")) {
        return ctx.fail(.Nope, "Not today", .{});
    }

    if (std.mem.eql(u8, in.how, "crash")) {
        return error.Unavailable;
    }

    ctx.log(.err, "The disk is full", .{});

    return .{
        .how = in.how,
    };
}

/// Sends every error to the tracker
fn track(ctx: *publr.QueueCtx, failed: publr.errors.Failed.Payload) publr.Error!void {
    std.debug.assert(failed.entry > 0);

    ctx.log(.info, "Tracked {s} {s}: {s} by {s}", .{
        failed.what,
        failed.error_name,
        failed.message,
        failed.caller,
    });
}

/// Notes sign-ins that failed
fn noted(ctx: *publr.QueueCtx, failed: publr.auth.SignInFailed.Payload) publr.Error!void {
    std.debug.assert(failed.email.len > 0);

    ctx.log(.info, "Sign-in failed for {s}", .{failed.email});
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Break},
    .hooks = &.{
        publr.on(publr.errors.Failed, track),
        publr.on(publr.auth.SignInFailed, noted),
    },
});
